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
import 'artist_names.dart';
import 'schema.dart';

/// 常驻 SQLite 写隔离（后台 isolate 独占第二个连接）。
///
/// 目标（DESIGN：启动磁盘 I/O 风暴修复）：
/// 1. 所有写/fsync 离开 UI 线程——主线程的连接只做读，写全部经此隔离排队；
/// 2. 队列内多条语句自动合并为**单个事务**（WAL 下一次顺序追加 + 一次 checkpoint
///    fsync），把「逐行 autocommit 的几万次小块写」收敛成少量大块顺序写；
/// 3. `PRAGMA synchronous=NORMAL`：WAL 模式下仅 checkpoint 才 fsync。
///
/// 一致性约定：全部调用按到达顺序 FIFO 执行；需要回执的调用在**落库后**才完成
/// Future（主线程读连接通过 WAL 立刻可见已提交数据）；纯 fire 的写仅保证最终一致。
class DbWriter {
  DbWriter._(this._cmd, this._isolate) {
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
    final isolate = await Isolate.spawn(_writerEntry, boot.sendPort,
        debugName: 'local-db-writer');
    final cmd = await boot.first as SendPort;
    boot.close();
    final w = DbWriter._(cmd, isolate);
    await w._send('init', {'path': dbPath});
    return w;
  }

  // ---------- 主线程侧 API ----------

  /// 排队写并等待落库（自动与其他排队写合并为单事务）。
  Future<void> exec(String sql, [List<Object?>? args]) async {
    await _send('exec', {'sql': sql, 'args': args ?? const []});
  }

  /// 排队写，不等落库（最终一致；settings 内存缓存/outbox uuid 等场景用）。
  void execFire(String sql, [List<Object?>? args]) {
    _cmd.send({
      't': 'execFire',
      'sql': sql,
      'args': args ?? const [],
      'reply': null,
    });
  }

  /// 写并返回受影响行数。
  Future<int> execUpdated(String sql, [List<Object?>? args]) async {
    final v = await _send('execUpdated', {'sql': sql, 'args': args ?? const []});
    return v as int;
  }

  /// 写并返回 lastInsertRowId。
  Future<int> execInsert(String sql, List<Object?> args) async {
    final v = await _send('execInsert', {'sql': sql, 'args': args});
    return v as int;
  }

  /// 执行一条复合写操作（多语句/内部读依赖，运行在写连接上保证一致性）。
  Future<T> op<T>(String name, Map<String, dynamic> args) async {
    final v = await _send('op', {'name': name, 'args': args});
    return v as T;
  }

  /// 批量执行同类复合操作：合并为**单个事务**（同步 pull 落库主路径）。
  Future<void> opBatch(String name, List<Map<String, dynamic>> argList) async {
    if (argList.isEmpty) return;
    await _send('opBatch', {'name': name, 'argList': argList});
  }

  /// 等待当前排队写全部落库。
  Future<void> flush() async {
    await _send('flush', const {});
  }

