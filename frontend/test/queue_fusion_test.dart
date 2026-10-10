import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/deep_list.dart';
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

bool _same(Song a, Song b) =>
    a.sourceKey == b.sourceKey && a.sourceRef == b.sourceRef;

void main() {
  // ---- fusedQueueOf：固定首位接续（深层占前 N，歌单第 N+1 位起接续） ----

  group('fusedQueueOf', () {
    test('深层为空 → 原样返回歌单副本', () {
      final base = [_song('a'), _song('b'), _song('c')];
      expect(PlayerProvider.fusedQueueOf(const [], base).map((s) => s.sourceRef),
          ['a', 'b', 'c']);
      expect(PlayerProvider.fusedQueueOf(const [], base),
          isNot(same(base))); // 副本，不共享可变引用
    });

    test('深层 N 首占前 N 位，歌单第 N+1 位起接续（总长=歌单长）', () {
      final base = [_song('p1'), _song('p2'), _song('p3'), _song('p4')];
      final deep = [_song('p1'), _song('p2')]; // 已播 p1 p2
      final fused = PlayerProvider.fusedQueueOf(deep, base);
      expect(fused.map((s) => s.sourceRef), ['p1', 'p2', 'p3', 'p4']);
      expect(fused.length, base.length);
    });

    test('深层大于歌单长 → 余部为空，只保留深层前 N', () {
      final base = [_song('p1'), _song('p2')];
      final deep = [_song('a'), _song('b'), _song('c')];
      expect(PlayerProvider.fusedQueueOf(deep, base).map((s) => s.sourceRef),
          ['a', 'b', 'c']);
    });

    test('不按内容去重：深层与尾区可同时出现同一首歌', () {
      final base = [_song('x'), _song('y'), _song('x')];
      final deep = [_song('x')];
      expect(PlayerProvider.fusedQueueOf(deep, base).map((s) => s.sourceRef),
          ['x', 'y', 'x']);
    });
  });

  // ---- fusedIndexFor：歌单行在融合队列中的位置映射 ----

  group('fusedIndexFor', () {
    Song s(String r) => _song(r);

    test('深层为空 → 行号即融合位', () {
      final base = [s('a'), s('b'), s('c')];
      final fused = PlayerProvider.fusedQueueOf(const [], base);
      expect(PlayerProvider.fusedIndexFor(1, 0, fused, base, _same), 1);
      expect(PlayerProvider.fusedIndexFor(2, 0, fused, base, _same), 2);
    });

    test('行号 >= 深层长度 → 尾区位置即自身', () {
      final base = [s('p1'), s('p2'), s('p3'), s('p4')];
      final deep = [s('p1'), s('p2')];
      final fused = PlayerProvider.fusedQueueOf(deep, base);
      expect(PlayerProvider.fusedIndexFor(2, 2, fused, base, _same), 2);
      expect(PlayerProvider.fusedIndexFor(3, 2, fused, base, _same), 3);
    });

    test('行号在深层内 → 按身份定位（可能多于一位取首个）', () {
      final base = [s('p1'), s('p2'), s('p3')];
      final deep = [s('p1'), s('p2')];
      final fused = PlayerProvider.fusedQueueOf(deep, base);
      expect(PlayerProvider.fusedIndexFor(0, 2, fused, base, _same), 0);
      expect(PlayerProvider.fusedIndexFor(1, 2, fused, base, _same), 1);
    });

    test('深层内有同名不同源 → 身份不匹配，退回深层末尾', () {
      Song o(String r) => Song(
          id: 0,
          sourceKey: 'server',
          title: r,
          source: 'webdav',
          sourceRef: '/x/$r',
          fileSize: 0);
      final base = [o('p1'), o('p2'), s('p3')];
      final deep = [s('p1'), s('p2')];
      final fused = PlayerProvider.fusedQueueOf(deep, base);
      // 深层内两条走行号路径：行 0 的 o('p1') 与深层 s('p1') 不同源，
      // 融合队列里身份匹配不到 o('p1') → 退回深层末尾(1)。
      expect(PlayerProvider.fusedIndexFor(0, 2, fused, base, _same), 1);
      // 行 1 的 o('p2') 也匹配不到 → 同样退回深层末尾(1)。
      expect(PlayerProvider.fusedIndexFor(1, 2, fused, base, _same), 1);
    });
  });

  // ---- 融合队列的「播完一轮清空重来」与重播去重由 DeepListController 保证，
  //      这里用与其一致的容量语义验证融合形状闭环 ----

  group('融合闭环（DeepListController 容量语义）', () {
    test('播完一轮：深层超容量清空重来 → 队列重头接续', () {
      final base = [_song('p1'), _song('p2'), _song('p3')];
      final dl = DeepListController(capacity: base.length);
      for (final s in base) {
        dl.pushPlayed(s, same: _same);
      }
      expect(PlayerProvider.fusedQueueOf(dl.entries, base)
          .map((ss) => ss.sourceRef), ['p1', 'p2', 'p3']);

      // 下一首超出容量 → 清空后从当前曲重新开始。
      dl.pushPlayed(_song('p1'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['p1']);
      expect(PlayerProvider.fusedQueueOf(dl.entries, base)
          .map((s) => s.sourceRef), ['p1', 'p2', 'p3']);
    });

    test('歌单删歌缩容量 → 深层收缩后队列仍以深层头部接续', () {
      final base = [_song('p1'), _song('p2'), _song('p3')];
      final dl = DeepListController(capacity: 3);
      for (final s in base) {
        dl.pushPlayed(s, same: _same);
      }
      dl.capacity = 2; // 歌单删到 2 首
      dl.removeRef(_song('p3'), same: _same);
      expect(PlayerProvider.fusedQueueOf(dl.entries, base)
          .map((s) => s.sourceRef), ['p1', 'p2', 'p3']);
    });

    test('外部点歌随 1.3a：保留深层但合并至歌单上下文（playSong 路径语义）', () {
      // playSong 外部点歌替换末尾；当前播放的仍是歌单内 → 深层尾部换曲不增长。
      final base = [_song('p1'), _song('p2'), _song('p3')];
      final dl = DeepListController(capacity: 3, entries: [_song('p1')]);
      dl.replaceTail(_song('outside'), same: _same); // 替换末尾，长仍 1
      expect(dl.entries.map((s) => s.sourceRef), ['outside']);
      expect(PlayerProvider.fusedQueueOf(dl.entries, base)
          .map((s) => s.sourceRef), ['outside', 'p2', 'p3']);
    });

    test('外部点歌深层为空 → 直接推入（首个列表即锚定）', () {
      final base = [_song('p1'), _song('p2')];
      final dl = DeepListController(capacity: 2);
      dl.replaceTail(_song('liked1'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['liked1']);
      expect(PlayerProvider.fusedQueueOf(dl.entries, base)
          .map((s) => s.sourceRef), ['liked1', 'p2']);
    });
  });

  group('锚定键', () {
    test('各上下文 key 构造与唯一性', () {
      expect(PlayerProvider.anchorForPlaylist('u1'), 'playlist:u1');
      expect(PlayerProvider.anchorForLiked(), 'liked');
      expect(PlayerProvider.anchorForSongs(), 'songs');
      expect(PlayerProvider.anchorForAlbum(7), 'album:7');
      expect(PlayerProvider.anchorForArtist('周'), 'artist:周');
      expect(PlayerProvider.anchorForSource('webdav:x'), 'source:webdav:x');
      expect(PlayerProvider.anchorForPlaylist('u1'),
          isNot(PlayerProvider.anchorForLiked()));
    });
  });

  group('删歌同步 / 容量收缩', () {
    test('删非当前播放的歌：深层同步 removeRef，不播放切换', () {
      final dl = DeepListController(capacity: 3,
          entries: [_song('p1'), _song('p2')]);
      dl.capacity = 2; // 歌单删到 2 首
      dl.removeRef(_song('p1'), same: _same); // 非当前删除（p2 仍在）
      expect(dl.entries.map((s) => s.sourceRef), ['p2']);
    });
  });

  group('重锚（播放全部清空深层）', () {
    test('reset 后深层清空，队列回到歌单原序', () {
      // 播放全部：DeepListController 以空 entries 重建（清空重来）。
      final base = [_song('p1'), _song('p2'), _song('p3')];
      final dl = DeepListController(capacity: 3,
          entries: [_song('p1'), _song('p2')]);
      final reset = DeepListController(capacity: 3); // reset -> 空栈
      expect(reset.entries, isEmpty);
      expect(PlayerProvider.fusedQueueOf(reset.entries, base)
          .map((s) => s.sourceRef), ['p1', 'p2', 'p3']);
      expect(dl.entries.map((s) => s.sourceRef), ['p1', 'p2']);
    });
  });

  group('上一首（弹深层末尾）', () {
    test('深层 ≥2：弹出末尾，新末尾成为当前曲', () {
      final dl = DeepListController(capacity: 5,
          entries: [_song('a'), _song('b'), _song('c')]);
      final popped = dl.popTail();
      expect(popped?.sourceRef, 'c');
      expect(dl.tail?.sourceRef, 'b');
      // 弹栈后队列总长不变：深层收缩 1，基座尾部重接一首。
      final base = List.generate(5, (i) => _song('p${i + 1}'));
      expect(PlayerProvider.fusedQueueOf(dl.entries, base)
          .map((s) => s.sourceRef), ['a', 'b', 'p3', 'p4', 'p5']);
    });
  });

  group('手动点播换尾后的融合形状（点播一律替换末尾，不增长）', () {
    List<Song> base6() => [for (var i = 1; i <= 6; i++) _song('s$i')];

    test('自动 s1→s5（推入）后点播 s3（换尾）：深层 [s1,s3]，队列带接缝复本',
        () {
      final base = base6();
      final dl = DeepListController(capacity: base.length);
      dl.pushPlayed(_song('s1'), same: _same); // 首播
      dl.pushPlayed(_song('s5'), same: _same); // 自动推进到 s5
      dl.replaceTail(_song('s3'), same: _same); // 手动点播 s3：换尾不增长
      expect(dl.entries.map((s) => s.sourceRef), ['s1', 's3']);
      // 切分仍按深层长度 n=2：续播段 base[2:] 首位恰为 s3（接缝复本，不断言去重）。
      expect(PlayerProvider.fusedQueueOf(dl.entries, base)
          .map((s) => s.sourceRef), ['s1', 's3', 's3', 's4', 's5', 's6']);
    });

    test('连续点播不增长深层：换尾两次长度仍为 2', () {
      final dl = DeepListController(capacity: 6,
          entries: [_song('s1'), _song('s5')]);
      dl.replaceTail(_song('s3'), same: _same);
      dl.replaceTail(_song('s2'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['s1', 's2']);
    });
  });

  group('skipSeamDupIndex（顺序推进越过接缝复本）', () {
    List<Song> q(List<String> refs) => [for (final r in refs) _song(r)];

    test('落到接缝复本上（== 深层长且同首）→ 越过一位', () {
      final queue = q(['s1', 's3', 's3', 's4', 's5', 's6']);
      expect(
          PlayerProvider.skipSeamDupIndex(
              2, 2, queue, _song('s3'), _same, anchored: true),
          3);
    });

    test('落点是真正的下一首（不同歌）→ 不动', () {
      final queue = q(['s1', 's5', 's3', 's4', 's5', 's6']);
      expect(
          PlayerProvider.skipSeamDupIndex(
              2, 2, queue, _song('s5'), _same, anchored: true),
          2);
    });

    test('同首但不在接缝位（深层内复本）→ 不动', () {
      final queue = q(['s1', 's3', 's3', 's4']);
      expect(
          PlayerProvider.skipSeamDupIndex(
              1, 2, queue, _song('s3'), _same, anchored: true),
          1);
    });

    test('非锚定普通队列 → 不动（无融合接缝）', () {
      final queue = q(['a', 'a', 'b']);
      expect(
          PlayerProvider.skipSeamDupIndex(
              0, 0, queue, _song('a'), _same, anchored: false),
          0);
    });

    test('越过队尾（== 队长）→ 原样返回，由调用方收尾', () {
      final queue = q(['s1', 's3']);
      expect(
          PlayerProvider.skipSeamDupIndex(
              2, 2, queue, _song('s3'), _same, anchored: true),
          2);
    });
  });

  group('locateCurrentIndex（定位优先深层尾）', () {
    List<Song> q(List<String> refs) => [for (final r in refs) _song(r)];

    test('深层尾与目标同首 → 取尾下标，不取旧复本', () {
      final queue = q(['s3', 's1', 's3', 's4']);
      expect(PlayerProvider.locateCurrentIndex(queue, 3, _song('s3'), _same),
          2); // 旧口径 indexWhere 会给 0
    });

    test('深层尾不是目标 → 首个匹配', () {
      final queue = q(['s3', 's1', 's3', 's4']);
      expect(PlayerProvider.locateCurrentIndex(queue, 3, _song('s1'), _same),
          1);
    });

    test('找不到 → -1；深层空 → 首个匹配', () {
      final queue = q(['s1', 's3']);
      expect(PlayerProvider.locateCurrentIndex(queue, 2, _song('s9'), _same),
          -1);
      expect(PlayerProvider.locateCurrentIndex(queue, 0, _song('s3'), _same),
          1);
    });
  });
}