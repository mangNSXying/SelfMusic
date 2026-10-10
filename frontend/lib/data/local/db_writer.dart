import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import '../sources/music_source.dart';
import '../sources/webdav_url.dart';
import '../../utils/perf_log.dart';
import 'artist_names.dart';
import 'schema.dart';

/// SQLite 写层：主线程只读，写按平台走两种实现之一（[DbWriter.start] 分派）。
///
/// 目标（DESIGN：启动磁盘 I/O 风暴修复）：
/// 1. 写/fsync 不与 UI 帧竞争——桌面/移动常规平台经后台 isolate（见
///    [_IsolateDbWriter]）离开 UI 线程；ohos 因引擎/包限制退化为同 isolate
///    内联写（见 [_InlineDbWriter] 头注释）；
/// 2. 队列内多条语句自动合并为**单个事务**（WAL 下一次顺序追加 + 一次 checkpoint
///    fsync），把「逐行 autocommit 的几万次小块写」收敛成少量大块顺序写；
/// 3. `PRAGMA synchronous=NORMAL`：WAL 模式下仅 checkpoint 才 fsync。
///
/// 一致性约定：全部调用按到达顺序 FIFO 执行；需要回执的调用在**落库后**才完成
/// Future（主线程读连接通过 WAL 立刻可见已提交数据）；纯 fire 的写仅保证最终一致。
abstract class DbWriter {
  /// 启动并初始化写层。
  ///
  /// - 非 ohos：后台写隔离 [_IsolateDbWriter]（fsync/写盘离开 UI 线程）。
  /// - ohos：同 isolate 内联写 [_InlineDbWriter]（fork 引擎上跨 isolate 方案
  ///   不可用，见该类头注释——曾致 main() 挂死、白屏）。
  ///
  /// print 分段日志：写层是启动链白屏排查的关键分段，本文件保持纯 Dart
  /// 不依赖 foundation，故用 print。
  static Future<DbWriter> start(String dbPath) async {
    if (Platform.operatingSystem == 'ohos') {
      return _InlineDbWriter.start(dbPath);
    }
    return _IsolateDbWriter.start(dbPath);
  }

  // ---------- 主线程侧 API ----------

  /// 排队写并等待落库（自动与其他排队写合并为单事务）。
  Future<void> exec(String sql, [List<Object?>? args]);

  /// 排队写，不等落库（最终一致；settings 内存缓存/outbox uuid 等场景用）。
  void execFire(String sql, [List<Object?>? args]);

  /// 写并返回受影响行数。
  Future<int> execUpdated(String sql, [List<Object?>? args]);

  /// 写并返回 lastInsertRowId。
  Future<int> execInsert(String sql, List<Object?> args);

  /// 执行一条复合写操作（多语句/内部读依赖，运行在写连接上保证一致性）。
  Future<T> op<T>(String name, Map<String, dynamic> args);

  /// 批量执行同类复合操作：合并为**单个事务**（同步 pull 落库主路径）。
  Future<void> opBatch(String name, List<Map<String, dynamic>> argList);

  /// 等待当前排队写全部落库。
  Future<void> flush();

  /// 优雅关闭：等待排队写落库后释放写层。
  Future<void> close();

  /// 立即关闭（fire-and-forget）：丢弃未落库排队写。
  /// 调用方负责先 [flush]；供同步 close()（如测试收尾）使用。
  void dispose();
}

// ---------- 后台写隔离实现（非 ohos） ----------

class _IsolateDbWriter implements DbWriter {
  _IsolateDbWriter._(this._cmd, this._isolate) {
    _resp.listen((raw) => _onResp(raw));
  }

  final SendPort _cmd;
  final Isolate _isolate;
  final ReceivePort _resp = ReceivePort();
  final Map<int, Completer<Object?>> _out = {};
  int _seq = 0;
  bool _closed = false;

  /// 启动并初始化：开连接 → WAL/NORMAL/busy_timeout → 建表迁移（幂等）。
  static Future<DbWriter> start(String dbPath) async {
    final boot = ReceivePort();
    print('[db-writer] spawning');
    final isolate = await Isolate.spawn(_writerEntry, boot.sendPort,
        debugName: 'local-db-writer');
    print('[db-writer] spawn done');
    final cmd = await boot.first as SendPort;
    print('[db-writer] boot port received');
    boot.close();
    final w = _IsolateDbWriter._(cmd, isolate);
    await w._send('init', {'path': dbPath});
    print('[db-writer] init done');
    return w;
  }

  @override
  Future<void> exec(String sql, [List<Object?>? args]) async {
    await _send('exec', {'sql': sql, 'args': args ?? const []});
  }

  @override
  void execFire(String sql, [List<Object?>? args]) {
    // seq 必须带：写隔离侧按 `m['seq'] as int` 取标识，缺失会在类型转换处抛错，
    // 而这条命令是 fire（reply 为 null）——原先没有任何人回包也没有日志，于是
    // **整条写被静默丢弃**：settingsSet / touchCache 等全靠 fire 的写入从来没
    // 落过盘，只有进程内的内存缓存看着是对的，一重启就丢（同步游标、播放模式、
    // 缓存 LRU 时间等）。
    _cmd.send({
      't': 'execFire',
      'seq': _seq++,
      'sql': sql,
      'args': args ?? const [],
      'reply': null,
    });
  }

  @override
  Future<int> execUpdated(String sql, [List<Object?>? args]) async {
    final v =
        await _send('execUpdated', {'sql': sql, 'args': args ?? const []});
    return v as int;
  }

  @override
  Future<int> execInsert(String sql, List<Object?> args) async {
    final v = await _send('execInsert', {'sql': sql, 'args': args});
    return v as int;
  }

  @override
  Future<T> op<T>(String name, Map<String, dynamic> args) async {
    final v = await _send('op', {'name': name, 'args': args});
    return v as T;
  }

  @override
  Future<void> opBatch(String name, List<Map<String, dynamic>> argList) async {
    if (argList.isEmpty) return;
    final sw = Stopwatch()..start();
    await _send('opBatch', {'name': name, 'argList': argList});
    if (sw.elapsedMilliseconds >= 16) {
      perfLog('db.opBatch isolate',
          '$name ${sw.elapsedMilliseconds}ms rows=${argList.length}');
    }
  }

  @override
  Future<void> flush() async {
    await _send('flush', const {});
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      // 先发 close 再置 _closed：_send 会拒绝已关闭的写层。
      await _send('close', const {});
    } finally {
      _closed = true;
      _resp.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _resp.close();
  }

  Future<Object?> _send(String t, Map<String, dynamic> extra) {
    // close()/dispose() 之后回包端口已关、隔离已杀：再排队就永远等不到回包。
    // 这里直接失败，让调用方拿到明确的 StateError 而不是挂死——退出流程里
    // 收尾顺序略有出入就会静默卡住，非常难查。
    if (_closed) {
      return Future<Object?>.error(StateError('db-writer: 写层已关闭，拒绝执行 $t'));
    }
    final seq = _seq++;
    final c = Completer<Object?>();
    _out[seq] = c;
    _cmd.send(<String, dynamic>{
      't': t,
      'seq': seq,
      'reply': _resp.sendPort,
      ...extra,
    });
    return c.future;
  }

  void _onResp(Object raw) {
    final m = raw as Map<String, dynamic>;
    final seq = m['seq'] as int;
    final ok = m['ok'] as bool;
    final c = _out.remove(seq);
    if (c == null) return;
    if (ok) {
      c.complete(m['value']);
    } else {
      c.completeError(StateError('db-writer: ${m['error']}'));
    }
  }
}

// ---------- ohos 内联写实现 ----------

/// ohos 上的写层退化实现：同 isolate 第二条连接直写（PoC 级）。
///
/// 为什么不用写隔离（真机取证 2026-09，白屏根因链第二层）：
/// 1. `open.overrideForAll`（setupOhos 注入的 libsqlite3.so 加载）是库级
///    可变状态，**不随 Isolate.spawn 进入子 isolate**——子 isolate 里
///    `sqlite3.open` 走默认加载器，'ohos' 不在 sqlite3 2.9.4 的已知平台
///    枚举内，必抛 `UnsupportedError`（load_library.dart `_defaultOpen`）；
/// 2. fork 引擎（HAR 1.0.0-4cbeea6a36f1）上子 isolate 能否可靠拉起存疑
///    （VM service 实测 isolate 组内无子 isolate 成员）。
/// 两者叠加：写隔离的 init 回执必然失败/缺席，而 [DbWriter.start] 位于
/// main() 的 await 链上（无兜底）→ runApp 永不执行 → 永久白屏。
///
/// PoC 取舍：写在本 isolate 同步执行。WAL 下与主读连接并发安全
/// （busy_timeout=30s），复合操作复用隔离版的 `_runOp`/`_runOpBatch`；
/// 写盘占用 UI 线程的窗口已按「批量分片 + 片间让出事件循环」压缩
/// （见 [opBatch]，同步 pull 的千级快照行不再是一个巨型同步块）。
/// 正式版随引擎 isolate 修复切回 [_IsolateDbWriter]。
class _InlineDbWriter implements DbWriter {
  _InlineDbWriter._(this._db);

  /// 内联批量写分片大小：每片一个事务，片间让出事件循环。
  /// 200 行量级在 ohos 上可控制在单帧预算附近（快照行以主键 upsert 为主）。
  static const int _inlineBatchChunk = 200;

  final Database _db;
  bool _closed = false;

  static Future<DbWriter> start(String dbPath) async {
    // 加载 override 已由 setupOhos 在本 isolate 注入（main() 首步）。
    final db = sqlite3.open(dbPath);
    db.execute('PRAGMA synchronous=NORMAL;');
    db.execute('PRAGMA busy_timeout=30000;');
    db.execute('PRAGMA wal_autocheckpoint=1000;');
    applySchema(db);
    // 启动一次性迁移（探测 + 迁移）在写连接内完成：主线程 open() 不再做
    // 任何读扫描（曾把 play_meta 的 instr 全表探测挂在启动 await 链上）。
    _migrateLegacyRefsIfNeeded(db);
    print('[db-writer] ohos 内联模式就绪');
    return _InlineDbWriter._(db);
  }

