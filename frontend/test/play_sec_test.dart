import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/play_stats.dart';
import 'package:sqlite3/open.dart';

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

Future<(LocalIndex, SongWeightStore)> _openStore() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_playsec_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return (index, SongWeightStore(index));
}

Song _song(String ref) => Song(
      id: 0,
      sourceKey: 'webdav:test',
      title: ref,
      source: 'webdav',
      sourceRef: ref,
      fileSize: 0,
    );

/// 播放时长采集与派生次数（改进.txt：播放时长精确到秒，播放次数=时长÷歌曲时长）。
void main() {
  group('play_meta.play_sec 累加', () {
    test('多次落库为累加；权重/收藏等列不受影响', () async {
      final (index, w) = await _openStore();
      addTearDown(index.close);
      final s = _song('a.mp3');

      expect(index.playMetaOf(s.sourceKey, s.sourceRef).playSec, 0);
      await w.addPlaySec(s, 12);
      await w.addPlaySec(s, 8);
      expect(index.playMetaOf(s.sourceKey, s.sourceRef).playSec, 20);

      // 负数/零增量忽略
      await w.addPlaySec(s, 0);
      await w.addPlaySec(s, -5);
      expect(index.playMetaOf(s.sourceKey, s.sourceRef).playSec, 20);

      // 权重事件不冲掉播放时长
      await w.onCompleted(s);
      final m = index.playMetaOf(s.sourceKey, s.sourceRef);
      expect(m.playSec, 20);
      expect(m.likeStreak, greaterThan(0));
    });

    test('收藏/快照 upsert 不冲掉 play_sec', () async {
      final (index, w) = await _openStore();
      addTearDown(index.close);
      final s = _song('b.mp3');
      await w.addPlaySec(s, 100);
      await w.setLiked(s);
      expect(index.playMetaOf(s.sourceKey, s.sourceRef).playSec, 100);
      // 显式绝对值回写才覆盖（服务端快照路径）
      await index.upsertPlayMeta(s.sourceKey, s.sourceRef, playSec: 250);
      expect(index.playMetaOf(s.sourceKey, s.sourceRef).playSec, 250);
      // 未传 playSec = 保持原值
      await index.upsertPlayMeta(s.sourceKey, s.sourceRef, likeStreak: 2);
      expect(index.playMetaOf(s.sourceKey, s.sourceRef).playSec, 250);
    });

    test('play_sec<>0 的行进入补推列表', () async {
      final (index, w) = await _openStore();
      addTearDown(index.close);
      final s = _song('c.mp3');
      expect(index.listDirtyPlayMeta().where((m) => m.songRef == 'c.mp3'),
          isEmpty);
      await w.addPlaySec(s, 30);
      final row = index.listDirtyPlayMeta().firstWhere((m) => m.songRef == 'c.mp3');
      expect(row.playSec, 30);
    });
  });

  group('挂钟窗口结算', () {
    final t0 = DateTime(2026, 1, 1, 10);

    test('整秒计入，零头留到下个窗口', () {
      final r = settlePlaySecWindow(t0, t0.add(const Duration(milliseconds: 3400)));
      expect(r.sec, 3);
      expect(r.window, t0.add(const Duration(seconds: 3)));
    });

    test('不足 1 秒不计入', () {
      final r = settlePlaySecWindow(t0, t0.add(const Duration(milliseconds: 900)));
      expect(r.sec, 0);
      expect(r.window, t0);
    });

    test('连续结算无漂移（10 次 999ms ≈ 9 秒）', () {
      var win = t0;
      var total = 0;
      var now = t0;
      for (var i = 0; i < 10; i++) {
        now = now.add(const Duration(milliseconds: 999));
        final r = settlePlaySecWindow(win, now);
        total += r.sec;
        win = r.window;
      }
      expect(total, 9);
    });

    test('时间回拨（系统时间被改）不产生负增量', () {
      final r = settlePlaySecWindow(t0, t0.subtract(const Duration(seconds: 5)));
      expect(r.sec, 0);
      expect(r.window, t0);
    });
  });

  group('播放次数派生（时长÷歌曲时长，1 位小数）', () {
    test('正常口径', () {
      expect(playCountOf(240, 240), 1.0);
      expect(playCountOf(480, 240), 2.0);
      expect(playCountOf(100, 240), closeTo(0.4, 1e-9));
      expect(playCountOf(300, 240), closeTo(1.3, 1e-9)); // 1.25 四舍五入
      expect(playCountOf(1, 240), closeTo(0.0, 1e-9)); // 0.004 → 0.0
    });

    test('时长未知/未播放 → 0', () {
      expect(playCountOf(0, 240), 0);
      expect(playCountOf(120, null), 0);
      expect(playCountOf(120, 0), 0);
    });

    test('后台断续播放按累计时长累计次数', () {
      // 3 次各听 80 秒 = 240 秒 = 1 次完整播放
      const total = 80 + 80 + 80;
      expect(playCountOf(total, 240), 1.0);
    });

    test('展示文案', () {
      expect(playCountLabel(240, 240), '1 次');
      expect(playCountLabel(300, 240), '1.3 次');
      expect(playCountLabel(0, 240), '0 次');
      expect(playCountLabel(120, null), '0 次');
    });

    test('播放时长展示', () {
      expect(playSecLabel(0), '0 秒');
      expect(playSecLabel(42), '42 秒');
      expect(playSecLabel(185), '3 分 5 秒');
      expect(playSecLabel(180), '3 分');
      expect(playSecLabel(43200), '12 小时');
      expect(playSecLabel(45000), '12 小时 30 分');
    });
  });
}
