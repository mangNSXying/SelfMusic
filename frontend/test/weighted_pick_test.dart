import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';
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

Future<LocalIndex> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_weighted_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

Song _song(String sourceKey, String ref) => Song(
      id: 0,
      sourceKey: sourceKey,
      title: ref,
      source: 'source',
      sourceRef: ref,
      fileSize: 0,
    );

// 加权抽样（改进.txt：时长削弱 + 排除当前曲）改造后的确定性验证：
// - 轮盘纯函数：按 [0,total) 连续区段均匀铺权，命中边界归属前一段；
// - 整队批量取权重：由逐首同步查库改为按 sourceKey 分组批量查询。
void main() {
  group('weightedPickByWheel：加权轮盘纯函数', () {
    test('等权：r 落在对应段即命中下标', () {
      expect(PlayerProvider.weightedPickByWheel([1.0, 1.0, 1.0], 0.0), 0);
      expect(PlayerProvider.weightedPickByWheel([1.0, 1.0, 1.0], 0.333), 0);
      expect(PlayerProvider.weightedPickByWheel([1.0, 1.0, 1.0], 0.334), 1);
      expect(PlayerProvider.weightedPickByWheel([1.0, 1.0, 1.0], 0.999999), 2);
    });

    test('加权：区段长度正比权重，命中边界归属前一段', () {
      // total=3：段0=[0,2/3)、段1=[2/3,5/6)、段2=[5/6,1)。
      expect(PlayerProvider.weightedPickByWheel([2, 0.5, 0.5], 0.0), 0);
      expect(PlayerProvider.weightedPickByWheel([2, 0.5, 0.5], 0.66), 0);
      expect(PlayerProvider.weightedPickByWheel([2, 0.5, 0.5], 0.6666666), 0);
      expect(PlayerProvider.weightedPickByWheel([2, 0.5, 0.5], 0.833333), 1);
      expect(PlayerProvider.weightedPickByWheel([2, 0.5, 0.5], 0.83334), 2);
    });

    test('单元素恒命中 0', () {
      expect(PlayerProvider.weightedPickByWheel([0.5], 0.0), 0);
      expect(PlayerProvider.weightedPickByWheel([0.5], 0.99), 0);
    });

    test('r=1 恰在末段末尾，兜底命中末尾', () {
      expect(PlayerProvider.weightedPickByWheel([1, 2, 3], 1.0), 2);
    });
  });

  group('weightedCooldownReject：削峰冷却判定', () {
    test('WeightedDrawCooldown 档位映射（off/weak/normal → 0/0、1/2、2/3）', () {
      expect(WeightedDrawCooldown.off.limitFor(2.0), 0);
      expect(WeightedDrawCooldown.off.limitFor(0.5), 0);
      expect(WeightedDrawCooldown.weak.limitFor(2.0), 1);
      expect(WeightedDrawCooldown.weak.limitFor(0.5), 2);
      expect(WeightedDrawCooldown.normal.limitFor(2.0), 2);
      expect(WeightedDrawCooldown.normal.limitFor(0.5), 3);
      expect(WeightedDrawCooldown.parse('weak'), WeightedDrawCooldown.weak);
      expect(WeightedDrawCooldown.parse('nope'), WeightedDrawCooldown.normal);
      expect(WeightedDrawCooldown.parse(null), WeightedDrawCooldown.normal);
    });

    test('规则1：低权重档前3次抽中抛弃，第4次作数', () {
      const w = 200;
      final limit = WeightedDrawCooldown.normal.lowLimit;
      for (var d = 1; d <= limit; d++) {
        expect(
            PlayerProvider.weightedCooldownReject(
                draws: d, stepsSincePlay: 1000, drawLimit: limit, window: w),
            isTrue,
            reason: '第 $d 次抽中应抛弃');
      }
      expect(
          PlayerProvider.weightedCooldownReject(
              draws: limit + 1,
              stepsSincePlay: 1000,
              drawLimit: limit,
              window: w),
          isFalse);
    });

    test('规则1：高权重档前2次抽中抛弃，第3次作数', () {
      const w = 200;
      final limit = WeightedDrawCooldown.normal.highLimit;
      expect(limit, 2);
      expect(
          PlayerProvider.weightedCooldownReject(
              draws: 1, stepsSincePlay: 1000, drawLimit: limit, window: w),
          isTrue);
      expect(
          PlayerProvider.weightedCooldownReject(
              draws: 2, stepsSincePlay: 1000, drawLimit: limit, window: w),
          isTrue);
      expect(
          PlayerProvider.weightedCooldownReject(
              draws: 3, stepsSincePlay: 1000, drawLimit: limit, window: w),
          isFalse);
    });

    test('规则1 关闭（上限 0）时任何抽中都不因次数被抛弃', () {
      expect(
          PlayerProvider.weightedCooldownReject(
              draws: 1, stepsSincePlay: 1000, drawLimit: 0, window: 0),
          isFalse);
    });

    test('规则2：距上次播放 <= 窗口即抛弃（含边界；窗口 0=关闭）', () {
      expect(
          PlayerProvider.weightedCooldownReject(
              draws: 99, stepsSincePlay: 200, drawLimit: 0, window: 200),
          isTrue);
      expect(
          PlayerProvider.weightedCooldownReject(
              draws: 99, stepsSincePlay: 201, drawLimit: 0, window: 200),
          isFalse);
      expect(
          PlayerProvider.weightedCooldownReject(
              draws: 99, stepsSincePlay: 1, drawLimit: 0, window: 0),
          isFalse);
    });
  });

  group('playFactorsOf / factorsOf：批量读权重', () {
    test('整队均未记录：返回空，上层取默认 1.0', () async {
      final index = await _openIndex();
      addTearDown(index.close);
      final store = SongWeightStore(index);
      final factors = store.factorsOf([_song('k1', 'a.mp3'), _song('k2', 'b.mp3')]);
      expect(factors['k1'], isNull);
      expect(factors['k2'], isNull);
    });

    test('已记录 factor 读回；跨 sourceKey 分组，未命中不放入', () async {
      final index = await _openIndex();
      addTearDown(index.close);
      final store = SongWeightStore(index);
      await index.upsertPlayMeta('k1', 'a.mp3', factor: 1.3);
      await index.upsertPlayMeta('k1', 'b.mp3', factor: 0.7);
      await index.upsertPlayMeta('k2', 'c.mp3', factor: 1.5);
      final factors = store.factorsOf([
        _song('k1', 'a.mp3'),
        _song('k1', 'b.mp3'),
        _song('k1', 'nomatch.mp3'),
        _song('k2', 'c.mp3'),
      ]);
      expect(factors['k1'], {'a.mp3': 1.3, 'b.mp3': 0.7});
      expect(factors['k2'], {'c.mp3': 1.5});
    });

    test('refs 超过单查询分片上限时仍全部读回', () async {
      final index = await _openIndex();
      addTearDown(index.close);
      await index.upsertPlayMeta('k1', 'a.mp3', factor: 1.1);
      await index.upsertPlayMeta('k1', 'b.mp3', factor: 1.2);
      final refs = [for (var i = 0; i < 501; i++) 'x$i.mp3'];
      final factors = index.playFactorsOf('k1', ['a.mp3', ...refs, 'b.mp3']);
      expect(factors, {'a.mp3': 1.1, 'b.mp3': 1.2});
    });

    test('重复 refs 去重', () async {
      final index = await _openIndex();
      addTearDown(index.close);
      await index.upsertPlayMeta('k1', 'a.mp3', factor: 1.4);
      expect(index.playFactorsOf('k1', ['a.mp3', 'a.mp3', 'a.mp3']),
          {'a.mp3': 1.4});
    });
  });

  group('时间戳种子 PRNG：构造时注入可复现', () {
    testWidgets('同一种子相同队列 → 加权起播下标一致（复现序列）', (tester) async {
      final songs = [for (var i = 0; i < 200; i++) _song('k1', 's$i.mp3')];
      for (var trial = 0; trial < 5; trial++) {
        final a = PlayerProvider(rng: Random(trial))..setMode(PlayMode.weighted);
        final b = PlayerProvider(rng: Random(trial))..setMode(PlayMode.weighted);
        expect(a.startIndexForPlaylist(songs), b.startIndexForPlaylist(songs),
            reason: '同种子第 $trial 轮应给出相同抽样');
      }
    });

    testWidgets('不同种子通常得到不同序列', (tester) async {
      final songs = [for (var i = 0; i < 200; i++) _song('k1', 's$i.mp3')];
      final a = PlayerProvider(rng: Random(1))..setMode(PlayMode.weighted);
      final b = PlayerProvider(rng: Random(2))..setMode(PlayMode.weighted);
      final seqA = [for (var k = 0; k < 5; k++) a.startIndexForPlaylist(songs)];
      final seqB = [for (var k = 0; k < 5; k++) b.startIndexForPlaylist(songs)];
      expect(seqA, isNot(equals(seqB)));
    });
  });
}