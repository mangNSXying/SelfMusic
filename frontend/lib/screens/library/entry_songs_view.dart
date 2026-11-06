import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../providers/library_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/draggable_sheet.dart';
import '../../widgets/locate_current_button.dart';
import '../../widgets/row_list.dart';
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

  /// 叠在列表之上的浮动操作（歌手页「重新解析」）。
  final Widget? overlay;

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
    this.overlay,
  });

  @override
  State<EntrySongsView> createState() => _EntrySongsViewState();
}

class _EntrySongsViewState extends State<EntrySongsView> {
  /// 歌曲列表 sliver：定位时经它读取标题/附加区已占用的滚动距离。
  final GlobalKey _listKey = GlobalKey();

  /// 本次布局是否带表格表头（列表前多一行 pinned 表头，定位偏移要计入）。
  bool _tableHeader = false;

  /// 计数栏「定位当前曲」：目标行置于置顶标题栏下方 96px（与其它列表同口径）。
  void _locateCurrent() {
    final player = context.read<PlayerProvider>();
    final index = widget.songs.indexWhere(player.isCurrent);
    if (index < 0) return;
    final ctrl = widget.scrollCtrl;
    if (!ctrl.hasClients) return;
    final ro = _listKey.currentContext?.findRenderObject();
    final preceding =
        ro is RenderSliver ? ro.constraints.precedingScrollExtent : 0.0;
    final target = (preceding +
            (_tableHeader ? kSongTableHeaderHeight : 0) +
            index * kRowExtent -
            AppSheetTitleBar.heightOf(context) -
            96)
        .clamp(0.0, ctrl.position.maxScrollExtent);
    ctrl.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final lib = context.read<LibraryProvider>();
    final nav = context.read<NavigationProvider>();
    final content = LayoutBuilder(builder: (context, constraints) {
      final table = SongTableLayout.fit(constraints.maxWidth);
      _tableHeader = table != null;
      final leading = widget.leading;
      return CustomScrollView(
        controller: widget.scrollCtrl,
        slivers: [
          // 置顶标题行：滚动歌曲时标题/计数常驻顶部（与队列/歌手弹层同构）。
          AppSheetHeader(
            height: AppSheetTitleBar.heightOf(context),
            child: AppSheetTitleBar(
              title: widget.title,
              count: widget.songs.length,
              leading: widget.headerLeading,
              showClose: widget.showClose,
              trailing: Builder(builder: (c) {
                final has = c.select<PlayerProvider, bool>(
                    (p) => p.current != null && widget.songs.any(p.isCurrent));
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
      );
    });
    final overlay = widget.overlay;
    if (overlay == null) return content;
    return Stack(children: [content, overlay]);
  }
}
