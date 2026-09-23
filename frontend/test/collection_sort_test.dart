import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/collection_sort.dart';

Song _song(String title, {String sourceRef = ''}) => Song(
      id: 0,
      sourceKey: 'local:x',
      title: title,
      source: 'local',
      sourceRef: sourceRef.isEmpty ? title : sourceRef,
      fileSize: 0,
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
