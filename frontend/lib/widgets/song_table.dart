import 'package:flutter/material.dart';

import '../utils/collection_sort.dart';
import 'row_list.dart';

/// 宽列表表格模式的最小列表宽度。
///
/// 与旧的「宽行技术信息」阈值同值：达到该宽度后，歌曲行升级为表头 + 对齐列；
/// 低于该宽度（分栏右栏、队列面板、窄屏）继续走普通行。
const double kSongTableMinWidth = 800;

/// 源页递归树启用「每个文件夹块重复表头」的最低列表宽度。
///
/// 块整体缩进最多 4 级 × 18px = 72；再留 [kSongTableMinWidth] 才能保证
/// 最深层的块仍有完整九列。800~871 继续用单一全局表头 + 标题格缩进。
const double kSongTreeBlockHeaderMinWidth = kSongTableMinWidth + 72;

/// 表头高度（含底部分隔线）。
const double kSongTableHeaderHeight = 32;

/// 表格行左右内边距，与 [ListTile] 的 contentPadding 保持一致。
const double kSongTableRowPaddingH = 16;

/// 行首封面宽度与「封面 → 标题」间距；表头用同一组数值对齐。
const double kSongTableCoverWidth = 44;
const double kSongTableCoverGap = 12;

/// 行尾菜单占位宽度（[PopupMenuButton] 的默认点击区）。
const double kSongTableMenuWidth = 48;

/// 文本列的弹性比例。
const int kSongTableTitleFlex = 4;
const int kSongTableArtistFlex = 3;
const int kSongTableAlbumFlex = 3;
const int kSongTableSourceFlex = 2;

/// 技术列的固定宽度。
const double kSongTableFormatWidth = 56;
const double kSongTableBitrateWidth = 76;
const double kSongTableSizeWidth = 64;
const double kSongTableStateWidth = 44;
const double kSongTableDurationWidth = 48;

/// 表头左侧缩进：与行内 contentPadding + 封面 + 间距一致。
const double kSongTableHeaderLeftInset =
    kSongTableRowPaddingH + kSongTableCoverWidth + kSongTableCoverGap;

/// 表头右侧缩进：与行尾菜单 + contentPadding 一致。
///
/// [ListTile] 的尾部占位是 `trailing + horizontalTitleGap`（见其
/// `adjustedTrailingWidth`），所以这里也要把 [kSongTableCoverGap] 计入。
const double kSongTableHeaderRightInset =
    kSongTableRowPaddingH + kSongTableMenuWidth + kSongTableCoverGap;

/// 表格列几何：行与表头**必须**共用同一份构建函数，宽度才不会漂移。
class SongTableLayout {
  const SongTableLayout._();

  /// 当前列表宽度是否适合表格；不够时返回 null（调用方走普通行）。
  static SongTableLayout? fit(double width) =>
      width >= kSongTableMinWidth ? const SongTableLayout._() : null;

  /// 9 个数据列（不含封面、菜单）。
  ///
  /// 列内右间距在这里统一附加：标题/歌手/专辑 12，其余 8，赞踩与时长 0。
  /// [ListTile] 行用 `title` 承载本 Row，表头用 `padding + 本 Row` 对齐。
  Widget buildCells({
    required Widget title,
    required Widget artist,
    required Widget album,
    required Widget source,
    required Widget format,
    required Widget bitrate,
    required Widget size,
    required Widget state,
    required Widget duration,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          flex: kSongTableTitleFlex,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: title,
          ),
        ),
        Expanded(
          flex: kSongTableArtistFlex,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: artist,
          ),
        ),
        Expanded(
          flex: kSongTableAlbumFlex,
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: album,
          ),
        ),
        Expanded(
          flex: kSongTableSourceFlex,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: source,
          ),
        ),
        SizedBox(
          width: kSongTableFormatWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: format,
          ),
        ),
        SizedBox(
          width: kSongTableBitrateWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: bitrate,
          ),
        ),
        SizedBox(
          width: kSongTableSizeWidth,
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: size,
          ),
        ),
        SizedBox(width: kSongTableStateWidth, child: state),
        SizedBox(width: kSongTableDurationWidth, child: duration),
      ],
    );
  }
}

