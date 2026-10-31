import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/table_column_weights.dart';
import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import 'row_list.dart';
import 'song_row_view.dart';
import 'song_table.dart';
import 'song_tile.dart';
import 'table_columns.dart';

/// sliver 列表外壳：宽度足够时在歌曲行上方加 pinned 表头。
///
/// 用于「页头与列表必须共用同一个 CustomScrollView」的详情页（专辑 / 歌手）。
/// 行内容仍由调用方提供，外壳只负责表头与列表结构。
class SliverSongTable extends StatelessWidget {
  final SongTableLayout? table;
  final int count;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double rowHeight;

  /// 列宽拖拽回调（与歌曲表共用全局权重）；为空时表头只读。
  final ValueChanged<List<double>>? onWeightsChanged;
  final ValueChanged<List<double>>? onWeightsCommitted;
  final VoidCallback? onResetWeights;

  const SliverSongTable({
    super.key,
    required this.table,
    required this.count,
    required this.itemBuilder,
    this.rowHeight = kRowHeight,
    this.onWeightsChanged,
    this.onWeightsCommitted,
    this.onResetWeights,
  });

  @override
  Widget build(BuildContext context) {
    final rows = SliverRowList(
      count: count,
      rowHeight: rowHeight,
      itemBuilder: itemBuilder,
    );
    if (table == null || count == 0) return rows;
    return SliverMainAxisGroup(
      slivers: [
        SliverPersistentHeader(
          pinned: true,
          delegate: _SongTableHeaderDelegate(
            table!,
            onWeightsChanged: onWeightsChanged,
            onWeightsCommitted: onWeightsCommitted,
            onResetWeights: onResetWeights,
          ),
        ),
        rows,
      ],
    );
  }
}

class _SongTableHeaderDelegate extends SliverPersistentHeaderDelegate {
  final SongTableLayout table;
  final ValueChanged<List<double>>? onWeightsChanged;
  final ValueChanged<List<double>>? onWeightsCommitted;
  final VoidCallback? onResetWeights;

  const _SongTableHeaderDelegate(
    this.table, {
    this.onWeightsChanged,
    this.onWeightsCommitted,
    this.onResetWeights,
  });

  @override
  double get minExtent => kSongTableHeaderHeight;

  @override
  double get maxExtent => kSongTableHeaderHeight;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      SizedBox(
        height: kSongTableHeaderHeight,
        child: SongTableHeader(
          layout: table,
          onWeightsChanged: onWeightsChanged,
          onWeightsCommitted: onWeightsCommitted,
          onResetWeights: onResetWeights,
        ),
      );

  @override
  bool shouldRebuild(covariant _SongTableHeaderDelegate oldDelegate) =>
      oldDelegate.table != table;
}

/// 专辑 / 歌手详情页的纯歌曲列表：内置行级视图缓存与共享表格行。
///
/// 传入 [table] 时走表格列；为 null 时保持普通单行。页头滚动轴由外层
/// `CustomScrollView` 统一提供，本组件只产出 sliver。
class SongTableSliverList extends StatefulWidget {
  final List<Song> songs;

  /// 表格布局；为 null 表示宽度不足，保持普通行。
  final SongTableLayout? table;

  final MusicSource? Function(Song song) sourceOf;
  final void Function(int index) onPlay;

  const SongTableSliverList({
    super.key,
    required this.songs,
    required this.table,
    required this.sourceOf,
    required this.onPlay,
  });

  @override
  State<SongTableSliverList> createState() => _SongTableSliverListState();
}

class _SongTableSliverListState extends State<SongTableSliverList> {
  final SongRowCache _rows = SongRowCache();
  List<double> _weights = defaultTableWeights(songTableColumns);
  bool _weightsLoaded = false;

  @override
  void initState() {
    super.initState();
    TableColumnWeightsRevision.instance.addListener(_reloadWeights);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_weightsLoaded) {
      _weightsLoaded = true;
      final stored = context
          .read<DirectSourceManager>()
          .settings
          .tableColumnWeights(kSongTableColumnsId);
      _weights = sanitizeTableWeights(songTableColumns, stored);
    }
  }

  @override
  void dispose() {
    TableColumnWeightsRevision.instance.removeListener(_reloadWeights);
    super.dispose();
  }

  void _reloadWeights() {
    if (!mounted || !_weightsLoaded) return;
    final stored = context
        .read<DirectSourceManager>()
        .settings
        .tableColumnWeights(kSongTableColumnsId);
    final next = sanitizeTableWeights(songTableColumns, stored);
    if (listEquals(next, _weights)) return;
    setState(() => _weights = next);
  }

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final player = context.watch<PlayerProvider>();
    final current = player.current;
    final currentKey = current == null ? null : songRowKey(current);
    final layout = widget.table == null ? null : SongTableLayout(_weights);
    _rows.begin(
      (
        identityHashCode(widget.songs),
        direct.favoriteVersion,
        direct.metaVersion,
        direct.settingsVersion,
        direct.sourcesRevision,
        direct.settings.songTitleFormat,
        widget.table != null,
        currentKey,
      ),
      widget.songs.length,
      onWarm: () => direct.weight.warmMetaOf(widget.songs),
    );
    return SliverSongTable(
      table: layout,
      count: widget.songs.length,
      onWeightsChanged: (w) => setState(() => _weights = w),
      onWeightsCommitted: (w) {
        _weights = w;
        direct.settings.setTableColumnWeights(kSongTableColumnsId, w);
      },
      onResetWeights: () {
        direct.settings.setTableColumnWeights(kSongTableColumnsId, null);
        setState(() => _weights = defaultTableWeights(songTableColumns));
      },
      itemBuilder: (context, index) {
        final song = widget.songs[index];
        final src = widget.sourceOf(song);
        final playing = player.isCurrent(song);
        return SongTile(
          song: song,
          source: src,
          row: _rows.rowAt(index, () {
            if (!direct.weight.hasMetaCached(song)) {
              direct.weight.ensureMetaOf([song]);
            }
            final meta = direct.weight.metaOf(song);
            return SongRowView.of(
              song: song,
              titleFormat: direct.settings.songTitleFormat,
              sourceName: src?.name ?? direct.sourceByKey(song.sourceKey)?.name,
              playing: playing,
              favorite: meta.favorite,
              disliked: meta.frozen,
              isFirst: index == 0,
              isLast: index == widget.songs.length - 1,
              table: widget.table != null,
            );
          }),
          table: layout,
          playing: playing,
          onPlay: () => widget.onPlay(index),
        );
      },
    );
  }
}
