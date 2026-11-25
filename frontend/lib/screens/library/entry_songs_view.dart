import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../providers/library_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/current_song_focus.dart';
import '../../widgets/draggable_sheet.dart';
import '../../widgets/locate_current_button.dart';
import '../../widgets/row_list.dart';
import '../../widgets/song_list_locator.dart';
import '../../widgets/song_table.dart';
import '../../widgets/song_table_sliver.dart';

/// 专辑/歌手歌曲详情的共用滚动视图：置顶标题 + 可选附加区 + 歌曲表。
///
/// 弹层与整页只差外壳（点歌是否先关窗），列表与播放口径完全一致。
class EntrySongsView extends StatefulWidget {
  final List<Song> songs;
  final ScrollController scrollCtrl;

  /// 置顶标题与计数（[AppSheetTitleBar]）：计数行右侧统一挂「定位当前曲」。
  final String title;
  final Widget? headerLeading;
  final bool showClose;

  /// true=窄屏弹层（点歌先 pop 关窗）；false=宽屏整页（保持页面）。
  final bool fromSheet;

  /// 播放器上下文锚点（专辑 / 歌手）。
  final String contextKey;

  /// 歌曲表之前的附加内容（歌手页的专辑横条 + 详情块）。
  final Widget? leading;

  const EntrySongsView({
    super.key,
    required this.songs,
    required this.scrollCtrl,
    required this.title,
    required this.fromSheet,
    required this.contextKey,
    this.headerLeading,
    this.showClose = true,
    this.leading,
  });

  @override
  State<EntrySongsView> createState() => _EntrySongsViewState();
}

class _EntrySongsViewState extends State<EntrySongsView> {
  /// 歌曲列表 sliver：定位时经它读取标题/附加区已占用的滚动距离。
  final GlobalKey _listKey = GlobalKey();

  /// 本次布局是否带表格表头（列表前多一行 pinned 表头，定位偏移要计入）。
  bool _tableHeader = false;

  /// 「定位当前曲」的统一调度（本页不自动追焦，仅在点按钮时请求）。
  late final CurrentSongFocusController _focus;

  @override
  void initState() {
    super.initState();
    _focus = CurrentSongFocusController(
      scroll: widget.scrollCtrl,
      isActive: () => mounted,
      rowIndexOfCurrent: () =>
          widget.songs.indexWhere(context.read<PlayerProvider>().isCurrent),
      rowTopOf: (row) =>
          SongListLocator.precedingExtentOf(_listKey.currentContext) +
          (_tableHeader ? kSongTableHeaderHeight : 0) +
          row * kRowExtent,
      coveredTopOf: () => AppSheetTitleBar.heightOf(context),
    );
  }

  /// 计数栏「定位当前曲」：目标行置于置顶标题栏下方（统一口径见
  /// [SongListLocator] / [CurrentSongFocusController]）。
  void _locateCurrent() => _focus.request();

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final lib = context.read<LibraryProvider>();
    final nav = context.read<NavigationProvider>();
    return LayoutBuilder(builder: (context, constraints) {
      final table = SongTableLayout.fit(constraints.maxWidth);
      _tableHeader = table != null;
      final leading = widget.leading;
      return NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          _focus.onMetricsAvailable();
          return false;
        },
        child: CustomScrollView(
          controller: widget.scrollCtrl,
          slivers: [
            // 置顶标题行：滚动歌曲时标题/计数常驻顶部（与队列/歌手弹层同构）。
            AppSheetHeader(
              height: AppSheetTitleBar.heightOf(context),
              child: AppSheetTitleBar(
                title: widget.title,
                count: widget.songs.length,
                scrollCtrl: widget.scrollCtrl,
                leading: widget.headerLeading,
                showClose: widget.showClose,
                trailing: Builder(builder: (c) {
                  final has = c.select<PlayerProvider, bool>((p) =>
                      p.current != null && widget.songs.any(p.isCurrent));
                  return LocateCurrentButton(
                    onPressed: has ? _locateCurrent : null,
                  );
                }),
              ),
            ),
            if (leading != null) SliverToBoxAdapter(child: leading),
            SongTableSliverList(
              key: _listKey,
              songs: widget.songs,
              table: table,
              sourceOf: (s) => lib.sourceFor(s.sourceKey),
              onPlay: (i) {
                if (widget.fromSheet) Navigator.of(context).pop();
                player.playQueue(widget.songs,
                    index: i, contextKey: widget.contextKey);
                nav.openPlayer();
              },
            ),
          ],
        ),
      );
    });
  }
}