  @override
  Future<void> exec(String sql, [List<Object?>? args]) async {
    _db.execute(sql, args ?? const []);
  }

  @override
  void execFire(String sql, [List<Object?>? args]) {
    _db.execute(sql, args ?? const []);
  }

  @override
  Future<int> execUpdated(String sql, [List<Object?>? args]) async {
    _db.execute(sql, args ?? const []);
    return _db.updatedRows;
  }

  @override
  Future<int> execInsert(String sql, List<Object?> args) async {
    _db.execute(sql, args);
    return _db.lastInsertRowId;
  }

  @override
  Future<T> op<T>(String name, Map<String, dynamic> args) async {
    final sw = Stopwatch()..start();
    final r = _runOp(_db, name, args) as T;
    if (sw.elapsedMilliseconds >= 16) {
      perfLog('db.op inline', '$name ${sw.elapsedMilliseconds}ms');
    }
    return r;
  }

  @override
  Future<void> opBatch(String name, List<Map<String, dynamic>> argList) async {
    if (argList.isEmpty) return;
    final swAll = Stopwatch()..start();
    if (name == 'applyPlaylistSnapshots') {
      // 逐歌单一个事务、片间让出：单歌单条目循环仍是长块，但多歌单批量
      // （pull 常见）不再拼成一个巨型同步块。
      var i = 0;
      var slow = 0;
      for (final p in argList) {
        i++;
        final sw = Stopwatch()..start();
        _runOpBatch(_db, name, [p]);
        final ms = sw.elapsedMilliseconds;
        if (ms >= 16) {
          slow++;
          final items = p['items'] is List ? (p['items'] as List).length : 0;
          perfLog('db.opBatch inline',
              '$name #$i uuid=${p['client_uuid']} items=$items ${ms}ms');
        }
        await Future<void>.delayed(Duration.zero);
      }
      perfLog('db.opBatch inline total',
          '$name lists=${argList.length} slow=$slow ${swAll.elapsedMilliseconds}ms');
      return;
    }
    // 歌曲权重快照 pull 主路径：整页可达成千上万行，整批事务会长时间独占
    // UI 线程（ohos 内联写）。切成小事务，片间让出事件循环，让动画/输入
    // 有机会插进来。cursor 在整页应用完成后才推进，中途失败/退出由重拉
    // 幂等收敛（快照应用本身幂等）。
    var chunks = 0;
    var slowChunks = 0;
    for (final chunk in chunkedSublists(argList, _inlineBatchChunk)) {
      chunks++;
      final sw = Stopwatch()..start();
      _runOpBatch(_db, name, chunk);
      final ms = sw.elapsedMilliseconds;
      if (ms >= 16) {
        slowChunks++;
        perfLog('db.opBatch inline',
            '$name chunk#$chunks rows=${chunk.length} ${ms}ms');
      }
      await Future<void>.delayed(Duration.zero);
    }
    perfLog('db.opBatch inline total',
        '$name rows=${argList.length} chunks=$chunks slow=$slowChunks ${swAll.elapsedMilliseconds}ms');
  }

  @override
  Future<void> flush() async {
    // 内联写同步落库，无排队，无需冲刷。
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    _db.dispose();
  }
}

// ---------- 写隔离入口 ----------

/// 在后台 isolate 内打开数据库连接（写隔离与后台读快照共用）。
///
/// 后台 isolate 拿不到主 isolate 的 `open.overrideFor`（测试即如此覆盖）；
/// Linux 发行版又常只有 `libsqlite3.so.0` 而无 `-dev` 符号链接，sqlite3
/// 包默认只试前者。故在此按候选名解析一次，保证后台 isolate 在任何平台都能起库。
Database openIsolateDatabase(String path) {
  if (Platform.isLinux) {
    open.overrideFor(OperatingSystem.linux, () {
      Object? last;
      for (final name in const ['libsqlite3.so', 'libsqlite3.so.0']) {
        try {
          return DynamicLibrary.open(name);
        } on Object catch (e) {
          last = e;
        }
      }
      throw StateError('无法加载 libsqlite3：$last');
    });
  }
  return sqlite3.open(path);
}

void _writerEntry(SendPort boot) {
  print('[db-writer] entry running');
  final cmd = ReceivePort();
  boot.send(cmd.sendPort);
  Database? db;
  final pending = <_PendOp>[];
  Timer? timer;

  void reply(Map<String, dynamic> m, Object? value) {
    final rp = m['reply'];
    if (rp is SendPort) {
      rp.send({'seq': m['seq'], 'ok': true, 'value': value});
    }
  }

  void flushNow() {
    if (pending.isEmpty) return;
    timer?.cancel();
    timer = null;
    // 注意：必须复制一份，不能 `final ops = pending`（同一 List，clear 会把 ops 一起清空）。
    final ops = List<_PendOp>.of(pending);
    pending.clear();
    final conn = db;
    if (conn == null) {
      // 连接已被 close：如实回绝，绝不让等待方挂着。
      for (final o in ops) {
        o.reply?.send({'seq': o.seq, 'ok': false, 'error': '写连接已关闭'});
      }
      return;
    }
    if (ops.length == 1 && ops.single.reply == null) {
      // 单条 fire：autocommit，省一次 BEGIN/COMMIT。
      try {
        conn.execute(ops.single.sql, ops.single.args);
      } catch (e, st) {
        // 单条 fire 没有等待方，但失败必须留下痕迹——否则写丢了完全没人知道。
        _logWriteFailure(ops.single, e, st);
      }
      return;
    }
    // 每条一个 SAVEPOINT：单条失败（唯一键冲突、字段超长等）只回滚它自己，
    // 同批其余照常提交。
    //
    // 原来是一条失败就整批 ROLLBACK 再 rethrow，有两个后果：
    //   1) 同批最多 255 条无关的成功写入一起丢；
    //   2) rethrow 冒到 cmd.listen 的 catch，那里回的是「触发这次 flush 的那条
    //      消息」（第 257 条 / flush / close），而不是批里等回复的那些——于是
    //      批内所有 exec() 的 Future 永远收不到回包，调用方直接卡死。
    conn.execute('BEGIN');
    var sp = 0;
    for (final o in ops) {
      final name = 'sp_${sp++}';
      try {
        conn.execute('SAVEPOINT $name');
        conn.execute(o.sql, o.args);
        conn.execute('RELEASE $name');
      } catch (e, st) {
        try {
          conn.execute('ROLLBACK TO $name');
          conn.execute('RELEASE $name');
        } catch (_) {}
        o.error = '$e\n$st';
        _logWriteFailure(o, e, st);
      }
    }
    try {
      conn.execute('COMMIT');
    } catch (e, st) {
      // 致命错误（磁盘满 / IO 错）：整批都没落库，如实回报给所有等待方。
      try {
        conn.execute('ROLLBACK');
      } catch (_) {}
      for (final o in ops) {
        o.error ??= '批量提交失败：$e';
        _logWriteFailure(o, e, st);
      }
    }
    // 逐条回包：每条带 reply 的 op 都必须收到且只收到一个结果，绝不漏。
    for (final o in ops) {
      final err = o.error;
      if (err != null) {
        o.reply?.send({'seq': o.seq, 'ok': false, 'error': err});
      } else {
        o.reply?.send({'seq': o.seq, 'ok': true, 'value': null});
      }
    }
  }

  void armFlush() {
    if (pending.length >= 256) {
      flushNow();
      return;
    }
    if (timer != null) return;
    timer = Timer(const Duration(milliseconds: 2), flushNow);
  }

  cmd.listen((raw) {
    final m = raw as Map<String, dynamic>;
    final t = m['t'] as String;
    try {
      switch (t) {
        case 'init':
          db = openIsolateDatabase(m['path'] as String);
          db!.execute('PRAGMA synchronous=NORMAL;');
          db!.execute('PRAGMA busy_timeout=30000;');
          db!.execute('PRAGMA wal_autocheckpoint=1000;');
          applySchema(db!);
          // 历史 play_meta ENCODE 行的一次性探测 + 迁移：此前在主连接/UI
          // 线程做 instr 全表探测（启动链上的同步扫描），现随 init 在写
          // 隔离内完成，open() 只需等 init 回执。
          _migrateLegacyRefsIfNeeded(db!);
          reply(m, null);
        case 'execFire':
        case 'exec':
          pending.add(_PendOp(
              m['sql'] as String,
              (m['args'] as List).cast<Object?>(),
              m['reply'] is SendPort ? m['reply'] as SendPort : null,
              // seq 只用于标识与回包配对；缺失时给个占位值，绝不能因为取不到它
              // 就把这条写整个丢掉（那正是之前 fire 全丢的根因）。
              m['seq'] is int ? m['seq'] as int : -1));
          armFlush();
        case 'execInsert':
        case 'execUpdated':
          flushNow();
          final stmt = db!.prepare(m['sql'] as String);
          int v;
          try {
            stmt.execute((m['args'] as List).cast<Object?>());
            v = t == 'execInsert' ? db!.lastInsertRowId : db!.updatedRows;
          } finally {
            stmt.dispose();
          }
          reply(m, v);
        case 'op':
          flushNow();
          reply(
              m,
              _runOp(db!, m['name'] as String,
                  (m['args'] as Map).cast<String, dynamic>()));
        case 'opBatch':
          flushNow();
          _runOpBatch(db!, m['name'] as String,
              (m['argList'] as List).cast<Map<String, dynamic>>());
          reply(m, null);
        case 'flush':
          flushNow();
          reply(m, null);
        case 'close':
          flushNow();
          db?.dispose();
          db = null;
          reply(m, null);
          cmd.close();
      }
    } catch (e, st) {
      final rp = m['reply'];
      if (rp is SendPort) {
        rp.send({'seq': m['seq'], 'ok': false, 'error': '$e\n$st'});
      } else {
        print('[db-writer] 命令处理失败（无回包方）: $e\n$st');
      }
    }
  }, onError: (Object e, StackTrace st) {
    // 原先没有 onError：消息处理过程中抛出且未被上面 catch 覆盖的错误会变成
    // 未捕获的 isolate 异常，写隔离就此静默死掉——之后所有写入都只进队列，
    // 再无任何报错，看起来像「设置没保存」。
    print('[db-writer] 监听错误（写隔离即将不可用）: $e\n$st');
  });
}