  /// 优雅关闭：等待排队写落库后退出写隔离。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _send('close', const {});
    } finally {
      _resp.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }

  /// 立即关闭（fire-and-forget）：丢弃未落库排队写并杀掉写隔离。
  /// 调用方负责先 [flush]；供同步 close()（如测试收尾）使用。
  void dispose() {
    if (_closed) return;
    _closed = true;
    _isolate.kill(priority: Isolate.immediate);
    _resp.close();
  }

  Future<Object?> _send(String t, Map<String, dynamic> extra) {
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

// ---------- 写隔离入口 ----------

/// 写隔离内打开连接。
///
/// 写隔离是独立 isolate，拿不到主 isolate 的 `open.overrideFor`（测试即如此
/// 覆盖）；Linux 发行版又常只有 `libsqlite3.so.0` 而无 `-dev` 符号链接，sqlite3
/// 包默认只试前者。故在此按候选名解析一次，保证写隔离在任何平台都能起库。
Database _openWriterDb(String path) {
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
    final conn = db!;
    if (ops.length == 1 && ops.single.reply == null) {
      // 单条 fire：autocommit，省一次 BEGIN/COMMIT。
      conn.execute(ops.single.sql, ops.single.args);
      return;
    }
    conn.execute('BEGIN');
    try {
      for (final o in ops) {
        conn.execute(o.sql, o.args);
      }
      conn.execute('COMMIT');
      for (final o in ops) {
        o.reply?.send({'seq': o.seq, 'ok': true, 'value': null});
      }
    } catch (_) {
      try {
        conn.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
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
          db = _openWriterDb(m['path'] as String);
          db!.execute('PRAGMA synchronous=NORMAL;');
          db!.execute('PRAGMA busy_timeout=30000;');
          db!.execute('PRAGMA wal_autocheckpoint=1000;');
          applySchema(db!);
          reply(m, null);
        case 'execFire':
        case 'exec':
          pending.add(_PendOp(
              m['sql'] as String,
              (m['args'] as List).cast<Object?>(),
              m['reply'] is SendPort ? m['reply'] as SendPort : null,
              m['seq'] as int));
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
          reply(m,
              _runOp(db!, m['name'] as String, (m['args'] as Map).cast<String, dynamic>()));
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
      }
    }
  });
}

class _PendOp {
  final String sql;
  final List<Object?> args;
  final SendPort? reply;
  final int seq;
  _PendOp(this.sql, this.args, this.reply, this.seq);
}

// ---------- 复合写操作（全部运行在写连接上） ----------

Object? _runOp(Database db, String name, Map<String, dynamic> a) {
  switch (name) {
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
  }
  throw StateError('unknown writer op: $name');
}

void _runOpBatch(Database db, String name, List<Map<String, dynamic>> argList) {
  switch (name) {
    case 'applySongSnapshots':
      db.execute('BEGIN');
      try {
        for (final a in argList) {
          _opApplySongSnapshot(db, a);
        }
        db.execute('COMMIT');
      } catch (_) {
        try {
          db.execute('ROLLBACK');
        } catch (_) {}
        rethrow;
      }
      return;
  }
  throw StateError('unknown writer batch op: $name');
}

// ---------- 共享小工具（写连接内的读依赖） ----------

String _newUuid() {
  final r = Random.secure();
  final tail = List.generate(
          3, (_) => r.nextInt(0xffffffff).toRadixString(16).padLeft(8, '0'))
      .join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${tail.substring(0, 12)}';
}

String _sourceOfKey(String key) {
  final i = key.indexOf(':');
  return i > 0 ? key.substring(0, i) : key;
}

String? _sourceKeyOfUuid(Database db, String uuid) {
  if (uuid.isEmpty) return null;
  final rs =
      db.select('SELECT key FROM sources WHERE client_uuid=?', [uuid]);
  return rs.isEmpty ? null : rs.first['key'] as String;
}

