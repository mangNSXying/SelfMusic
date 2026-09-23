import '../models/song.dart';

/// 内容页排序方式（改进：字符升/降、权重升/降；时间排序已剔除）。
enum CollectionSort { defaultOrder, charAsc, charDesc, weightAsc, weightDesc }

extension CollectionSortX on CollectionSort {
  String get label => switch (this) {
        CollectionSort.defaultOrder => '默认排序',
        CollectionSort.charAsc => '字符升序',
        CollectionSort.charDesc => '字符降序',
        CollectionSort.weightAsc => '权重升序',
        CollectionSort.weightDesc => '权重降序',
      };

  /// 是否权重排序（仅歌曲类内容页可用）。
  bool get isWeight =>
      this == CollectionSort.weightAsc || this == CollectionSort.weightDesc;

  static CollectionSort parse(String? v) => v == null
      ? CollectionSort.defaultOrder
      : CollectionSort.values.firstWhere((e) => e.name == v,
          orElse: () => CollectionSort.defaultOrder);
}

/// 按字符排序（名称取小写比较；[desc] 反转）。
List<T> sortByChars<T>(List<T> items, String Function(T) nameOf, bool desc) {
  final list = List<T>.of(items);
  list.sort((a, b) {
    final c = nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase());
    return desc ? -c : c;
  });
  return list;
}

/// 非歌曲列表的字符排序入口（权重不适用；默认排序保持原序）。
List<T> sortByCollection<T>(
    List<T> items, CollectionSort sort, String Function(T) nameOf) {
  switch (sort) {
    case CollectionSort.charAsc:
      return sortByChars(items, nameOf, false);
    case CollectionSort.charDesc:
      return sortByChars(items, nameOf, true);
    default:
      return items;
  }
}

/// 歌曲排序下标序列：返回重排后的原下标列表，供平行数组（行数据 + 歌曲）同步重排。
///
/// [factorOf] 逐首查询较慢，内部做一次 memo（同一次排序内每首只查一次）。
List<int> songSortOrder(List<Song> songs, CollectionSort sort,
    {double Function(Song)? factorOf}) {
  final order = List<int>.generate(songs.length, (i) => i);
  if (songs.length < 2 || sort == CollectionSort.defaultOrder) return order;
  int byTitle(int a, int b) =>
      songs[a].title.toLowerCase().compareTo(songs[b].title.toLowerCase());
  if (sort.isWeight && factorOf != null) {
    final cache = <String, double>{};
    double f(Song s) => cache.putIfAbsent(
        '${s.sourceKey}\u0000${s.sourceRef}', () => factorOf(s));
    final desc = sort == CollectionSort.weightDesc;
    order.sort((a, b) {
      final c = f(songs[a]).compareTo(f(songs[b]));
      if (c != 0) return desc ? -c : c;
      return byTitle(a, b);
    });
  } else {
    final desc = sort == CollectionSort.charDesc;
    order.sort((a, b) {
      final c = byTitle(a, b);
      return desc ? -c : c;
    });
  }
  return order;
}

/// 歌曲列表排序入口（字符按标题；权重排序需提供 [factorOf]）。
List<Song> sortSongs(List<Song> songs, CollectionSort sort,
    {double Function(Song)? factorOf}) {
  if (sort == CollectionSort.defaultOrder) return songs;
  final order = songSortOrder(songs, sort, factorOf: factorOf);
  return [for (final i in order) songs[i]];
}
