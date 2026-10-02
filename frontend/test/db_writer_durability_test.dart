import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/db_writer.dart';
import 'package:selfmusic/data/local/schema.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// 写隔离的落库可靠性。两条都是实测出的真丢数据/真卡死，不是理论风险：
///
/// 1) execFire 原先不带 seq，写隔离侧 `m['seq'] as int` 直接抛错；而 fire 的
///    reply 为 null，既没有回包方也没有日志 —— 整条写被静默丢弃。
///    settingsSet / touchCache 等全靠 fire，于是「同步游标、播放模式、缓存 LRU
///    时间」这些一重启就丢，而进程内内存缓存一直看着是对的，极难察觉。
///
/// 2) flushNow 原先是一条失败就整批 ROLLBACK 再 rethrow：同批最多 255 条无关
///    写入一起丢；且 rethrow 冒到监听器的 catch 后回的是「触发这次 flush 的那条
///    消息」，批里等回复的 exec() 永远收不到 → Future 永久挂起。
DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

/// app_settings.value 是 NOT NULL，传 null 必然失败——用来制造「坏 SQL」。
const _insert = 'INSERT INTO app_settings(key, value) VALUES(?,?)';

void main() {
  late Directory tmp;
  late String dbPath;
  late DbWriter w;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    tmp = Directory.systemTemp.createTempSync('selfmusic_dbwriter_');
    dbPath = '${tmp.path}/t.db';
    // 建表（写隔离的 init 只做 PRAGMA，不负责 schema）。
    final seed = sqlite3.open(dbPath);
    applySchema(seed);
    seed.dispose();

    w = await DbWriter.start(dbPath);
  });

  tearDown(() async {
    await w.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 用独立连接读库文件，绕开进程内任何缓存。
  List<Object?> raw(String key) {
    final db = sqlite3.open(dbPath);
    try {
      final rs = db.select('SELECT value FROM app_settings WHERE key=?', [key]);
      return rs.isEmpty ? const [] : [rs.first['value']];
    } finally {
      db.dispose();
    }
  }

  test('execFire 的写入真的落盘', () async {
    w.execFire(_insert, ['fire_key', 'fire_value']);
    await w.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(raw('fire_key'), ['fire_value'],
        reason: 'fire 写入必须真的到达磁盘，不能只在内存缓存里看着对');
  });

  test('单条 fire 失败不留数据，也不影响后续 fire', () async {
    w.execFire(_insert, ['bad_single', null]); // NOT NULL 违例
    await w.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(raw('bad_single'), isEmpty, reason: '失败的写入不该留下数据');

    // 失败之后写层要还能继续用（不能因一条坏 SQL 就废掉）。
    w.execFire(_insert, ['after_bad', 'ok']);
    await w.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(raw('after_bad'), ['ok']);
  });

  test('批内单条失败：同批其余写入仍落库（不再整批回滚）', () async {
    for (var i = 0; i < 5; i++) {
      w.execFire(_insert, ['good_$i', 'v$i']);
    }
    w.execFire(_insert, ['bad_batch', null]); // 同批里的坏行
    await w.flush();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    for (var i = 0; i < 5; i++) {
      expect(raw('good_$i'), ['v$i'],
          reason: '一条坏 SQL 不该把同批其余写入一起回滚掉');
    }
    expect(raw('bad_batch'), isEmpty);
  });

  test('批内单条失败：等回复的 exec() 收到失败，不会永久挂起', () async {
    for (var i = 0; i < 3; i++) {
      w.execFire(_insert, ['ok_$i', 'v']);
    }
    final failing = w.exec(_insert, ['bad_exec', null]);

    // 带超时：若仍会挂死，这里直接失败，而不是让测试无限等下去。
    await expectLater(
        failing.timeout(const Duration(seconds: 5)), throwsA(isA<StateError>()));
  });

  test('批量窗口内失败的 fire 不影响同批 exec() 的正常返回', () async {
    // fire 与 exec 共用同一个 2ms 批量窗口，必须都能收口。
    w.execFire(_insert, ['b1', null]);
    w.execFire(_insert, ['g1', 'v1']);
    await expectLater(
        w.exec(_insert, ['g2', 'v2'])
            .timeout(const Duration(seconds: 5)),
        completes);
    expect(raw('g2'), ['v2']);
  });

  test('写层关闭后 flush 立刻失败，不挂起', () async {
    // close 之后再排队的写必须有明确结果：原先回包端口已关、隔离已杀，
    // flush() 会永远等着 —— 退出流程里收尾顺序稍有出入就静默卡住。
    await w.close();
    await expectLater(w.flush().timeout(const Duration(seconds: 5)),
        throwsA(isA<StateError>()));
  });
}