/// 读当前 play_meta 行（写前合并用；空行返回默认权重）。
({int ls, int ds, double f, bool frozen, bool fav, String? sj, int ps}) _curMeta(
    Database db, String sourceKey, String songRef) {
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
    final rows = db.select(
        'SELECT source_key, ref FROM idx_songs WHERE ref=?', [v]);
    for (final r in rows) {
      final key = r['source_key'] as String;
      if (key == 'server') continue;
      if (_sourceOfKey(key) != source) continue;
      write(key, r['ref'] as String);
    }
  }
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

  final existing = db.select(
      'SELECT id FROM playlists WHERE client_uuid=?', [uuid]);
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
  db.execute(
      'DELETE FROM playlist_items WHERE playlist_id=? AND source_key=?',
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
    final resolved =
        it['sourceId'] == null ? null : _sourceKeyOfUuid(db, it['sourceId'] as String);
    if (resolved != null) {
      key = resolved;
    } else if (it['source'] != null && (it['source'] as String).isNotEmpty) {
      final kind = it['source'] as String;
      final peers = db
          .select('SELECT key FROM sources WHERE kind=?', [kind]);
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
  final rs = db.select(
      'SELECT key, config FROM sources WHERE client_uuid=?', [uuid]);
  if (rs.isNotEmpty) {
    hitKey = rs.first['key'] as String;
  }
  if (hitKey == null && !deleted && addr.isNotEmpty) {
    for (final r in db.select(
        'SELECT key, kind, config FROM sources WHERE kind=?', [kind])) {
      Map<String, dynamic> cfg = const {};
      try {
        cfg = jsonDecode(r['config'] as String) as Map<String, dynamic>;
      } catch (_) {}
      if (sourceAddressOf(kind, cfg) == addr) {
        db.execute('UPDATE sources SET client_uuid=? WHERE key=?',
            [uuid, r['key']]);
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
    final fallbackName =
        hitKey.contains(':') ? hitKey.substring(hitKey.indexOf(':') + 1) : hitKey;
    db.execute(
        'UPDATE sources SET kind=?, name=?, config=?, enabled=? WHERE key=?',
        [kind, name ?? fallbackName, cfgJson, enabled ? 1 : 0, hitKey]);
    return true;
  }
  final suffix =
      name == null || name.isEmpty ? uuid.substring(0, 8) : name;
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
  final rs =
      db.select('SELECT client_uuid FROM playlists WHERE id=?', [id]);
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
  final max = db
      .select('SELECT COALESCE(MAX(sort_order),0) m FROM playlist_items WHERE playlist_id=?',
          [playlistId])
      .first['m'] as int;
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

/// 全表一次性迁移历史 ENCODE 形态的 play_meta 行（启动时由 LocalIndex.open 触发）。
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
  final rs =
      db.select('SELECT client_uuid FROM playlists WHERE id=?', [id]);
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

void _opRenameSource(Database db, String oldKey, String newKey) {
  db.execute('UPDATE OR REPLACE sources SET key=? WHERE key=?', [newKey, oldKey]);
  db.execute('UPDATE OR REPLACE idx_songs SET source_key=? WHERE source_key=?',
      [newKey, oldKey]);
  db.execute('UPDATE OR REPLACE play_meta SET source_key=? WHERE source_key=?',
      [newKey, oldKey]);
  db.execute(
      'UPDATE OR REPLACE playlist_items SET source_key=? WHERE source_key=?',
      [newKey, oldKey]);
  db.execute('UPDATE OR REPLACE artist_song_map SET source_key=? WHERE source_key=?',
      [newKey, oldKey]);
}

// ---------- 歌手处理.txt：身份聚合写操作（写连接内一次性算完） ----------

/// 歌手串 → 聚合用的归一化键：声优注记（CV:x）以「角色|人物」为键（不同拼写合
/// 并成同一调查项），其余情况取整串 NFKC 键。
String _artistCanonicalOf(String raw) {
  final p = splitArtistPart(raw);
  if (p.hasCv) {
    final b = p.base.isEmpty ? p.cvName! : '${p.base}|${p.cvName}';
    return artistCanonicalKey(b);
  }
  return artistCanonicalKey(raw);
}

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
  db.execute('''
    DELETE FROM artists WHERE status='pending' AND NOT EXISTS (
      SELECT 1 FROM artist_song_map m WHERE m.artist_key = artists.artist_key
    )
  ''');
}

/// 对 idx_songs 的当前（源,引用,歌手）集合校准身份映射：
/// 1. 缺失 canonical 建占位身份行（status='pending'）与 artist_canon 桥；
/// 2. 每（源,引用）单元格按当前 canonical 校准 artist_song_map（身份变即旧映射
///    删除重写）；
/// 3. 清理已不存在的歌曲/已清空歌手的映射，并回收孤儿占位身份。
///
/// 单事务内完成（好比对 5k 行的全量重建，但走 INSERT OR IGNORE 增量）；由扫描
/// 结束、元数据回填批、用户编辑歌手后触发。
void _opArtistReconcile(Database db) {
  db.execute('BEGIN');
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    final nowIso = DateTime.now().toIso8601String();
    final rows = db.select(
        'SELECT source_key, ref, artist FROM idx_songs '
        'WHERE missing=0 AND artist IS NOT NULL AND artist<>\'\'');

    final keyOfCanon = <String, String>{};
    for (final r in db
        .select('SELECT canonical_key, artist_key FROM artist_canon')) {
      keyOfCanon[r['canonical_key'] as String] = r['artist_key'] as String;
    }
    final canonDisplay = <String, String>{};
    final cells = <(String, String, String)>[];
    // (source_key, ref) 去重：同一首歌只校准一次（先 putIfAbsent 再 add）。
    final seen = <String, Set<String>>{};
    for (final r in rows) {
      final raw = r['artist'] as String;
      final canon = _artistCanonicalOf(raw);
      canonDisplay.putIfAbsent(canon, () => raw);
      final sk = r['source_key'] as String;
      final ref = r['ref'] as String;
      if (seen.putIfAbsent(sk, () => <String>{}).add(ref)) {
        cells.add((sk, ref, canon));
      }
    }

    for (final entry in canonDisplay.entries) {
      if (keyOfCanon.containsKey(entry.key)) continue;
      final ak = _newUuid();
      keyOfCanon[entry.key] = ak;
      db.execute(
          'INSERT INTO artists(artist_key, canonical_key, display_name, names, status, updated_at) '
          'VALUES(?,?,?,?,?,?)', [
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

    final insStmt = db.prepare(
        'INSERT OR IGNORE INTO artist_song_map(source_key, ref, artist_key, role) '
        'VALUES(?,?,?,\'main\')');
    final delStmt = db.prepare(
        "DELETE FROM artist_song_map WHERE role='main' AND source_key=? AND ref=? AND artist_key<>?");
    try {
      for (final (sk, ref, canon) in cells) {
        final ak = keyOfCanon[canon]!;
        delStmt.execute([sk, ref, ak]);
        insStmt.execute([sk, ref, ak]);
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
      groups, type, disambiguation, status, error_count, next_at, resolved_at, updated_at)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(artist_key) DO UPDATE SET
      mbid=excluded.mbid, display_name=excluded.display_name, names=excluded.names,
      groups=excluded.groups, type=excluded.type,
      disambiguation=excluded.disambiguation, status=excluded.status,
      error_count=excluded.error_count, next_at=excluded.next_at,
      resolved_at=excluded.resolved_at, updated_at=excluded.updated_at
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
  final target = db.select('SELECT artist_key FROM artists WHERE mbid=?', [mbid]);
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
    final row = db.select('SELECT names, groups, display_name, type, disambiguation '
        'FROM artists WHERE artist_key=?', [targetAk]);
    if (row.isNotEmpty) {
      final r = row.first;
      final names = _mergeNameLists(
          _jsonList(r['names']), (a['names'] as List).cast<Map<dynamic, dynamic>>());
      final groups = _mergeJsonList(
          _jsonList(r['groups']), (a['groups'] as List).cast<Map<dynamic, dynamic>>());
      final nowIso = DateTime.now().toIso8601String();
      db.execute('''
        UPDATE artists SET names=?, groups=?, display_name=?, type=?, 
          disambiguation=?, status='resolved', error_count=0, resolved_at=?, updated_at=?
        WHERE artist_key=?
      ''', [
        jsonEncode(names),
        jsonEncode(groups),
        (r['display_name'] as String?)?.isNotEmpty == true ? r['display_name'] : a['displayName'],
        a['type'],
        (r['disambiguation'] as String?) ?? a['disambiguation'],
        nowIso,
        nowIso,
        targetAk,
      ]);
    }
  }
  db.execute('DELETE FROM artists WHERE artist_key=?', [fromAk]);
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
        "WHERE status IN ('local','ambiguous')", [nowIso]);
    return;
  }
  db.execute(
      "UPDATE artists SET status='pending', error_count=0, next_at=0, updated_at=? "
      "WHERE canonical_key=? AND status IN ('local','ambiguous')",
      [nowIso, canon]);
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