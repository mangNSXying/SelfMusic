import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/collection_sort.dart';

Song _song(String title, {String sourceRef = '', int? duration}) => Song(
      id: 0,
      sourceKey: 'local:x',
      title: title,
      source: 'local',
      sourceRef: sourceRef.isEmpty ? title : sourceRef,
      fileSize: 0,
      duration: duration,
    );

void main() {
  test('sortByChars：大小写无关升降序', () {
    final items = ['banana', 'Apple', 'cherry'];
    expect(sortByChars(items, (s) => s, false),
        ['Apple', 'banana', 'cherry']);
    expect(sortByChars(items, (s) => s, true),
        ['cherry', 'banana', 'Apple']);
    // 原列表不被修改
    expect(items, ['banana', 'Apple', 'cherry']);
  });

  test('sortByCollection：默认不排序，权重项被忽略（非歌曲页无权重）', () {
    final items = ['b', 'a'];
    expect(sortByCollection(items, CollectionSort.defaultOrder, (s) => s),
        items);
    expect(sortByCollection(items, CollectionSort.weightDesc, (s) => s), items);
    expect(sortByCollection(items, CollectionSort.charAsc, (s) => s),
        ['a', 'b']);
  });

  test('songSortOrder：权重升降 + 同权重按标题稳定回退', () {
    final songs = [
      _song('C', sourceRef: 'c'),
      _song('A', sourceRef: 'a'),
      _song('B', sourceRef: 'b'),
    ];
    final weights = {'a': 0.5, 'b': 1.5, 'c': 1.5};
    double f(Song s) => weights[s.sourceRef]!;

    final asc = songSortOrder(songs, CollectionSort.weightAsc, factorOf: f);
    expect([for (final i in asc) songs[i].title], ['A', 'B', 'C']);
    final desc = songSortOrder(songs, CollectionSort.weightDesc, factorOf: f);
    expect([for (final i in desc) songs[i].title], ['B', 'C', 'A']);
  });

  group('改进.txt 新增排序字段', () {
    test('播放时长升/降序（playSecOf）', () {
      final songs = [
        _song('A', sourceRef: 'a'),
        _song('B', sourceRef: 'b'),
        _song('C', sourceRef: 'c'),
      ];
      final sec = {'a': 300, 'b': 60, 'c': 600};
      int ps(Song s) => sec[s.sourceRef]!;
      expect(
        [for (final i in songSortOrder(songs, CollectionSort.playTimeAsc, playSecOf: ps)) songs[i].sourceRef],
        ['b', 'a', 'c'],
      );
      expect(
        [for (final i in songSortOrder(songs, CollectionSort.playTimeDesc, playSecOf: ps)) songs[i].sourceRef],
        ['c', 'a', 'b'],
      );
    });

    test('播放次数升/降序（由 playSec÷时长 派生，与展示同口径）', () {
      final songs = [
        _song('A', sourceRef: 'a', duration: 100), // 100/100 = 1.0
        _song('B', sourceRef: 'b', duration: 300), // 60/300 = 0.2
        _song('C', sourceRef: 'c', duration: 200), // 500/200 = 2.5
      ];
      final sec = {'a': 100, 'b': 60, 'c': 500};
      int ps(Song s) => sec[s.sourceRef]!;
      expect(
        [for (final i in songSortOrder(songs, CollectionSort.playCountAsc, playSecOf: ps)) songs[i].sourceRef],
        ['b', 'a', 'c'],
      );
      expect(
        [for (final i in songSortOrder(songs, CollectionSort.playCountDesc, playSecOf: ps)) songs[i].sourceRef],
        ['c', 'a', 'b'],
      );
    });

    test('歌曲时长升/降序，时长未知恒排最后', () {
      final songs = [
        _song('A', sourceRef: 'a', duration: 300),
        _song('B', sourceRef: 'b'),
        _song('C', sourceRef: 'c', duration: 100),
      ];
      expect(
        [for (final i in songSortOrder(songs, CollectionSort.durationAsc)) songs[i].sourceRef],
        ['c', 'a', 'b'],
      );
      expect(
        [for (final i in songSortOrder(songs, CollectionSort.durationDesc)) songs[i].sourceRef],
        ['a', 'c', 'b'],
      );
    });

    test('缺数据源时退化为标题序（不抖动）', () {
      final songs = [
        _song('C', sourceRef: 'c'),
        _song('A', sourceRef: 'a'),
      ];
      expect(
        [for (final i in songSortOrder(songs, CollectionSort.playTimeDesc)) songs[i].sourceRef],
        ['a', 'c'],
      );
    });

    test('曲数升/降序（同数按名称）', () {
      final items = [
        (name: 'b', count: 3),
        (name: 'a', count: 1),
        (name: 'c', count: 3),
      ];
      int count(({String name, int count}) e) => e.count;
      String name(({String name, int count}) e) => e.name;
      expect(
        [
          for (final e in sortByCollection(
              items, CollectionSort.countAsc, name,
              countOf: count))
            e.name
        ],
        ['a', 'b', 'c'],
      );
      expect(
        [
          for (final e in sortByCollection(
              items, CollectionSort.countDesc, name,
              countOf: count))
            e.name
        ],
        ['b', 'c', 'a'],
      );
      // 未提供 countOf → 保持原序
      expect(sortByCollection(items, CollectionSort.countDesc, name), items);
    });

    test('scope：曲数只在集合页，权重/播放统计只在歌曲页', () {
      for (final s in CollectionSort.values) {
        if (s.isCount) {
          expect(s.availableIn(SortScope.collections), isTrue);
          expect(s.availableIn(SortScope.songs), isFalse);
        } else if (s.isWeight || s.isPlayStat) {
          expect(s.availableIn(SortScope.songs), isTrue);
          expect(s.availableIn(SortScope.collections), isFalse);
        } else {
          expect(s.availableIn(SortScope.songs), isTrue);
          expect(s.availableIn(SortScope.collections), isTrue);
        }
      }
    });

    test('方向翻转与标签', () {
      expect(CollectionSort.charAsc.flipped, CollectionSort.charDesc);
      expect(CollectionSort.countDesc.flipped, CollectionSort.countAsc);
      expect(CollectionSort.playCountAsc.flipped, CollectionSort.playCountDesc);
      expect(CollectionSort.defaultOrder.flipped, CollectionSort.defaultOrder);
      expect(CollectionSort.charDesc.isDesc, isTrue);
      expect(CollectionSort.countAsc.isDesc, isFalse);
      expect(CollectionSort.playTimeDesc.lineLabel, '播放时长 ↓');
      expect(CollectionSort.durationAsc.lineLabel, '时长 ↑');
      // 持久化解析覆盖新枚举值
      for (final v in CollectionSort.values) {
        expect(CollectionSortX.parse(v.name), v);
      }
    });
  });

  test('collection sort 持久化解析：未知/空值回退默认', () {
    expect(CollectionSortX.parse(null), CollectionSort.defaultOrder);
    expect(CollectionSortX.parse('bad'), CollectionSort.defaultOrder);
    for (final v in CollectionSort.values) {
      expect(CollectionSortX.parse(v.name), v);
    }
    expect(CollectionSort.weightAsc.isWeight, isTrue);
    expect(CollectionSort.charAsc.isWeight, isFalse);
  });
}
