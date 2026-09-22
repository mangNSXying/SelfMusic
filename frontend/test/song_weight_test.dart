import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
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

Future<(LocalIndex, SongWeightStore)> _openWeightStore() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_weight_');
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

void main() {
  group('完播/跳过阈值分档（>95% 完播 / <30% 跳过 / 30%~95% 不记）', () {
    const dur = Duration(minutes: 4); // 240s

    test('播放时长 >95% 记完播 = 100%、96%', () {
      expect(judgeWeightRatio(dur, const Duration(minutes: 4)),
          WeightJudgement.complete);
      expect(judgeWeightRatio(dur, const Duration(seconds: 230, milliseconds: 500)),
          WeightJudgement.complete);
    });

    test('临界 95% 不记', () {
      expect(judgeWeightRatio(dur, const Duration(seconds: 228)),
          WeightJudgement.none);
    });

    test('30%~95% 区间不记', () {
      expect(judgeWeightRatio(dur, const Duration(seconds: 120)),
          WeightJudgement.none);
      expect(judgeWeightRatio(dur, const Duration(minutes: 2, seconds: 16)),
          WeightJudgement.none);
    });

    test('<30% 记跳过，临界 30% 不记', () {
      expect(judgeWeightRatio(dur, const Duration(seconds: 70)),
          WeightJudgement.skip);
      expect(judgeWeightRatio(dur, const Duration(seconds: 72)),
          WeightJudgement.none);
    });

    test('时长无效（null/0）时无法判定', () {
      expect(judgeWeightRatio(null, const Duration(seconds: 30)),
          WeightJudgement.none);
      expect(judgeWeightRatio(Duration.zero, const Duration(seconds: 30)),
          WeightJudgement.none);
    });

    test('0 播放进度（未开始）记跳过', () {
      expect(judgeWeightRatio(dur, Duration.zero), WeightJudgement.skip);
    });
  });

  group('SongWeightStore：同曲完播/跳过次数互斥，后来者覆盖', () {
    test('先完播后跳过：完播次数被清零，只留跳过', () async {
      final (_, w) = await _openWeightStore();
      final s = _song('a.mp3');
      w.onCompleted(s);
      w.onCompleted(s); // like_streak=2
      var m = w.metaOf(s);
      expect(m.likeStreak, 2);
      expect(m.dislikeStreak, 0);

      w.onSkipped(s); // 后来者覆盖：完播清零，只留跳过=1
      m = w.metaOf(s);
      expect(m.likeStreak, 0);
      expect(m.dislikeStreak, 1);
      expect(m.factor, SongWeightStore.defaultFactor);
    });

    test('先跳过完播后：跳过次数被清零，只留完播', () async {
      final (_, w) = await _openWeightStore();
      final s = _song('b.mp3');
      w.onSkipped(s);
      w.onSkipped(s); // dislike_streak=2
      var m = w.metaOf(s);
      expect(m.dislikeStreak, 2);
      expect(m.likeStreak, 0);

      w.onCompleted(s); // 后来者覆盖：跳过清零，只留完播=1
      m = w.metaOf(s);
      expect(m.dislikeStreak, 0);
      expect(m.likeStreak, 1);
    });

    test('连续 3 次完播调整一次权重 +0.1 并清零', () async {
      final (_, w) = await _openWeightStore();
      final s = _song('c.mp3');
      w.onCompleted(s);
      w.onCompleted(s);
      expect(w.metaOf(s).factor, SongWeightStore.defaultFactor);
      w.onCompleted(s);
      final m = w.metaOf(s);
      expect(m.factor,
          SongWeightStore.defaultFactor + SongWeightStore.step);
      expect(m.likeStreak, 0);
      expect(m.dislikeStreak, 0);
    });

    test('连续 3 次跳过调整一次权重 −0.1 并清零', () async {
      final (_, w) = await _openWeightStore();
      final s = _song('d.mp3');
      w.onSkipped(s);
      w.onSkipped(s);
      expect(w.metaOf(s).factor, SongWeightStore.defaultFactor);
      w.onSkipped(s);
      final m = w.metaOf(s);
      expect(m.factor,
          SongWeightStore.defaultFactor - SongWeightStore.step);
      expect(m.dislikeStreak, 0);
      expect(m.likeStreak, 0);
    });
  });
}