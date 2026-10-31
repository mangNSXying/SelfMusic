import 'package:flutter/material.dart';

import '../utils/collection_sort.dart';
import 'resizable_table_header.dart';
import 'row_list.dart';
import 'table_columns.dart';

/// 宽列表表格模式的最小列表宽度。
///
/// 与旧的「宽行技术信息」阈值同值：达到该宽度后，歌曲行升级为表头 + 对齐列；
/// 低于该宽度（分栏右栏、队列面板、窄屏）继续走普通行。
const double kSongTableMinWidth = 800;

/// 歌曲表的列宽持久化 key（全站歌曲列表共用一套手调权重）。
const String kSongTableColumnsId = 'song_table';

/// 表头高度（含底部分隔线）。
const double kSongTableHeaderHeight = 32;

/// 表格行左右内边距，与 [ListTile] 的 contentPadding 保持一致。
const double kSongTableRowPaddingH = 16;

/// 行首封面宽度与「封面 → 标题」间距；表头用同一组数值对齐。
const double kSongTableCoverWidth = 44;
const double kSongTableCoverGap = 12;

/// 行尾菜单占位宽度（[PopupMenuButton] 的默认点击区）。
const double kSongTableMenuWidth = 48;

/// 9 列的相对权重（flex），不再写死像素宽度。
///
/// 用户拖拽后写回的是同一套权重（见 [TableColumnSpec]）；默认权重按 800 宽
/// 下的原视觉比例折算，拖拽/缩放都只是改权重。
const List<TableColumnSpec> songTableColumns = [
  TableColumnSpec(
      id: 'title',
      label: '标题',
      defaultWeight: 123,
      minWeight: 40,
      rightPadding: 12,
      sortable: true),
  TableColumnSpec(
      id: 'artist',
      label: '歌手',
      defaultWeight: 92,
      minWeight: 32,
      rightPadding: 12,
      sortable: true),
  TableColumnSpec(
      id: 'album',
      label: '专辑',
      defaultWeight: 92,
      minWeight: 32,
      rightPadding: 12,
      sortable: true),
  TableColumnSpec(
      id: 'source', label: '播放源', defaultWeight: 61, minWeight: 24),
  TableColumnSpec(
      id: 'format', label: '格式', defaultWeight: 64, minWeight: 24),
  TableColumnSpec(
      id: 'bitrate',
      label: '码率',
      defaultWeight: 84,
      minWeight: 24,
      align: TextAlign.right),
  TableColumnSpec(
      id: 'size',
      label: '大小',
      defaultWeight: 72,
      minWeight: 24,
      align: TextAlign.right),
  TableColumnSpec(
      id: 'state',
      label: '赞踩',
      defaultWeight: 44,
      minWeight: 20,
      align: TextAlign.center),
  TableColumnSpec(
      id: 'duration',
      label: '时长',
      defaultWeight: 48,
      minWeight: 24,
      align: TextAlign.right,
      sortable: true),
];

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
///
/// 列宽全部按权重分配；[fit] 只负责判断「是否进入表格形态」，进入后同一个
/// 布局实例可用于任意宽度的行/块。
class SongTableLayout {
  SongTableLayout([List<double>? weights])
      : _layout = TableColumnLayout(
          songTableColumns,
          sanitizeTableWeights(songTableColumns, weights),
        );

  final TableColumnLayout _layout;

  List<double> get weights => _layout.weights;

  /// 当前列表宽度是否适合表格；不够时返回 null（调用方走普通行）。
  static SongTableLayout? fit(double width, {List<double>? weights}) =>
      width >= kSongTableMinWidth ? SongTableLayout(weights) : null;

  /// 9 个数据列（不含封面、菜单）。
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
  }) =>
      _layout.buildCells([
        title,
        artist,
        album,
        source,
        format,
        bitrate,
        size,
        state,
        duration,
      ]);
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

  /// 拖拽中的实时列权重（页面 setState 重绘）。
  final ValueChanged<List<double>>? onWeightsChanged;

  /// 拖拽结束/双击恢复时提交权重（持久化）。
  final ValueChanged<List<double>>? onWeightsCommitted;

  /// 双击分隔线恢复默认列宽。
  final VoidCallback? onResetWeights;

  const SongTableHeader({
    super.key,
    required this.layout,
    this.sort = CollectionSort.defaultOrder,
    this.onSort,
    this.onWeightsChanged,
    this.onWeightsCommitted,
    this.onResetWeights,
  });

  /// 同一列表头的点击循环：升 → 降 → 默认；换列时从升序开始。
  static CollectionSort nextSort(CollectionSort current, CollectionSort asc) {
    if (current == asc) return asc.flipped;
    if (current == asc.flipped) return CollectionSort.defaultOrder;
    return asc;
  }

  /// 排序字段 → 表头列下标（权重/播放统计没有对应列）。
  static int? columnOf(CollectionSort sort) => switch (sort) {
        CollectionSort.charAsc || CollectionSort.charDesc => 0,
        CollectionSort.artistAsc || CollectionSort.artistDesc => 1,
        CollectionSort.albumAsc || CollectionSort.albumDesc => 2,
        CollectionSort.durationAsc || CollectionSort.durationDesc => 8,
        _ => null,
      };

  static CollectionSort? _ascFor(int column) => switch (column) {
        0 => CollectionSort.charAsc,
        1 => CollectionSort.artistAsc,
        2 => CollectionSort.albumAsc,
        8 => CollectionSort.durationAsc,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    return ResizableTableHeader(
      columns: songTableColumns,
      weights: layout.weights,
      sortIndex: columnOf(sort),
      sortDescending: sort.isDesc,
      onSortColumn: onSort == null
          ? null
          : (i) {
              final asc = _ascFor(i);
              if (asc != null) onSort!(nextSort(sort, asc));
            },
      onWeightsChanged: onWeightsChanged,
      onWeightsCommitted: onWeightsCommitted,
      onResetWeights: onResetWeights,
      height: kSongTableHeaderHeight,
      padding: const EdgeInsets.only(
        left: kSongTableHeaderLeftInset,
        right: kSongTableHeaderRightInset,
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

  /// 列宽拖拽回调（见 [SongTableHeader]）。
  final ValueChanged<List<double>>? onWeightsChanged;
  final ValueChanged<List<double>>? onWeightsCommitted;
  final VoidCallback? onResetWeights;

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
    this.onWeightsChanged,
    this.onWeightsCommitted,
    this.onResetWeights,
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
        SongTableHeader(
          layout: table!,
          sort: sort,
          onSort: onSort,
          onWeightsChanged: onWeightsChanged,
          onWeightsCommitted: onWeightsCommitted,
          onResetWeights: onResetWeights,
        ),
        Expanded(child: list),
      ],
    );
  }
}
