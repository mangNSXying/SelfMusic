import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/player_provider.dart';

/// 「下一首播放」：歌曲列表三点菜单的新入口。
///
/// 锚定上下文（歌单/喜欢/专辑…）下队列不是普通 List，而是
/// 「深层历史 ‖ 基座续播段」的融合投影，总长恒等于基座长度，且每次播放成功都会
/// 被 [_rebuildFusedQueue] 按基座整段重算。因此「下一首播放」不能直接
/// `_queue.insert`，必须由 [_nextUp] 预载槽承载并参与拼接，否则切一次歌就原形毕露。
///
/// 语义是**替换**而非**插入**：预载只有一格，排新的顶掉原先那首，队列不腾位置。
Song _song(String ref) => Song(
      id: 0,
      sourceKey: 'local:x',
      title: ref,
      source: 'local',
      sourceRef: ref,
      fileSize: 0,
    );

void main() {
  group('fusedQueueOf + nextUp（下一首播放替换后的融合队列）', () {
    test('nextUp 为空 → 与旧的「深层 ‖ 基座」完全等价', () {
      final base = [_song('p1'), _song('p2'), _song('p3')];
      final deep = [_song('p1'), _song('p2')];
      expect(
        PlayerProvider.fusedQueueOf(deep, base).map((s) => s.sourceRef),
        ['p1', 'p2', 'p3'],
      );
    });

    test('预载项替换掉基座的下一首，队列长度不变', () {
      final base = [_song('p1'), _song('p2'), _song('p3'), _song('p4')];
      final deep = [_song('p1'), _song('p2')]; // 已播 p1 p2
      final fused =
          PlayerProvider.fusedQueueOf(deep, base, nextUp: _song('zz'));
      // p3 正是「原本预订的下一首」，被 zz 顶掉；p4 顺移补位。
      expect(fused.map((s) => s.sourceRef), ['p1', 'p2', 'zz', 'p4']);
      // 核心不变量：替换不腾位置，总长恒等于基座长。
      expect(fused.length, base.length);
    });

    test('再排一首 → 顶掉原先排的那首，队列长度依旧不变', () {
      final base = [_song('p1'), _song('p2'), _song('p3')];
      final deep = [_song('p1')];
      final afterX =
          PlayerProvider.fusedQueueOf(deep, base, nextUp: _song('x'));
      final afterY =
          PlayerProvider.fusedQueueOf(deep, base, nextUp: _song('y'));
      expect(afterX.map((s) => s.sourceRef), ['p1', 'x', 'p3']);
      expect(afterY.map((s) => s.sourceRef), ['p1', 'y', 'p3']);
      // x 被 y 替换掉，不会两者并存。
      expect(afterY.length, base.length);
    });

    test('深层为空（锚定后还没播过）→ 预载项占队首，基座首位被顶掉', () {
      final base = [_song('p1'), _song('p2')];
      final fused =
          PlayerProvider.fusedQueueOf(const [], base, nextUp: _song('zz'));
      expect(fused.map((s) => s.sourceRef), ['zz', 'p2']);
      expect(fused.length, base.length);
    });

    test('深层已覆盖整个基座（没有下一首可顶）→ 预载项追加在末尾', () {
      final base = [_song('p1')];
      final deep = [_song('a'), _song('b')];
      final fused =
          PlayerProvider.fusedQueueOf(deep, base, nextUp: _song('zz'));
      expect(fused.map((s) => s.sourceRef), ['a', 'b', 'zz']);
    });

    test('预载项本身在基座里出现过也不去重（沿用既有不按内容去重语义）', () {
      final base = [_song('x'), _song('y')];
      final deep = [_song('x')];
      final fused = PlayerProvider.fusedQueueOf(deep, base, nextUp: _song('x'));
      expect(fused.map((s) => s.sourceRef), ['x', 'x']);
      expect(fused.length, base.length);
    });

    test('预载项播完出队后，原被顶掉的那首不会复活', () {
      final base = [_song('p1'), _song('p2'), _song('p3')];
      // 预载 zz 顶掉 p2；zz 播完进入深层历史，深层长 2，基座从第 3 位接续。
      final afterPlayed = [_song('p1'), _song('zz')];
      final fused = PlayerProvider.fusedQueueOf(afterPlayed, base);
      expect(fused.map((s) => s.sourceRef), ['p1', 'zz', 'p3']);
      expect(fused.length, base.length);
    });
  });
}
