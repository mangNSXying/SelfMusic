import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../providers/library_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/player_provider.dart';
import '../../widgets/draggable_sheet.dart';
import '../../widgets/song_table.dart';
import '../../widgets/song_table_sliver.dart';

/// 专辑/歌手歌曲详情的共用滚动视图：置顶标题 + 可选附加区 + 歌曲表。
///
/// 弹层与整页只差外壳（点歌是否先关窗），列表与播放口径完全一致。
class EntrySongsView extends StatelessWidget {
  final List<Song> songs;
  final ScrollController scrollCtrl;
  final Widget header;

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
    required this.header,
    required this.fromSheet,
    required this.contextKey,
    this.leading,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final lib = context.read<LibraryProvider>();
    final nav = context.read<NavigationProvider>();
    final content = LayoutBuilder(builder: (context, constraints) {
      final table = SongTableLayout.fit(constraints.maxWidth);
      final leading = this.leading;
      return CustomScrollView(
        controller: scrollCtrl,
        slivers: [
          // 置顶标题行：滚动歌曲时标题/计数常驻顶部（与队列/歌手弹层同构）。
          AppSheetHeader(
            height: AppSheetTitleBar.heightOf(context),
            child: header,
          ),
          if (leading != null) SliverToBoxAdapter(child: leading),
          SongTableSliverList(
            songs: songs,
            table: table,
            sourceOf: (s) => lib.sourceFor(s.sourceKey),
            onPlay: (i) {
              if (fromSheet) Navigator.of(context).pop();
              player.playQueue(songs, index: i, contextKey: contextKey);
              nav.openPlayer();
            },
          ),
        ],
      );
    });
    final overlay = this.overlay;
    if (overlay == null) return content;
    return Stack(children: [content, overlay]);
  }
}
