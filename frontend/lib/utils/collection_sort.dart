import '../models/song.dart';
import 'play_stats.dart';

/// 内容页排序方式。
///
/// 改进.txt：新增「播放时长 / 播放次数 / 歌曲时长」（歌曲类内容页）与「曲数」
/// （歌单/播放源/专辑/歌手）。播放次数不落库，由累计播放秒数派生
/// （见 [play_stats.playCountOf]），所以排序口径与展示口径永远一致。
enum CollectionSort {
  defaultOrder,
  charAsc,
  charDesc,
  weightAsc,
  weightDesc,
  playTimeAsc,
  playTimeDesc,
  playCountAsc,
  playCountDesc,
  durationAsc,
  durationDesc,
  countAsc,
  countDesc,
}

/// 排序菜单的可用范围（不同内容页能排的字段不同）。
enum SortScope {
  /// 歌曲类内容页（喜欢 / 歌曲 / 歌单详情）：字符、权重、播放时长、播放次数、时长。
  songs,

  /// 集合类内容页（歌单 / 播放源 / 专辑 / 歌手）：字符、曲数。
  collections,
}

extension CollectionSortX on CollectionSort {
  /// 字段名（不含方向；方向由 UI 的箭头表达，单行标签用 [lineLabel]）。
  String get label => switch (this) {
        CollectionSort.defaultOrder => '默认排序',
        CollectionSort.charAsc ||
        CollectionSort.charDesc =>
          '字符',
        CollectionSort.weightAsc ||
        CollectionSort.weightDesc =>
          '权重',
        CollectionSort.playTimeAsc ||
        CollectionSort.playTimeDesc =>
          '播放时长',
        CollectionSort.playCountAsc ||
        CollectionSort.playCountDesc =>
          '播放次数',
        CollectionSort.durationAsc ||
        CollectionSort.durationDesc =>
          '时长',
        CollectionSort.countAsc ||
        CollectionSort.countDesc =>
          '曲数',
      };

  /// 单行标签（自带方向箭头，供弹窗菜单等一行到底的 UI 用）。
  String get lineLabel => '$label ${isDesc ? '↓' : '↑'}';

  /// 降序（曲数多的/时长长的在前）。
  bool get isDesc => switch (this) {
        CollectionSort.charDesc ||
        CollectionSort.weightDesc ||
        CollectionSort.playTimeDesc ||
        CollectionSort.playCountDesc ||
        CollectionSort.durationDesc ||
        CollectionSort.countDesc =>
          true,
        _ => false,
      };

  /// 同一字段切换方向（弹窗/箭头点击用）。
  CollectionSort get flipped => switch (this) {
        CollectionSort.charAsc => CollectionSort.charDesc,
        CollectionSort.charDesc => CollectionSort.charAsc,
        CollectionSort.weightAsc => CollectionSort.weightDesc,
        CollectionSort.weightDesc => CollectionSort.weightAsc,
        CollectionSort.playTimeAsc => CollectionSort.playTimeDesc,
        CollectionSort.playTimeDesc => CollectionSort.playTimeAsc,
        CollectionSort.playCountAsc => CollectionSort.playCountDesc,
        CollectionSort.playCountDesc => CollectionSort.playCountAsc,
        CollectionSort.durationAsc => CollectionSort.durationDesc,
        CollectionSort.durationDesc => CollectionSort.durationAsc,
        CollectionSort.countAsc => CollectionSort.countDesc,
        CollectionSort.countDesc => CollectionSort.countAsc,
        CollectionSort.defaultOrder => CollectionSort.defaultOrder,
      };

  /// 是否权重排序（仅歌曲类内容页可用）。
  bool get isWeight =>
      this == CollectionSort.weightAsc || this == CollectionSort.weightDesc;

  /// 是否播放统计类排序（播放时长/播放次数/时长；仅歌曲类内容页）。
  bool get isPlayStat => switch (this) {
        CollectionSort.playTimeAsc ||
        CollectionSort.playTimeDesc ||
        CollectionSort.playCountAsc ||
        CollectionSort.playCountDesc ||
        CollectionSort.durationAsc ||
        CollectionSort.durationDesc =>
          true,
        _ => false,
      };

  /// 是否曲数排序（仅集合类内容页）。
  bool get isCount =>
      this == CollectionSort.countAsc || this == CollectionSort.countDesc;