class _PendOp {
  final String sql;
  final List<Object?> args;
  final SendPort? reply;
  final int seq;
  _PendOp(this.sql, this.args, this.reply, this.seq);

  /// 本条自身的执行错误（逐条隔离后才有意义）；非空表示这条没落库。
  String? error;
}

/// 写失败的可见化：fire 类写入没有等待方，失败若不记就等于凭空消失。
/// 保留原有的 `[db-writer]` 前缀，便于和既有日志一起过滤。
void _logWriteFailure(_PendOp op, Object e, StackTrace st) {
  final sql = op.sql.length > 120 ? '${op.sql.substring(0, 120)}…' : op.sql;
  print('[db-writer] 写入失败（seq=${op.seq}, reply=${op.reply != null}）: $e\n'
      '  sql: $sql');
}

// ---------- 复合写操作（全部运行在写连接上） ----------

Object? _runOp(Database db, String name, Map<String, dynamic> a) {
  switch (name) {
    case 'pendingOutbox':
      return _opPendingOutbox(db, a);
    case 'pendingOutboxCount':
      return db
          .select('SELECT COUNT(*) c FROM weight_outbox WHERE acked=0')
          .first['c'] as int;
    case 'upsertSongs':
      _opUpsertSongs(db, (a['rows'] as List).cast<Map<String, dynamic>>());
      return null;
    case 'upsertPlayMeta':
      _opUpsertPlayMeta(db, a);
      return null;
    case 'setFavorite':
      _opSetFavorite(db, a);
      return null;
    case 'applyWeightEvent':
      _opApplyWeightEvent(db, a);
      return null;
    case 'addPlaySec':
      _opAddPlaySec(db, a);
      return null;
    case 'applySongSnapshot':
      _opApplySongSnapshot(db, a);
      return null;
    case 'applySongSnapshotRaw':
      _opApplySongSnapshotRaw(db, a);
      return null;
    case 'applyPlaystateMirror':
      _opApplyPlaystateMirror(db, a);
      return null;
    case 'applyPlaylistSnapshot':
      _opApplyPlaylistSnapshot(db, a);
      return null;
    case 'applySourceSnapshot':
      return _opApplySourceSnapshot(db, a);
    case 'createPlaylist':
      return _opCreatePlaylist(db, a);
    case 'ensurePlaylistUuid':
      return _opEnsurePlaylistUuid(db, a);
    case 'addPlaylistItem':
      _opAddPlaylistItem(db, a);
      return null;
    case 'updateSongUserMeta':
      _opUpdateSongUserMeta(db, a);
      return null;
    case 'migrateMetaRefs':
      _opMigrateMetaRefs(db);
      return null;
    case 'clearMissing':
      _opClearMissing(db, a['sourceKey'] as String);
      return null;
    case 'deleteSong':
      _opDeleteSong(db, a['sourceKey'] as String, a['ref'] as String);
      return null;
    case 'movePlaylistItem':
      _opMovePlaylistItem(db, a);
      return null;
    case 'deletePlaylist':
      _opDeletePlaylist(db, a['id'] as int);
      return null;
    case 'deleteSource':
      _opDeleteSource(db, a['key'] as String);
      return null;
    case 'renameSource':
      _opRenameSource(db, a['oldKey'] as String, a['newKey'] as String);
      return null;
    case 'artistReconcile':
      _opArtistReconcile(db);
      return null;
    case 'artistUpsert':
      _opArtistUpsert(db, a);
      return null;
    case 'artistMergeMbid':
      return _opArtistMergeMbid(db, a);
    case 'artistRetry':
      _opArtistRetry(db, a);
      return null;
    case 'artistForceRetry':
      _opArtistForceRetry(db, a);
      return null;
    case 'artistMarkError':
      _opArtistMarkError(db, a);
      return null;
    case 'artistSetMembers':
      return _opArtistSetMembers(db, a);
    case 'artistMarkExpanded':
      _opArtistMarkExpanded(db, a);
      return null;
  }
  throw StateError('unknown writer op: $name');
}

void _runOpBatch(Database db, String name, List<Map<String, dynamic>> argList) {
  switch (name) {
    case 'applySongSnapshots':
      _inTx(db, () {
        for (final a in argList) {
          _opApplySongSnapshot(db, a);
        }
      });
      return;
    case 'applySongSnapshotsRaw':
      _inTx(db, () {
        for (final a in argList) {
          _opApplySongSnapshotRaw(db, a);
        }
      });
      return;
    case 'applyPlaylistSnapshots':
      _inTx(db, () {
        for (final a in argList) {
          _opApplyPlaylistSnapshotRaw(db, a);
        }
      });
      return;
  }
  throw StateError('unknown writer batch op: $name');
}

/// 单事务执行 [body]（各批 op 共用）。
void _inTx(Database db, void Function() body) {
  db.execute('BEGIN');
  try {
    body();
    db.execute('COMMIT');
  } catch (_) {
    try {
      db.execute('ROLLBACK');
    } catch (_) {}
    rethrow;
  }
}

/// 把 [list] 按 [size] 切成连续子列表（[size] < 1 时按 1）。
/// ohos 内联写按此分片落库并在片间让出事件循环（见 `_InlineDbWriter.opBatch`）。
List<List<T>> chunkedSublists<T>(List<T> list, int size) {
  final step = size < 1 ? 1 : size;
  final out = <List<T>>[];
  for (var start = 0; start < list.length; start += step) {
    final end = start + step < list.length ? start + step : list.length;
    out.add(list.sublist(start, end));
  }
  return out;
}

// ---------- 共享小工具（写连接内的读依赖） ----------