/// 固定表头：标题 / 歌手 / 专辑 / 播放源 / 格式 / 码率 / 大小 / 赞踩 / 时长。
///
/// 普通列表由 [SongTableList] 放在列表上方；sliver 列表放在 pinned
/// [SliverPersistentHeader] 里（见 `SliverSongTable`）。
///
/// 标题/歌手/专辑/时长四个文本列可点击排序，点击循环「升 → 降 → 默认」
/// 与计数栏右侧的 [SortMenuButton] 写同一份 `sort` 状态；专辑/歌手详情页
/// 没有排序入口，[onSort] 为空时表头只读。
class SongTableHeader extends StatelessWidget {
  final SongTableLayout layout;

  /// 当前排序（与计数栏右侧排序菜单共用）。
  final CollectionSort sort;

  /// 点击可排序列表头的回调；为空时表头只读。
  final ValueChanged<CollectionSort>? onSort;

  const SongTableHeader({
    super.key,
    required this.layout,
    this.sort = CollectionSort.defaultOrder,
    this.onSort,
  });

  /// 同一列表头的点击循环：升 → 降 → 默认；换列时从升序开始。
  static CollectionSort nextSort(CollectionSort current, CollectionSort asc) {
    if (current == asc) return asc.flipped;
    if (current == asc.flipped) return CollectionSort.defaultOrder;
    return asc;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget cell(String text,
        {TextAlign align = TextAlign.left, CollectionSort? asc}) {
      final active = asc != null && (sort == asc || sort == asc.flipped);
      final label = active ? '$text ${sort.isDesc ? '↓' : '↑'}' : text;
      final content = Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: align,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              // 与计数头/列表同一套前景色；当前排序列用强调色。
              color: active ? cs.primary : cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      );
      if (asc == null || onSort == null) return content;
      return InkWell(
        onTap: () => onSort!(nextSort(sort, asc)),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: content,
        ),
      );
    }

    return Container(
      height: kSongTableHeaderHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        // 与计数头/歌曲行共用页面底色：不再额外压一条 surfaceContainerLow 色带。
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.only(
        left: kSongTableHeaderLeftInset,
        right: kSongTableHeaderRightInset,
      ),
      child: layout.buildCells(
        title: cell('标题', asc: CollectionSort.charAsc),
        artist: cell('歌手', asc: CollectionSort.artistAsc),
        album: cell('专辑', asc: CollectionSort.albumAsc),
        source: cell('播放源'),
        format: cell('格式'),
        bitrate: cell('码率', align: TextAlign.right),
        size: cell('大小', align: TextAlign.right),
        state: cell('赞踩', align: TextAlign.center),
        duration:
            cell('时长', align: TextAlign.right, asc: CollectionSort.durationAsc),
      ),
    );
  }
}

/// 普通列表外壳：宽度足够时在列表上方加固定表头，否则原样返回列表。
///
/// 行内容（含分组头、文件夹行）仍由调用方提供；外壳只负责表头与滚动容器。
class SongTableList extends StatelessWidget {
  final SongTableLayout? table;
  final int count;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final ScrollController? controller;
  final RefreshCallback? onRefresh;
  final double rowHeight;

  /// 表头排序状态与点击回调（与计数栏排序菜单共用）；为空时表头只读。
  final CollectionSort sort;
  final ValueChanged<CollectionSort>? onSort;

  const SongTableList({
    super.key,
    required this.table,
    required this.count,
    required this.itemBuilder,
    this.controller,
    this.onRefresh,
    this.rowHeight = kRowHeight,
    this.sort = CollectionSort.defaultOrder,
    this.onSort,
  });

  @override
  Widget build(BuildContext context) {
    final list = RowList(
      controller: controller,
      count: count,
      onRefresh: onRefresh,
      rowHeight: rowHeight,
      itemBuilder: itemBuilder,
    );
    if (table == null || count == 0) return list;
    return Column(
      children: [
        SongTableHeader(layout: table!, sort: sort, onSort: onSort),
        Expanded(child: list),
      ],
    );
  }
}
