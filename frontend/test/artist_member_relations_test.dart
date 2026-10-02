import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/artist_resolver.dart';

/// MB `artist-rels` 的形状（2026-10 实测自 musicbrainz.org/ws/2）：
/// - 对端实体在 `artist` 键下（不是 `target`）；
/// - type 首字母大写：`Group` / `Character` / `Person`；
/// - `direction` 只说明当前实体是关系哪一端，**不能**用来判断谁是成员
///   （`振り回され隊` 名下三条 member of band 全是 backward，成员却是它自己带的）。
Map<String, dynamic> _rel(
        String type, String direction, String name, String ttype, String id) =>
    {
      'type': type,
      'direction': direction,
      'target-type': 'artist',
      'artist': {'name': name, 'type': ttype, 'id': id},
    };

void main() {
  group('成员边判定：按关系类型 + 对端 type，不看 direction', () {
    test('Group 的 member of band（即使 backward）建成员边', () {
      final rels = [
        _rel('member of band', 'backward', 'チノ', 'Character', 'c1'),
        _rel('member of band', 'backward', 'リゼ', 'Character', 'c2'),
        _rel('member of band', 'backward', 'シャロ', 'Character', 'c3'),
      ];
      final members = ArtistResolver.parseMemberRelations(rels, 'group');
      expect(members.map((m) => m['name']), ['チノ', 'リゼ', 'シャロ']);
      expect(members.map((m) => m['type']),
          ['character', 'character', 'character']);
      expect(members.every((m) => m['mbid'] != null), isTrue);
      expect(members.first['relation'], 'member of band');
    });

    test('Character 的 voice actor（backward）建成员边到 Person', () {
      final rels = [
        _rel('member of band', 'forward', '振り回され隊', 'Group', 'g1'),
        _rel('voice actor', 'backward', '内田真礼', 'Person', 'p1'),
      ];
      final members = ArtistResolver.parseMemberRelations(rels, 'character');
      // 「所属团体」是反向信息，不建边；只有声优算成员。
      expect(members.map((m) => m['name']), ['内田真礼']);
      expect(members.single['type'], 'person');
    });

    test('Person 的 voice actor（本人声优过的角色）不建边', () {
      final rels = [
        _rel('voice actor', 'forward', 'シャロ', 'Character', 'c3'),
        _rel('member of band', 'backward', '振り回され隊', 'Group', 'g1'),
      ];
      expect(ArtistResolver.parseMemberRelations(rels, 'person'), isEmpty);
    });

    test('Person 的 member of band 指向 Group 不建边（否则与团体成环）', () {
      final rels = [
        _rel('member of band', 'backward', 'ぴこぱにろ', 'Group', 'g2'),
      ];
      expect(ArtistResolver.parseMemberRelations(rels, 'person'), isEmpty);
    });

    test('collaboration 双方同级，不建边', () {
      final rels = [
        _rel('collaboration', 'backward', '某组合', 'Group', 'g3'),
      ];
      expect(ArtistResolver.parseMemberRelations(rels, 'group'), isEmpty);
    });

    test('缺 mbid / 空名 / 重复对端都跳过', () {
      final rels = [
        _rel('member of band', 'backward', '无名', 'Person', ''),
        _rel('member of band', 'backward', '', 'Person', 'p9'),
        _rel('member of band', 'backward', '重复', 'Person', 'p1'),
        _rel('member of band', 'backward', '重复', 'Person', 'p1'),
      ];
      final members = ArtistResolver.parseMemberRelations(rels, 'group');
      expect(members, hasLength(1));
      expect(members.single['mbid'], 'p1');
    });

    test('真实样本：振り回され隊 → 3 个 Character → 内田真礼', () {
      // 第一跳：组合带 3 个 Character。
      final group = ArtistResolver.parseMemberRelations(
          [_rel('member of band', 'backward', 'チノ', 'Character', 'c1')],
          'group');
      // 第二跳：其中「シャロ」的声优。
      final char = ArtistResolver.parseMemberRelations(
          [_rel('voice actor', 'backward', '内田真礼', 'Person', 'p1')],
          'character');
      expect(group.single['type'], 'character');
      expect(char.single['type'], 'person');
    });
  });

  group('采纳策略：脏数据过滤后取首个候选（不判断 strong）', () {
    test('ASCII 撇号查询 → 命中 MB 的弯撇号写法', () {
      final hits = [
        const MbArtistHit(
            mbid: 'aa5cab6f-9827-4a6f-bdf2-a4b5e5608598',
            name: 'Petit Rabbit\u2019s',
            type: 'Group',
            score: 100),
      ];
      final pick = ArtistResolver.pickFirstUsable(hits);
      expect(pick, isNotNull);
      expect(pick!.name, 'Petit Rabbit\u2019s');
      expect(pick.score, 100);
    });

    test('跳过占位名/低分/未知类型，取第一个可用候选', () {
      final hits = [
        const MbArtistHit(
            mbid: 'x', name: '[no artist]', type: 'Other', score: 63),
        const MbArtistHit(
            mbid: 'y', name: 'Various Artists', type: 'Other', score: 87),
        const MbArtistHit(
            mbid: 'z', name: '[unknown]', type: 'Other', score: 68),
        const MbArtistHit(mbid: 'w', name: 'Alias', type: 'Person', score: 68),
        const MbArtistHit(mbid: 'low', name: '同名噪声', type: 'Person', score: 41),
        const MbArtistHit(
            mbid: 'ok', name: '宇多田ヒカル', type: 'Person', score: 87),
      ];
      final pick = ArtistResolver.pickFirstUsable(hits);
      expect(pick!.mbid, 'ok');
    });

    test('MB 的 type 首字母大写照样识别（否则全被当未知类型挡掉）', () {
      for (final t in ['Person', 'Group', 'Character', 'Orchestra', 'Other']) {
        final pick = ArtistResolver.pickFirstUsable(
            [MbArtistHit(mbid: 'a', name: '名字', type: t, score: 100)]);
        expect(pick, isNotNull, reason: '$t 应被接受');
      }
      // 不在白名单里的类型（如 MB 的 Location/Event 实体）挡掉。
      expect(
          ArtistResolver.pickFirstUsable([
            const MbArtistHit(
                mbid: 'a', name: '某个场所', type: 'Place', score: 100)
          ]),
          isNull);
    });

    test('全被过滤 → null（退回 local 退避重试）', () {
      expect(
          ArtistResolver.pickFirstUsable([
            const MbArtistHit(
                mbid: '', name: '无 id', type: 'Person', score: 100),
            const MbArtistHit(
                mbid: 'a', name: '  ', type: 'Person', score: 100),
            const MbArtistHit(
                mbid: 'b', name: '[no artist]', type: 'Other', score: 100),
          ]),
          isNull);
    });
  });

  group('groups JSON：所属团体/角色', () {
    test('Person 的 member of band 记进 groups', () {
      final rels = [
        _rel('member of band', 'backward', 'ぴこぱにろ', 'Group', 'g2'),
        _rel('voice actor', 'forward', 'シャロ', 'Character', 'c3'),
      ];
      final groups = ArtistResolver.parseGroupRelations(rels);
      expect(groups.map((g) => g['name']), ['ぴこぱにろ', 'シャロ']);
      expect(groups.first['mbid'], 'g2');
      expect(groups.first['target_type'], 'Group');
    });

    test('重复关系去重；白名单外类型忽略', () {
      final rels = [
        _rel('member of band', 'backward', 'A团', 'Group', 'g1'),
        _rel('member of band', 'forward', 'A团', 'Group', 'g1'),
        _rel('url', 'forward', 'example.com', 'Other', 'x1'),
      ];
      expect(ArtistResolver.parseGroupRelations(rels), hasLength(1));
    });
  });
}