String _newUuid() {
  final r = Random.secure();
  final tail = List.generate(
      3, (_) => r.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0')).join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${tail.substring(0, 12)}';
}

String _sourceOfKey(String key) {
  final i = key.indexOf(':');
  return i > 0 ? key.substring(0, i) : key;
}

String? _sourceKeyOfUuid(Database db, String uuid) {
  if (uuid.isEmpty) return null;
  final rs = db.select('SELECT key FROM sources WHERE client_uuid=?', [uuid]);
  return rs.isEmpty ? null : rs.first['key'] as String;
}

/// 读当前 play_meta 行（写前合并用；空行返回默认权重）。
({int ls, int ds, double f, bool frozen, bool fav, String? sj, int ps})
    _curMeta(Database db, String sourceKey, String songRef) {
  final rs = db.select(
      'SELECT like_streak, dislike_streak, factor, frozen, is_favorite, song_json, play_sec '
      'FROM play_meta WHERE source_key=? AND song_ref=?',
      [sourceKey, songRef]);
  if (rs.isEmpty) {
    return (ls: 0, ds: 0, f: 1.0, frozen: false, fav: false, sj: null, ps: 0);
  }
  final r = rs.first;
  return (
    ls: r['like_streak'] as int,
    ds: r['dislike_streak'] as int,
    f: (r['factor'] as num).toDouble(),
    frozen: (r['frozen'] as int) != 0,
    fav: (r['is_favorite'] as int) != 0,
    sj: r['song_json'] as String?,
    ps: (r['play_sec'] as int?) ?? 0,
  );
}

/// 历史 ENCODE 形态旧行迁移到当前 ref（幂等，逻辑同 LocalIndex._migrateMetaRef）。
void _migrateRef(Database db, String sourceKey, String songRef) {
  final alts = webdavRefVariants(songRef).where((v) => v != songRef).toList();
  if (alts.isEmpty) return;
  final ph = alts.map((_) => '?').join(',');
  final rows = db.select(
      'SELECT song_ref, like_streak, dislike_streak, factor, frozen, is_favorite, song_json, play_sec '
      'FROM play_meta WHERE source_key=? AND song_ref IN ($ph)',
      [sourceKey, ...alts]);
  if (rows.isEmpty) return;
  Row best = rows.first;
  int score(Row r) =>
      ((r['is_favorite'] as int) == 1 ? 4 : 0) +
      (((r['song_json'] as String?)?.isNotEmpty ?? false) ? 2 : 0) +
      (((r['factor'] as num).toDouble() - 1.0).abs() > 0.01 ? 1 : 0);
  for (final r in rows.skip(1)) {
    if (score(r) > score(best)) best = r;
  }
  db.execute('DELETE FROM play_meta WHERE source_key=? AND song_ref IN ($ph)',
      [sourceKey, ...alts]);
  db.execute(
      'INSERT OR IGNORE INTO play_meta(source_key, song_ref, like_streak, dislike_streak, '
      'factor, frozen, is_favorite, song_json, play_sec) VALUES(?,?,?,?,?,?,?,?,?)',
      [
        sourceKey,
        songRef,
        best['like_streak'],
        best['dislike_streak'],
        best['factor'],
        best['frozen'],
        best['is_favorite'],
        best['song_json'],
        (best['play_sec'] as int?) ?? 0,
      ]);
}

// ---------- 操作实现 ----------

void _opUpsertPlayMeta(Database db, Map<String, dynamic> a) {
  final sourceKey = a['sourceKey'] as String;
  final songRef = a['songRef'] as String;
  final ls = a['likeStreak'] as int?;
  final ds = a['dislikeStreak'] as int?;
  final f = a['factor'] as double?;
  final frozen = a['frozen'] as bool?;
  final fav = a['favorite'] as bool?;
  final sj = a['songJson'] as String?;
  final ps = a['playSec'] as int?;
  _migrateRef(db, sourceKey, songRef);
  final cur = _curMeta(db, sourceKey, songRef);
  db.execute('''
    INSERT INTO play_meta(source_key, song_ref, like_streak, dislike_streak,
      factor, frozen, is_favorite, song_json, play_sec)
    VALUES(?,?,?,?,?,?,?,?,?)
    ON CONFLICT(source_key, song_ref) DO UPDATE SET
      like_streak = excluded.like_streak,
      dislike_streak = excluded.dislike_streak,
      factor = excluded.factor,
      frozen = excluded.frozen,
      is_favorite = excluded.is_favorite,
      song_json = COALESCE(excluded.song_json, play_meta.song_json),
      play_sec = excluded.play_sec
  ''', [
    sourceKey,
    songRef,
    ls ?? cur.ls,
    ds ?? cur.ds,
    f ?? cur.f,
    (frozen ?? cur.frozen) ? 1 : 0,
    (fav ?? cur.fav) ? 1 : 0,
    sj ?? cur.sj,
    ps ?? cur.ps,
  ]);
}

/// 累计播放时长（秒）：`play_sec += seconds`。
///
/// 在写连接内累加（与 [addPlaySec] 调用方语义一致），不读-改-写两段式，
/// 避免并发 tick 丢增量。歌曲切换/暂停/退出时由播放器 flush 调用。
void _opAddPlaySec(Database db, Map<String, dynamic> a) {
  final sourceKey = a['sourceKey'] as String;
  final songRef = a['songRef'] as String;
  final sec = a['seconds'] as int;
  if (sec <= 0) return;
  _migrateRef(db, sourceKey, songRef);
  final cur = _curMeta(db, sourceKey, songRef);
  db.execute('''
    INSERT INTO play_meta(source_key, song_ref, like_streak, dislike_streak,
      factor, frozen, is_favorite, song_json, play_sec)
    VALUES(?,?,?,?,?,?,?,?,?)
    ON CONFLICT(source_key, song_ref) DO UPDATE SET
      play_sec = COALESCE(play_meta.play_sec, 0) + ?
  ''', [
    sourceKey,
    songRef,
    cur.ls,
    cur.ds,
    cur.f,
    cur.frozen ? 1 : 0,
    cur.fav ? 1 : 0,
    cur.sj,
    sec,
    sec,
  ]);
}

void _opSetFavorite(Database db, Map<String, dynamic> a) {
  final sourceKey = a['sourceKey'] as String;
  final songRef = a['songRef'] as String;
  final fav = a['favorite'] as bool;
  final songJson = a['songJson'] as String?;
  _migrateRef(db, sourceKey, songRef);
  final cur = _curMeta(db, sourceKey, songRef);
  db.execute('''
    INSERT INTO play_meta(source_key, song_ref, like_streak, dislike_streak,
      factor, frozen, is_favorite, song_json)
    VALUES(?,?,?,?,?,?,?,?)
    ON CONFLICT(source_key, song_ref) DO UPDATE SET
      is_favorite = excluded.is_favorite,
      song_json = COALESCE(excluded.song_json, play_meta.song_json)
  ''', [
    sourceKey,
    songRef,
    cur.ls,
    cur.ds,
    cur.f,
    cur.frozen ? 1 : 0,
    fav ? 1 : 0,
    songJson,
  ]);
}

double _clampDb(double v, double lo, double hi) => v.clamp(lo, hi).toDouble();

/// 权重/收藏事件的读-改-写（complete/skip/liked/unfavorite/disliked/reset）。
///
/// 必须在写连接内一次算完：若按「主连接读 streak/factor → 写绝对值」两段做，
/// 连续两次事件（如连续完播）第二次会读到尚未提交的旧值而覆盖第一次（丢更新）。
/// 上下界/step 由调用方（SongWeightStore）传入，避免常量双份维护。
void _opApplyWeightEvent(Database db, Map<String, dynamic> a) {
  final sourceKey = a['sourceKey'] as String;
  final songRef = a['songRef'] as String;
  final event = a['event'] as String;
  final minF = (a['minFactor'] as num).toDouble();
  final maxF = (a['maxFactor'] as num).toDouble();
  final step = (a['step'] as num).toDouble();
  final defF = (a['defaultFactor'] as num).toDouble();
  final songJson = a['songJson'] as String?;
  _migrateRef(db, sourceKey, songRef);
  final cur = _curMeta(db, sourceKey, songRef);
  var ls = cur.ls;
  var ds = cur.ds;
  var f = cur.f;
  var frozen = cur.frozen;
  var fav = cur.fav;
  switch (event) {
    case 'complete':
      ls = cur.ls + 1;
      ds = 0;
      if (!cur.frozen && ls >= 3) {
        ls = 0;
        f = _clampDb(cur.f + step, minF, maxF);
      }
      break;
    case 'skip':
      ds = cur.ds + 1;
      ls = 0;
      if (!cur.frozen && ds >= 3) {
        ds = 0;
        f = _clampDb(cur.f - step, minF, maxF);
      }
      break;
    case 'complete_manual':
      // 手动点播自然完播：直接提高一档权重 + 清空双 streak（不依赖门槛）。
      // 「不喜欢」锁定态不动权重（与 complete/skip 一致，锁定最低优先级最高）。
      ls = 0;
      ds = 0;
      if (!cur.frozen) f = _clampDb(cur.f + step, minF, maxF);
      break;
    case 'liked':
      ls = 0;
      ds = 0;
      f = maxF;
      frozen = false;
      fav = true;
      break;
    case 'unfavorite':
      ls = 0;
      ds = 0;
      if (!cur.frozen) f = defF;
      fav = false;
      break;
    case 'disliked':
      final on = a['enabled'] as bool;
      ls = 0;
      ds = 0;
      f = on ? minF : defF;
      frozen = on;
      break;
    case 'reset':
      ls = 0;
      ds = 0;
      f = defF;
      frozen = false;
      break;
    default:
      throw StateError('unknown weight event: $event');
  }
  db.execute('''
    INSERT INTO play_meta(source_key, song_ref, like_streak, dislike_streak,
      factor, frozen, is_favorite, song_json)
    VALUES(?,?,?,?,?,?,?,?)
    ON CONFLICT(source_key, song_ref) DO UPDATE SET
      like_streak = excluded.like_streak,
      dislike_streak = excluded.dislike_streak,
      factor = excluded.factor,
      frozen = excluded.frozen,
      is_favorite = excluded.is_favorite,
      song_json = COALESCE(excluded.song_json, play_meta.song_json)
  ''', [
    sourceKey,
    songRef,
    ls,
    ds,
    f,
    frozen ? 1 : 0,
    fav ? 1 : 0,
    songJson ?? cur.sj,
  ]);
}

void _opApplySongSnapshot(Database db, Map<String, dynamic> a) {
  final songRef = a['songRef'] as String;
  final source = a['source'] as String?;
  final sourceId = a['sourceId'] as String?;
  final ls = a['likeStreak'] as int;
  final ds = a['dislikeStreak'] as int;
  final factor = a['factor'] as double;
  final frozen = a['frozen'] as bool;
  final favorite = a['favorite'] as bool;
  final playSec = a['playSec'] as int?;

  void write(String key, String ref) {
    // 累计播放时长是单调量：快照值只增不减（服务端行级 LWW 可能比本地小）。
    final cur = _curMeta(db, key, ref);
    _opUpsertPlayMeta(db, {
      'sourceKey': key,
      'songRef': ref,
      'likeStreak': ls,
      'dislikeStreak': ds,
      'factor': factor,
      'frozen': frozen,
      'favorite': favorite,
      'playSec': playSec == null ? null : (playSec > cur.ps ? playSec : cur.ps),
    });
  }

  final byUuid = sourceId == null ? null : _sourceKeyOfUuid(db, sourceId);
  if (byUuid != null) {
    write(byUuid, songRef);
    return;
  }
  write('server', songRef);
  if (source == null || source.isEmpty) return;
  final refs = <String>{songRef, ...webdavRefVariants(songRef)};
  for (final v in refs) {
    final rows =
        db.select('SELECT source_key, ref FROM idx_songs WHERE ref=?', [v]);
    for (final r in rows) {
      final key = r['source_key'] as String;
      if (key == 'server') continue;
      if (_sourceOfKey(key) != source) continue;
      write(key, r['ref'] as String);
    }
  }
}

/// pull 歌曲权重快照·服务端原始形态直通（pull 主路径）：字段映射在写连接内
/// 完成，UI isolate 不做逐条映射。载荷形态见 `/sync/pull` 的 songs 快照。
void _opApplySongSnapshotRaw(Database db, Map<String, dynamic> a) {
  final ref = a['source_ref'] as String?;
  if (ref == null || ref.isEmpty) return;
  _opApplySongSnapshot(db, {
    'songRef': ref,
    'source': a['source'],
    'sourceId': a['source_id'],
    'likeStreak': (a['like_streak'] as num?)?.toInt() ?? 0,
    'dislikeStreak': (a['dislike_streak'] as num?)?.toInt() ?? 0,
    'factor': (a['weight'] as num?)?.toDouble() ?? 1.0,
    'frozen': a['frozen'] == true,
    'favorite': a['is_favorite'] == true,
    // 老服务端快照没有 play_sec（null = 不参与覆盖，本地累计值保留）
    'playSec': (a['play_sec'] as num?)?.toInt(),
  });
}

void _opUpsertSongs(Database db, List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return;
  db.execute('BEGIN');
  try {
    final stmt = db.prepare('''
      INSERT INTO idx_songs(source_key, ref, title, artist, album, album_artist, track_no, year,
        genre, duration, format, size, mtime, etag, cover_path, is_favorite, missing, url, meta_read)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,0,?,CASE WHEN ? IS NOT NULL THEN 1 ELSE 0 END)
      ON CONFLICT(source_key, ref) DO UPDATE SET
        title=CASE
          WHEN idx_songs.user_edited=1 THEN idx_songs.title
          WHEN ? THEN COALESCE(NULLIF(excluded.title, ''), idx_songs.title)
          ELSE COALESCE(idx_songs.title, excluded.title)
        END,
        artist=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.artist
          ELSE COALESCE(NULLIF(excluded.artist, ''), idx_songs.artist) END,
        album=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.album
          ELSE COALESCE(NULLIF(excluded.album, ''), idx_songs.album) END,
        album_artist=CASE WHEN idx_songs.user_edited=1 THEN idx_songs.album_artist
          ELSE COALESCE(NULLIF(excluded.album_artist, ''), idx_songs.album_artist) END,
        track_no=COALESCE(excluded.track_no, idx_songs.track_no),
        year=COALESCE(excluded.year, idx_songs.year),
        genre=COALESCE(excluded.genre, idx_songs.genre),
        duration=COALESCE(excluded.duration, idx_songs.duration),
        format=excluded.format, size=excluded.size, mtime=excluded.mtime,
        etag=COALESCE(excluded.etag, idx_songs.etag),
        cover_path=COALESCE(excluded.cover_path, idx_songs.cover_path),
        url=COALESCE(excluded.url, idx_songs.url),
        meta_read=CASE WHEN excluded.duration IS NOT NULL THEN 1 ELSE 0 END,
        missing=0
    ''');
    try {
      for (final s in rows) {
        stmt.execute([
          s['sourceKey'],
          s['ref'],
          s['title'],
          s['artist'],
          s['album'],
          s['albumArtist'],
          s['trackNo'],
          s['year'],
          s['genre'],
          s['duration'],
          s['format'],
          s['size'],
          s['mtime'],
          s['etag'],
          s['coverPath'],
          s['url'],
          s['duration'],
          (s['titleFromMeta'] as bool) ? 1 : 0,
        ]);
      }
    } finally {
      stmt.dispose();
    }
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _opApplyPlaylistSnapshot(Database db, Map<String, dynamic> a) {
  final uuid = a['uuid'] as String;
  final name = a['name'] as String;
  final description = a['description'] as String?;
  final deleted = a['deleted'] as bool;
  final items = (a['items'] as List).cast<Map<String, dynamic>>();

  final existing =
      db.select('SELECT id FROM playlists WHERE client_uuid=?', [uuid]);
  final id = existing.isEmpty ? null : existing.first['id'] as int;
  if (deleted) {
    if (id != null) _opDeletePlaylist(db, id);
    return;
  }
  final int pid;
  if (id == null) {
    db.execute(
        'INSERT INTO playlists(name, description, created_at, client_uuid, deleted) '
        'VALUES(?,?,?,?,0)',
        [name, description, DateTime.now().toIso8601String(), uuid]);
    pid = db.lastInsertRowId;
  } else {
    db.execute('UPDATE playlists SET name=?, description=? WHERE id=?',
        [name, description, id]);
    pid = id;
  }
  db.execute('DELETE FROM playlist_items WHERE playlist_id=? AND source_key=?',
      [pid, 'server']);

  final existingCovers = <String, String>{};
  for (final r in db.select(
      'SELECT source_key, song_ref, cover_path FROM playlist_items '
      'WHERE playlist_id=? AND cover_path IS NOT NULL',
      [pid])) {
    existingCovers['${r['source_key']}|${r['song_ref']}'] =
        r['cover_path'] as String;
  }
  for (final it in items) {
    String key = 'server';
    final resolved = it['sourceId'] == null
        ? null
        : _sourceKeyOfUuid(db, it['sourceId'] as String);
    if (resolved != null) {
      key = resolved;
    } else if (it['source'] != null && (it['source'] as String).isNotEmpty) {
      final kind = it['source'] as String;
      final peers = db.select('SELECT key FROM sources WHERE kind=?', [kind]);
      if (peers.length == 1) key = peers.first['key'] as String;
    }
    final songRef = it['songRef'] as String;
    String? cover = existingCovers['$key|$songRef'];
    if (cover == null) {
      for (final v in webdavRefVariants(songRef)) {
        cover = existingCovers['$key|$v'];
        if (cover != null) break;
      }
    }
    if (cover == null) {
      final rows = db.select(
          'SELECT cover_path FROM idx_songs WHERE source_key=? AND ref=?',
          [key, songRef]);
      if (rows.isNotEmpty) cover = rows.first['cover_path'] as String?;
    }
    db.execute(
        'DELETE FROM playlist_items WHERE playlist_id=? AND source_key=? AND song_ref=?',
        [pid, key, songRef]);
    db.execute('''
      INSERT INTO playlist_items(playlist_id, source_key, song_ref, title, artist,
        album, cover_path, sort_order, added_at, source)
      VALUES(?,?,?,?,?,?,?,?,?,?)
    ''', [
      pid,
      key,
      songRef,
      it['title'],
      it['artist'],
      it['album'],
      cover,
      it['sortOrder'],
      DateTime.now().toIso8601String(),
      it['source'],
    ]);
  }
}

/// pull 歌单快照·服务端原始形态直通：uuid/条目解析在写连接内完成。
void _opApplyPlaylistSnapshotRaw(Database db, Map<String, dynamic> p) {
  final uuid = p['client_uuid'] as String?;
  if (uuid == null || uuid.isEmpty) return;
  final items = <Map<String, dynamic>>[];
  final rawItems = p['items'];
  if (rawItems is List) {
    for (final it in rawItems) {
      if (it is! Map) continue;
      final m = it.cast<String, dynamic>();
      final ref = m['source_ref'] as String?;
      if (ref == null || ref.isEmpty) continue;
      items.add({
        'sourceId': m['source_id'],
        'source': m['source'],
        'songRef': ref,
        'title': (m['title'] as String?) ?? 'Unknown',
        'artist': m['artist'],
        'album': m['album'],
        'sortOrder': (m['sort_order'] as num?)?.toInt() ?? 0,
      });
    }
  }
  _opApplyPlaylistSnapshot(db, {
    'uuid': uuid,
    'name': (p['name'] as String?) ?? '未命名',
    'description': p['description'],
    'deleted': p['deleted'] == true,
    'items': items,
  });
}

/// pull 断点镜像·服务端原始形态直通：歌单存在性判定 + 墓碑清理 + upsert
/// 全在写连接内完成（原先 playlistIdOfUuid 是 UI 线程同步查询）。
void _opApplyPlaystateMirror(Database db, Map<String, dynamic> a) {
  final uuid = a['client_uuid'] as String?;
  if (uuid == null || uuid.isEmpty) return;
  // 歌单已在本地（硬）删除 → 镜像无意义，清掉（不复活已删歌单）。
  final exists =
      db.select('SELECT 1 FROM playlists WHERE client_uuid=?', [uuid]);
  if (exists.isEmpty) {
    db.execute('DELETE FROM breakpoint_mirror WHERE playlist_uuid=?', [uuid]);
    return;
  }
  final deep = a['deep_list'];
  db.execute(
      'INSERT INTO breakpoint_mirror(playlist_uuid, song_id, source_id, source, source_ref, '
      'position_ms, deep_list_json, updated_at, device_id) VALUES(?,?,?,?,?,?,?,?,?) '
      'ON CONFLICT(playlist_uuid) DO UPDATE SET '
      'song_id=excluded.song_id, source_id=excluded.source_id, source=excluded.source, '
      'source_ref=excluded.source_ref, position_ms=excluded.position_ms, '
      'deep_list_json=excluded.deep_list_json, '
      'updated_at=excluded.updated_at, device_id=excluded.device_id',
      [
        uuid,
        (a['song_id'] as num?)?.toInt(),
        a['source_id'],
        a['source'],
        a['source_ref'],
        (a['position_ms'] as num?)?.toInt() ?? 0,
        deep is List ? jsonEncode(deep) : null,
        (a['updated_at'] as String?) ?? DateTime.now().toIso8601String(),
        null,
      ]);
}

bool _opApplySourceSnapshot(Database db, Map<String, dynamic> a) {
  final uuid = a['uuid'] as String;
  final kind = a['kind'] as String;
  final name = a['name'] as String?;
  final addr = a['address'] as String;
  final config = (a['config'] as Map?)?.cast<String, dynamic>();
  final enabled = a['enabled'] as bool;
  final deleted = a['deleted'] as bool;
  if (!isSyncableKind(kind)) return false;
  String? hitKey;
  final rs =
      db.select('SELECT key, config FROM sources WHERE client_uuid=?', [uuid]);
  if (rs.isNotEmpty) {
    hitKey = rs.first['key'] as String;
  }
  if (hitKey == null && !deleted && addr.isNotEmpty) {
    for (final r in db
        .select('SELECT key, kind, config FROM sources WHERE kind=?', [kind])) {
      Map<String, dynamic> cfg = const {};
      try {
        cfg = jsonDecode(r['config'] as String) as Map<String, dynamic>;
      } catch (_) {}
      if (sourceAddressOf(kind, cfg) == normalizeSourceAddress(kind, addr)) {
        db.execute(
            'UPDATE sources SET client_uuid=? WHERE key=?', [uuid, r['key']]);
        hitKey = r['key'] as String;
        break;
      }
    }
  }
  if (deleted) {
    if (hitKey == null) return false;
    _opDeleteSource(db, hitKey);
    return true;
  }
  final cfgJson = jsonEncode(<String, dynamic>{...?config});
  if (hitKey != null) {
    final fallbackName = hitKey.contains(':')
        ? hitKey.substring(hitKey.indexOf(':') + 1)
        : hitKey;
    db.execute(
        'UPDATE sources SET kind=?, name=?, config=?, enabled=? WHERE key=?',
        [kind, name ?? fallbackName, cfgJson, enabled ? 1 : 0, hitKey]);
    return true;
  }
  final suffix = name == null || name.isEmpty ? uuid.substring(0, 8) : name;
  var key = '$kind:$suffix';
  var n = 2;
  while (db.select('SELECT 1 FROM sources WHERE key=?', [key]).isNotEmpty) {
    key = '$kind:$suffix($n)';
    n++;
  }
  db.execute(
      'INSERT INTO sources(key, kind, name, config, enabled, client_uuid) '
      'VALUES(?,?,?,?,?,?)',
      [key, kind, name ?? suffix, cfgJson, enabled ? 1 : 0, uuid]);
  return true;
}

int _opCreatePlaylist(Database db, Map<String, dynamic> a) {
  db.execute(
      'INSERT INTO playlists(name, description, created_at, client_uuid, deleted) '
      'VALUES(?,?,?,?,0)',
      [
        a['name'],
        a['description'],
        DateTime.now().toIso8601String(),
        _newUuid(),
      ]);
  return db.lastInsertRowId;
}

String _opEnsurePlaylistUuid(Database db, Map<String, dynamic> a) {
  final id = a['id'] as int;
  final rs = db.select('SELECT client_uuid FROM playlists WHERE id=?', [id]);
  if (rs.isEmpty) throw StateError('playlist not found: $id');
  var uuid = rs.first['client_uuid'] as String?;
  if (uuid == null || uuid.isEmpty) {
    uuid = _newUuid();
    db.execute('UPDATE playlists SET client_uuid=? WHERE id=?', [uuid, id]);
  }
  return uuid;
}

void _opAddPlaylistItem(Database db, Map<String, dynamic> a) {
  final playlistId = a['playlistId'] as int;
  final max = db.select(
      'SELECT COALESCE(MAX(sort_order),0) m FROM playlist_items WHERE playlist_id=?',
      [playlistId]).first['m'] as int;
  db.execute('''
    INSERT INTO playlist_items(playlist_id, source_key, song_ref, title, artist,
      album, cover_path, sort_order, added_at, source)
    VALUES(?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(playlist_id, source_key, song_ref) DO NOTHING
  ''', [
    playlistId,
    a['sourceKey'],
    a['songRef'],
    a['title'],
    a['artist'],
    a['album'],
    a['coverPath'],
    max + 1,
    DateTime.now().toIso8601String(),
    a['source'],
  ]);
}

void _opUpdateSongUserMeta(Database db, Map<String, dynamic> a) {
  final sourceKey = a['sourceKey'] as String;
  final songRef = a['songRef'] as String;
  final title = a['title'] as String?;
  final artist = a['artist'] as String?;
  final album = a['album'] as String?;
  final albumArtist = a['albumArtist'] as String?;
  db.execute('''
    UPDATE idx_songs SET
      title=CASE WHEN ? IS NULL THEN title ELSE NULLIF(?, '') END,
      artist=CASE WHEN ? IS NULL THEN artist ELSE NULLIF(?, '') END,
      album=CASE WHEN ? IS NULL THEN album ELSE NULLIF(?, '') END,
      album_artist=CASE WHEN ? IS NULL THEN album_artist ELSE NULLIF(?, '') END,
      user_edited=1
    WHERE source_key=? AND ref=?
  ''', [
    title,
    title,
    artist,
    artist,
    album,
    album,
    albumArtist,
    albumArtist,
    sourceKey,
    songRef,
  ]);
  final rows = db.select(
      'SELECT song_json FROM play_meta WHERE source_key=? AND song_ref=?',
      [sourceKey, songRef]);
  if (rows.isEmpty) return;
  final raw = rows.first['song_json'] as String?;
  if (raw == null || raw.isEmpty) return;
  try {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    if (title != null) j['title'] = title.isEmpty ? null : title;
    if (artist != null) j['artist'] = artist.isEmpty ? null : artist;
    if (album != null) j['albumName'] = album.isEmpty ? null : album;
    if (albumArtist != null) {
      j['albumArtist'] = albumArtist.isEmpty ? null : albumArtist;
    }
    db.execute(
        'UPDATE play_meta SET song_json=? WHERE source_key=? AND song_ref=?',
        [jsonEncode(j), sourceKey, songRef]);
  } catch (_) {
    // 快照损坏则忽略（下次收藏时重写）。
  }
  // 歌手字段被用户修改：身份映射随之校准（歌手处理.txt，与落库同事务提交）。
  _opArtistReconcile(db);
}

/// 启动一次性探测 + 迁移：write 连接 init 时调用（主线程 open() 不再扫描）。
/// 先探测有无含 `%` 的 ref（解码只可能改变这类串）：没有就跳过，不等一次
/// 全表解码扫描。
void _migrateLegacyRefsIfNeeded(Database db) {
  final legacy = db.select(
      "SELECT 1 FROM play_meta WHERE instr(song_ref, '%') > 0 LIMIT 1");
  if (legacy.isEmpty) return;
  _opMigrateMetaRefs(db);
}

/// 待上推事件（SyncEngine 用）：读取与 payload 解码都在写连接内完成，
/// UI isolate 只收已解码结果（同步后台化）。
List<Map<String, dynamic>> _opPendingOutbox(
    Database db, Map<String, dynamic> a) {
  final limit = (a['limit'] as num?)?.toInt() ?? 500;
  final rs = db.select(
      'SELECT event_uuid, type, payload, occurred_at FROM weight_outbox '
      'WHERE acked=0 ORDER BY rowid LIMIT ?',
      [limit]);
  return [
    for (final r in rs)
      {
        'eventUuid': r['event_uuid'] as String,
        'type': r['type'] as String,
        'occurredAt': r['occurred_at'] as String,
        'payload': jsonDecode(r['payload'] as String),
      }
  ];
}

/// 全表一次性迁移历史 ENCODE 形态的 play_meta 行（启动时由写入层 init 触发）。
///
/// 旧实现在 `playMetaOf` 读前按行迁移，会在主连接上写库（UI 线程 I/O）；
/// 现改为写隔离内一次扫完，之后所有读都是纯读。变体计算与逐行合并复用
/// [_migrateRef]（幂等：无旧行时不做任何写）。
void _opMigrateMetaRefs(Database db) {
  final rows = db.select('SELECT source_key, song_ref FROM play_meta');
  for (final r in rows) {
    final ref = r['song_ref'] as String;
    // 旧行为 ENCODE 文本，扫描入库的 ref 是解码态：能解码且与原串不同即为旧行，
    // 合并到解码态 ref（_migrateRef 幂等，保留收藏 > 有快照 > 权重偏离的行）。
    String canonical;
    try {
      canonical = Uri.decodeComponent(ref);
    } catch (_) {
      continue; // 已是解码态（或本身不是百分号编码），无历史行可并。
    }
    if (canonical == ref) continue;
    _migrateRef(db, r['source_key'] as String, canonical);
  }
}

void _opClearMissing(Database db, String sourceKey) {
  db.execute('''
    DELETE FROM idx_songs WHERE source_key=? AND missing=1
      AND COALESCE((SELECT p.is_favorite FROM play_meta p
                    WHERE p.source_key = idx_songs.source_key
                      AND p.song_ref = idx_songs.ref), 0) = 0
  ''', [sourceKey]);
}

void _opMovePlaylistItem(Database db, Map<String, dynamic> a) {
  final playlistId = a['playlistId'] as int;
  final itemId = a['itemId'] as int;
  final delta = a['delta'] as int;
  final rs = db.select(
      'SELECT id, sort_order FROM playlist_items WHERE playlist_id=? ORDER BY sort_order, id',
      [playlistId]);
  final items = [
    for (final r in rs) (id: r['id'] as int, sortOrder: r['sort_order'] as int),
  ];
  final i = items.indexWhere((x) => x.id == itemId);
  final j = i + delta;
  if (i < 0 || j < 0 || j >= items.length) return;
  db.execute('UPDATE playlist_items SET sort_order=? WHERE id=?',
      [items[j].sortOrder, items[i].id]);
  db.execute('UPDATE playlist_items SET sort_order=? WHERE id=?',
      [items[i].sortOrder, items[j].id]);
}

void _opDeletePlaylist(Database db, int id) {
  final rs = db.select('SELECT client_uuid FROM playlists WHERE id=?', [id]);
  final uuid = rs.isEmpty ? null : rs.first['client_uuid'] as String?;
  db.execute('DELETE FROM playlist_items WHERE playlist_id=?', [id]);
  db.execute('DELETE FROM playlists WHERE id=?', [id]);
  // 歌单删除同时清理其深层列表（隐藏历史栈）。
  if (uuid != null && uuid.isNotEmpty) {
    db.execute('DELETE FROM deep_lists WHERE playlist_uuid=?', [uuid]);
  }
}

void _opDeleteSource(Database db, String key) {
  db.execute('DELETE FROM sources WHERE key=?', [key]);
  db.execute('DELETE FROM idx_songs WHERE source_key=?', [key]);
  // 歌手身份映射随源删除清理（歌手处理.txt）。
  db.execute('DELETE FROM artist_song_map WHERE source_key=?', [key]);
}

/// 硬删一首歌的全部本地痕迹（阶段6：删除全删）。
/// 含索引/权重/歌词/歌单条目/歌手映射；缓存行由调用方另行清理。
void _opDeleteSong(Database db, String sourceKey, String ref) {
  db.execute('DELETE FROM idx_songs WHERE source_key=? AND ref=?', [sourceKey, ref]);
  db.execute('DELETE FROM play_meta WHERE source_key=? AND song_ref=?', [sourceKey, ref]);
  db.execute('DELETE FROM song_lyrics WHERE source_key=? AND ref=?', [sourceKey, ref]);
  db.execute('DELETE FROM playlist_items WHERE source_key=? AND song_ref=?', [sourceKey, ref]);
  db.execute('DELETE FROM artist_song_map WHERE source_key=? AND ref=?', [sourceKey, ref]);
}

void _opRenameSource(Database db, String oldKey, String newKey) {
  db.execute(
      'UPDATE OR REPLACE sources SET key=? WHERE key=?', [newKey, oldKey]);
  db.execute('UPDATE OR REPLACE idx_songs SET source_key=? WHERE source_key=?',
      [newKey, oldKey]);
  db.execute('UPDATE OR REPLACE play_meta SET source_key=? WHERE source_key=?',
      [newKey, oldKey]);
  db.execute(
      'UPDATE OR REPLACE playlist_items SET source_key=? WHERE source_key=?',
      [newKey, oldKey]);
  db.execute(
      'UPDATE OR REPLACE artist_song_map SET source_key=? WHERE source_key=?',
      [newKey, oldKey]);
}

// ---------- 歌手处理.txt：身份聚合写操作（写连接内一次性算完） ----------

void _opArtistGc(Database db) {
  db.execute('DELETE FROM artist_song_map WHERE (source_key, ref) NOT IN ('
      '  SELECT source_key, ref FROM idx_songs'
      '  WHERE missing=0 AND artist IS NOT NULL AND artist<>\'\')');
  db.execute('''
    DELETE FROM artist_canon WHERE artist_key IN (
      SELECT artist_key FROM artists a WHERE NOT EXISTS (
        SELECT 1 FROM artist_song_map m WHERE m.artist_key = a.artist_key
      ) AND a.status = 'pending'
    )
  ''');
  // 回收身份：只有「挂在有歌身份下」的成员链才有意义。
  //
  // 从有歌曲映射的身份出发沿成员边递归 —— 这批身份及其可达的成员全部保留
  // （Person 自己没有歌，歌记在组合名下，正是靠这条链继承）；
  // 不在这批里的身份是残留：从未命中的占位、成员退出/换人后掉队的旧成员、
  // 以及解析失败后无歌可挂的边。先删边再删身份，链上更深的成员随之失效。
  db.execute('''
    WITH RECURSIVE live(key) AS (
      SELECT artist_key FROM artists WHERE EXISTS (
        SELECT 1 FROM artist_song_map m WHERE m.artist_key=artists.artist_key
      )
      UNION
      SELECT am.member_key FROM artist_member am JOIN live l ON am.parent_key = l.key
    )
    DELETE FROM artist_member
      WHERE parent_key NOT IN (SELECT key FROM live)
         OR member_key NOT IN (SELECT key FROM live)
  ''');
  db.execute('''
    DELETE FROM artists WHERE artist_key NOT IN (
      WITH RECURSIVE live(key) AS (
        SELECT artist_key FROM artists WHERE EXISTS (
          SELECT 1 FROM artist_song_map m WHERE m.artist_key=artists.artist_key
        )
        UNION
        SELECT am.member_key FROM artist_member am JOIN live l ON am.parent_key = l.key
      )
      SELECT key FROM live
    )
  ''');
  // 刚被删掉的身份在桥表里的行。
  db.execute('''
    DELETE FROM artist_canon WHERE artist_key NOT IN (SELECT artist_key FROM artists)
  ''');
}

/// 对 idx_songs 的当前（源,引用,歌手）集合校准身份映射：
/// 1. 缺失 canonical 建占位身份行（status='pending'）与 artist_canon 桥；
/// 2. 每（源,引用）按当前身份集校准 artist_song_map——合作串 `A & B`/
///    `A feat. B` 逐段各挂一个 role='main'；身份变即旧映射删除重写；
/// 3. 清理已不存在的歌曲/已清空歌手的映射，并回收孤儿占位身份。
///
/// 单事务内完成（好比对 5k 行的全量重建，但走 INSERT OR IGNORE 增量）；由扫描
/// 结束、元数据回填批、用户编辑歌手后触发。
void _opArtistReconcile(Database db) {
  db.execute('BEGIN');
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    final nowIso = DateTime.now().toIso8601String();
    final rows = db.select('SELECT source_key, ref, artist FROM idx_songs '
        'WHERE missing=0 AND artist IS NOT NULL AND artist<>\'\'');

    final keyOfCanon = <String, String>{};
    for (final r
        in db.select('SELECT canonical_key, artist_key FROM artist_canon')) {
      keyOfCanon[r['canonical_key'] as String] = r['artist_key'] as String;
    }
    final canonDisplay = <String, String>{};
    // (source_key, ref) → 该歌归属的身份 canonical 集合（合作串逐段各一）。
    final songCanons = <(String, String), Set<String>>{};
    for (final r in rows) {
      final raw = r['artist'] as String;
      final sk = r['source_key'] as String;
      final ref = r['ref'] as String;
      final targets = songCanons.putIfAbsent((sk, ref), () => <String>{});
      for (final (canon, display) in artistCollabCanonicals(raw)) {
        canonDisplay.putIfAbsent(canon, () => display);
        targets.add(canon);
      }
    }

    for (final entry in canonDisplay.entries) {
      if (keyOfCanon.containsKey(entry.key)) continue;
      final ak = _newUuid();
      keyOfCanon[entry.key] = ak;
      db.execute(
          'INSERT INTO artists(artist_key, canonical_key, display_name, names, status, updated_at) '
          'VALUES(?,?,?,?,?,?)',
          [
            ak,
            entry.key,
            entry.value,
            jsonEncode([
              {'name': entry.value, 'name_type': 'primary', 'is_primary': 1}
            ]),
            'pending',
            nowIso,
          ]);
      db.execute(
          'INSERT INTO artist_canon(canonical_key, artist_key, updated_at) '
          'VALUES(?,?,?)',
          [entry.key, ak, now]);
    }

    // 每（源,引用）整体同步：整歌清掉 role='main' 旧映射，再逐身份重插。
    // 不能按身份单条「删异留同」——合作串两个身份会互相删掉刚插入的行。
    final delStmt = db.prepare(
        "DELETE FROM artist_song_map WHERE role='main' AND source_key=? AND ref=?");
    final insStmt = db.prepare(
        'INSERT OR IGNORE INTO artist_song_map(source_key, ref, artist_key, role) '
        'VALUES(?,?,?,\'main\')');
    try {
      for (final entry in songCanons.entries) {
        final (sk, ref) = entry.key;
        delStmt.execute([sk, ref]);
        for (final canon in entry.value) {
          insStmt.execute([sk, ref, keyOfCanon[canon]!]);
        }
      }
    } finally {
      insStmt.dispose();
      delStmt.dispose();
    }

    // 清理失效映射与最近回收的占位（pending 且无歌引用 = 已合并/删除的孤儿）。
    _opArtistGc(db);
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// 解析结果整行落库（占位更新 / 首次解析 / 人工绑定到全新 mbid）：
/// 更新 artists 全字段并 upsert artist_canon 桥。names/groups 为 JSON 数组。
void _opArtistUpsert(Database db, Map<String, dynamic> a) {
  final nowIso = DateTime.now().toIso8601String();
  final ak = a['artistKey'] as String;
  final canon = a['canonicalKey'] as String;
  final now = DateTime.now().millisecondsSinceEpoch;
  db.execute('''
    INSERT INTO artists(artist_key, mbid, canonical_key, display_name, names,
      groups, type, disambiguation, status, error_count, next_at, resolved_at,
      match_score, updated_at)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(artist_key) DO UPDATE SET
      mbid=excluded.mbid, display_name=excluded.display_name, names=excluded.names,
      groups=excluded.groups, type=excluded.type,
      disambiguation=excluded.disambiguation, status=excluded.status,
      error_count=excluded.error_count, next_at=excluded.next_at,
      resolved_at=excluded.resolved_at, match_score=excluded.match_score,
      updated_at=excluded.updated_at
  ''', [
    ak,
    a['mbid'],
    canon,
    a['displayName'],
    jsonEncode(a['names']),
    jsonEncode(a['groups']),
    a['type'],
    a['disambiguation'],
    a['status'],
    a['errorCount'],
    a['nextAt'],
    a['resolvedAt'],
    a['matchScore'],
    nowIso,
  ]);
  db.execute(
      'INSERT INTO artist_canon(canonical_key, artist_key, updated_at) '
      'VALUES(?,?,?) ON CONFLICT(canonical_key) DO UPDATE SET '
      'artist_key=excluded.artist_key, updated_at=excluded.updated_at',
      [canon, ak, now]);
}

/// 把某 canonical 解析结果合并进已存在的 mbid 身份行（同一真人不同拼写的别名合流）：
/// 迁移歌曲映射 → 删除占位身份 → 桥改指向 → （可选）把新名字/角色/小组并入目标行。
/// 不存在该 mbid 行时返回 false（调用方走 artistUpsert）。
bool _opArtistMergeMbid(Database db, Map<String, dynamic> a) {
  final mbid = a['mbid'] as String;
  final target =
      db.select('SELECT artist_key FROM artists WHERE mbid=?', [mbid]);
  if (target.isEmpty) return false;
  final targetAk = target.first['artist_key'] as String;
  final fromAk = a['fromArtistKey'] as String;
  db.execute('UPDATE artist_song_map SET artist_key=? WHERE artist_key=?',
      [targetAk, fromAk]);
  final canon = a['canonicalKey'] as String;
  final now = DateTime.now().millisecondsSinceEpoch;
  db.execute(
      'UPDATE artist_canon SET artist_key=?, updated_at=? WHERE canonical_key=?',
      [targetAk, now, canon]);
  if (a['update'] == true) {
    final row = db.select(
        'SELECT names, groups, display_name, type, disambiguation '
        'FROM artists WHERE artist_key=?',
        [targetAk]);
    if (row.isNotEmpty) {
      final r = row.first;
      final names = _mergeNameLists(_jsonList(r['names']),
          (a['names'] as List).cast<Map<dynamic, dynamic>>());
      final groups = _mergeJsonList(_jsonList(r['groups']),
          (a['groups'] as List).cast<Map<dynamic, dynamic>>());
      final nowIso = DateTime.now().toIso8601String();
      db.execute('''
        UPDATE artists SET names=?, groups=?, display_name=?, type=?, 
          disambiguation=?, status='resolved', error_count=0, resolved_at=?,
          match_score=COALESCE(?, match_score), updated_at=?
        WHERE artist_key=?
      ''', [
        jsonEncode(names),
        jsonEncode(groups),
        (r['display_name'] as String?)?.isNotEmpty == true
            ? r['display_name']
            : a['displayName'],
        a['type'],
        (r['disambiguation'] as String?) ?? a['disambiguation'],
        nowIso,
        // 按已有 mbid 重取实体拿不到分数（score=0 → null），此时保留原分数，
        // 别被一次重新解析抹成空。
        a['matchScore'],
        nowIso,
        targetAk,
      ]);
    }
  }
  // 合流目标就是来源本身（重新解析一个已解析身份）时**不能删**：
  // 删掉就等于把刚刷新的身份连同它的歌曲映射一起抹了。
  if (targetAk != fromAk) {
    db.execute('DELETE FROM artists WHERE artist_key=?', [fromAk]);
  }
  return true;
}

/// 重试：把 local/ambiguous 状态重置为 pending（空 canonicalKey=全部）。
/// 人工「重试解析」按钮即调用此入口。
void _opArtistRetry(Database db, Map<String, dynamic> a) {
  final canon = a['canonicalKey'] as String?;
  final nowIso = DateTime.now().toIso8601String();
  if (canon == null) {
    db.execute(
        "UPDATE artists SET status='pending', error_count=0, next_at=0, updated_at=? "
        "WHERE status IN ('local','ambiguous')",
        [nowIso]);
    return;
  }
  db.execute(
      "UPDATE artists SET status='pending', error_count=0, next_at=0, updated_at=? "
      "WHERE canonical_key=? AND status IN ('local','ambiguous')",
      [nowIso, canon]);
}

/// 某一轮解析失败：只记「待重试」，绝不碰 mbid/names/groups/type/match_score。
///
/// 不能复用 _opArtistUpsert——那是全字段覆盖，传空 names/groups 和空 mbid 会把
/// 已经合流好的身份整个抹掉，等于一次网络抖动就丢掉别名表和成员元数据。
void _opArtistMarkError(Database db, Map<String, dynamic> a) {
  final nowIso = DateTime.now().toIso8601String();
  db.execute(
      'UPDATE artists SET status=?, error_count=?, next_at=?, updated_at=? '
      'WHERE artist_key=?',
      [
        a['status'] ?? 'local',
        a['errorCount'] ?? 0,
        a['nextAt'] ?? 0,
        nowIso,
        a['artistKey'],
      ]);
}

/// 强制重新解析：把指定范围（全部 / 单个身份 / 单个 canonical）的歌手打回 pending。
///
/// 与 _opArtistRetry 的区别是**连 resolved 一起重置**，并清 expanded_at 让成员重新
/// 展开；成员边本身先留着——展开成功时 _opArtistSetMembers 全量替换，失败时旧的
/// 可用成员不至于被提前抹掉。
void _opArtistForceRetry(Database db, Map<String, dynamic> a) {
  final nowIso = DateTime.now().toIso8601String();
  const head = "UPDATE artists SET status='pending', error_count=0, next_at=0, "
      'expanded_at=NULL, updated_at=? WHERE ';
  if (a['all'] == true) {
    db.execute('$head 1=1', [nowIso]);
    return;
  }
  final ak = a['artistKey'] as String?;
  if (ak != null && ak.isNotEmpty) {
    db.execute('$head artist_key=?', [nowIso, ak]);
    return;
  }
  final canon = a['canonicalKey'] as String?;
  if (canon != null && canon.isNotEmpty) {
    db.execute('$head canonical_key=?', [nowIso, canon]);
  }
}

/// 全量替换某身份的成员边（歌手处理.txt 第 43 行：一次 artist-rels 拿回的关系直接建边）。
/// 成员元数据自带 mbid，所以成员身份一出生就是 resolved——不必为每个成员再单独搜 MB，
/// 也就不会进工作集反复重试。返回与 members 等长的成员身份键列表（调用方据此递归展开），
/// 未能建边的位置为空串；parent 已不存在时返回空列表。
List<String> _opArtistSetMembers(Database db, Map<String, dynamic> a) {
  final parentKey = a['parentKey'] as String;
  final members = (a['members'] as List).cast<Map<String, dynamic>>();
  final now = DateTime.now().millisecondsSinceEpoch;
  final nowIso = DateTime.now().toIso8601String();
  db.execute('BEGIN');
  try {
    db.execute('DELETE FROM artist_member WHERE parent_key=?', [parentKey]);
    if (db.select(
        'SELECT 1 FROM artists WHERE artist_key=?', [parentKey]).isEmpty) {
      db.execute('ROLLBACK');
      return const [];
    }
    final ins = db.prepare(
        'INSERT OR IGNORE INTO artist_member(parent_key, member_key, relation, updated_at) '
        'VALUES(?,?,?,?)');
    final keys = <String>[];
    try {
      for (final m in members) {
        final mk = _ensureMemberIdentity(db, m, nowIso, now) ?? '';
        keys.add(mk);
        if (mk.isEmpty) continue;
        ins.execute([parentKey, mk, m['relation'] as String, now]);
      }
    } finally {
      ins.dispose();
    }
    db.execute(
        'UPDATE artists SET member_count=?, expanded_at=?, updated_at=? WHERE artist_key=?',
        [keys.where((k) => k.isNotEmpty).length, nowIso, nowIso, parentKey]);
    // 全量替换后回收：这次退出的成员若既没歌也没有别的边，身份行应当消失
    // （否则 MB 换人/成员退出后，歌手页会一直挂着早已不在的成员）。
    _opArtistGc(db);
    db.execute('COMMIT');
    return keys;
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// 只补记「已展开过」，绝不碰成员边。
/// 与 _opArtistSetMembers 分开是因为后者是全量替换语义：把「标记已展开」实现成传空
/// 成员列表，会把刚建好的边整批删掉（expanded_at 反而写上了，看起来像成功）。
void _opArtistMarkExpanded(Database db, Map<String, dynamic> a) {
  final parentKey = a['artistKey'] as String;
  final nowIso = DateTime.now().toIso8601String();
  db.execute(
      'UPDATE artists SET expanded_at=?, updated_at=? WHERE artist_key=?',
      [nowIso, nowIso, parentKey]);
}

/// 取或建成员身份，优先按 mbid 复用（MB 里同实体跨名字只有一条），其次按原始拼写。
/// 同名但 mbid 不同视为两个实体：各自建行，但 artist_canon 键只指向前者（PK 冲突忽略），
/// 边本身走 artist_key，不受影响。
String? _ensureMemberIdentity(
    Database db, Map<String, dynamic> m, String nowIso, int now) {
  final name = (m['name'] as String?)?.trim() ?? '';
  if (name.isEmpty) return null;
  final mbid = m['mbid'] as String?;
  final type = (m['type'] as String?)?.isNotEmpty == true
      ? m['type'] as String
      : 'person';
  if (mbid != null) {
    final r = db.select('SELECT artist_key FROM artists WHERE mbid=?', [mbid]);
    if (r.isNotEmpty) return r.first['artist_key'] as String;
  }
  final same = db.select(
      'SELECT artist_key, mbid FROM artists WHERE canonical_key=?', [name]);
  if (same.isNotEmpty) {
    final row = same.first;
    final ak = row['artist_key'] as String;
    final rowMbid = row['mbid'] as String?;
    if (rowMbid == null) {
      // 占位身份首次拿到 MB 实体：原地升级，别再建一行把歌分到两个身份上。
      db.execute('''
        UPDATE artists SET mbid=?, type=?, status='resolved', error_count=0,
          next_at=0, resolved_at=?, names=?, updated_at=? WHERE artist_key=?
      ''', [
        mbid,
        type,
        nowIso,
        jsonEncode([
          {'name': name, 'name_type': 'primary', 'is_primary': 1}
        ]),
        nowIso,
        ak,
      ]);
    }
    return ak;
  }
  final ak = _newUuid();
  db.execute('''
    INSERT INTO artists(artist_key, mbid, canonical_key, display_name, names,
      groups, type, status, error_count, next_at, resolved_at, updated_at)
    VALUES(?,?,?,?,?,'[]',?,'resolved',0,0,?,?)
  ''', [
    ak,
    mbid,
    name,
    name,
    jsonEncode([
      {'name': name, 'name_type': 'primary', 'is_primary': 1}
    ]),
    type,
    nowIso,
    nowIso,
  ]);
  db.execute(
      'INSERT INTO artist_canon(canonical_key, artist_key, updated_at) VALUES(?,?,?) '
      'ON CONFLICT(canonical_key) DO NOTHING',
      [name, ak, now]);
  return ak;
}

/// DB 行里的 JSON 列表（容错：损坏返回空列表）。
List<Map<dynamic, dynamic>> _jsonList(Object? raw) {
  if (raw == null) return [];
  try {
    return (jsonDecode(raw as String) as List).cast<Map<dynamic, dynamic>>();
  } catch (_) {
    return [];
  }
}

/// 名字列表合并去重（按 name+name_type），覆盖时以新值为准。
List<Map<dynamic, dynamic>> _mergeNameLists(
    List<Map<dynamic, dynamic>> old, List<Map<dynamic, dynamic>> fresh) {
  final out = <Map<dynamic, dynamic>>[];
  final keys = <String>{};
  for (final n in [...fresh, ...old]) {
    final k = '${n['name']}\u0000${n['name_type']}';
    if (keys.add(k)) out.add(n);
  }
  return out;
}

/// 通用 JSON 条目合并去重（groups 用；按首个键去重）。
List<Map<dynamic, dynamic>> _mergeJsonList(
    List<Map<dynamic, dynamic>> old, List<Map<dynamic, dynamic>> fresh) {
  final out = <Map<dynamic, dynamic>>[];
  final keys = <String>{};
  for (final n in [...fresh, ...old]) {
    final k = n.keys.isEmpty ? '' : '${n.values.first}';
    if (keys.add(k)) out.add(n);
  }
  return out;
}