  /// 本排序在 [scope] 页面是否可用。
  bool availableIn(SortScope scope) => switch (scope) {
        SortScope.songs => !isCount,
        SortScope.collections => !isWeight && !isPlayStat,
      };

  static CollectionSort parse(String? v) => v == null
      ? CollectionSort.defaultOrder
      : CollectionSort.values.firstWhere((e) => e.name == v,
          orElse: () => CollectionSort.defaultOrder);
}

/// 数值比较：null（未知）恒排最后——升序时「没时长」的歌不该霸占榜首，
/// 降序时同理沉底。
int _cmpNum(num? a, num? b, bool desc) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return desc ? b.compareTo(a) : a.compareTo(b);
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

/// 非歌曲列表的排序入口（歌单/播放源/专辑/歌手：字符或曲数；默认排序保持原序）。
///
/// [countOf] 提供曲数（界面显示的曲数口径）；未提供时曲数排序退化为原序。
List<T> sortByCollection<T>(List<T> items, CollectionSort sort,
    String Function(T) nameOf, {int Function(T)? countOf}) {
  switch (sort) {
    case CollectionSort.charAsc:
      return sortByChars(items, nameOf, false);
    case CollectionSort.charDesc:
      return sortByChars(items, nameOf, true);
    case CollectionSort.countAsc:
    case CollectionSort.countDesc:
      if (countOf == null) return items;
      final desc = sort.isDesc;
      final list = List<T>.of(items);
      list.sort((a, b) {
        final c = desc
            ? countOf(b).compareTo(countOf(a))
            : countOf(a).compareTo(countOf(b));
        if (c != 0) return c;
        return nameOf(a).toLowerCase().compareTo(nameOf(b).toLowerCase());
      });
      return list;
    default:
      return items;
  }
}

/// 歌曲排序下标序列：返回重排后的原下标列表，供平行数组（行数据 + 歌曲）同步重排。
///
/// [factorOf]（权重库读 SQLite）与 [playSecOf]（累计播放秒数）都只查一次：
/// 排序前预取成长度与歌曲数相同的数组，比较阶段零查询。
List<int> songSortOrder(List<Song> songs, CollectionSort sort,
    {double Function(Song)? factorOf, int Function(Song)? playSecOf}) {
  final order = List<int>.generate(songs.length, (i) => i);
  if (songs.length < 2 || sort == CollectionSort.defaultOrder) return order;
  int byTitle(int a, int b) =>
      songs[a].title.toLowerCase().compareTo(songs[b].title.toLowerCase());

  // 预取排序键：null 表示该排序缺数据源，退化为标题序。
  List<num?>? keys;
  switch (sort) {
    case CollectionSort.weightAsc:
    case CollectionSort.weightDesc:
      if (factorOf != null) {
        keys = List<double?>.generate(songs.length, (i) => factorOf(songs[i]));
      }
    case CollectionSort.playTimeAsc:
    case CollectionSort.playTimeDesc:
      if (playSecOf != null) {
        keys = List<int?>.generate(songs.length, (i) => playSecOf(songs[i]));
      }
    case CollectionSort.playCountAsc:
    case CollectionSort.playCountDesc:
      if (playSecOf != null) {
        keys = List<double?>.generate(
          songs.length,
          (i) => playCountOf(playSecOf(songs[i]), songs[i].duration),
        );
      }
    case CollectionSort.durationAsc:
    case CollectionSort.durationDesc:
      keys = List<int?>.generate(songs.length, (i) => songs[i].duration);
    default:
      break;
  }
  final desc = sort.isDesc;
  order.sort((a, b) {
    if (sort == CollectionSort.charAsc || sort == CollectionSort.charDesc) {
      final c = byTitle(a, b);
      return desc ? -c : c;
    }
    if (keys == null) {
      // 缺数据源（如未注入权重库）时保持稳定的标题序，不做无意义抖动。
      return byTitle(a, b);
    }
    final c = _cmpNum(keys[a], keys[b], desc);
    return c != 0 ? c : byTitle(a, b);
  });
  return order;
}

/// 歌曲列表排序入口（字符按标题；权重/播放统计排序需提供对应读取回调）。
List<Song> sortSongs(List<Song> songs, CollectionSort sort,
        {double Function(Song)? factorOf, int Function(Song)? playSecOf}) =>
    sort == CollectionSort.defaultOrder
        ? songs
        : [
            for (final i in songSortOrder(songs, sort,
                factorOf: factorOf, playSecOf: playSecOf))
              songs[i]
          ];
