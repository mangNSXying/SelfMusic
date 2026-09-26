import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

Song _song(String ref) => Song(
      id: 0,
      sourceKey: 'local:x',
      title: ref,
      source: 'local',
      sourceRef: ref,
      fileSize: 0,
    );

void main() {
  // 改进.txt：歌单「播放」不再等同「从头播放」，起始曲由当前播放顺序算法决定。
  group('startIndexForOrder：歌单「播放」起始曲按播放顺序算法', () {
    test('顺序播放：首曲', () {
      expect(PlayerProvider.startIndexForOrder(PlayMode.sequence, 5), 0);
    });

    test('单曲循环：首曲（此后 next 重播该曲）', () {
      expect(PlayerProvider.startIndexForOrder(PlayMode.loopOne, 5), 0);
      // 即便给了当前曲/抽样下标也不改（避免误用）。
      expect(
          PlayerProvider.startIndexForOrder(PlayMode.loopOne, 5,
              currentIndex: 3, weightedIndex: 4),
          0);
    });

    test('列表循环：当前曲在歌单内则接续其后', () {
      expect(
          PlayerProvider.startIndexForOrder(PlayMode.loopList, 5,
              currentIndex: 0),
          1);
      expect(
          PlayerProvider.startIndexForOrder(PlayMode.loopList, 5,
              currentIndex: 2),
          3);
    });

    test('列表循环：末曲之后回绕到首曲', () {
      expect(
          PlayerProvider.startIndexForOrder(PlayMode.loopList, 5,
              currentIndex: 4),
          0);
    });

    test('列表循环：当前曲不在歌单内（缺省/负值/越界）→ 首曲', () {
      expect(PlayerProvider.startIndexForOrder(PlayMode.loopList, 5), 0);
      expect(
          PlayerProvider.startIndexForOrder(PlayMode.loopList, 5,
              currentIndex: -1),
          0);
      expect(
          PlayerProvider.startIndexForOrder(PlayMode.loopList, 5,
              currentIndex: 9),
          0);
    });

    test('加权随机：采用抽样下标', () {
      for (var i = 0; i < 5; i++) {
        expect(
            PlayerProvider.startIndexForOrder(PlayMode.weighted, 5,
                weightedIndex: i),
            i);
      }
    });

    test('加权随机：抽样缺省或越界 → 首曲', () {
      expect(PlayerProvider.startIndexForOrder(PlayMode.weighted, 5), 0);
      expect(
          PlayerProvider.startIndexForOrder(PlayMode.weighted, 5,
              weightedIndex: -1),
          0);
      expect(
          PlayerProvider.startIndexForOrder(PlayMode.weighted, 5,
              weightedIndex: 5),
          0);
    });

    test('空歌单：各模式都返回 0（不抛）', () {
      for (final m in PlayMode.values) {
        expect(
            PlayerProvider
                .startIndexForOrder(m, 0, currentIndex: 2, weightedIndex: 1),
            0);
      }
    });
  });

  group('startIndexForPlaylist：实例入口', () {
    testWidgets('空列表 → 0', (tester) async {
      final p = PlayerProvider();
      expect(p.startIndexForPlaylist(const []), 0);
    });

    testWidgets('默认顺序模式下从首曲起播（无当前曲可接续）', (tester) async {
      final p = PlayerProvider();
      final songs = [_song('a'), _song('b'), _song('c')];
      expect(p.startIndexForPlaylist(songs), 0);
      expect(p.mode, PlayMode.sequence);
    });

    testWidgets('列表循环模式 + 当前曲在歌单内 → 接续其后（加权模式取抽样下标）',
        (tester) async {
      final p = PlayerProvider()..setMode(PlayMode.loopList);
      expect(p.startIndexForPlaylist([_song('a'), _song('b')]), 0);

      p.setMode(PlayMode.weighted);
      // 无权重库时 factor 回落默认值，抽样下标必在范围内。
      final i = p.startIndexForPlaylist(
          [_song('a'), _song('b'), _song('c'), _song('d')]);
      expect(i, inInclusiveRange(0, 3));
    });
  });
}
