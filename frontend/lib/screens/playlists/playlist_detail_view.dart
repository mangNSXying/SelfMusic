import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../layout/screen_metrics.dart';
import '../../providers/navigation_provider.dart';
import '../../widgets/detail_presentation.dart';
import '../../widgets/playlist_song_picker.dart';
import '../../widgets/song_list.dart';

/// 歌单详情（内容区原地子视图 / 大横屏分栏右栏共用）。
///
/// 外壳内嵌统一的 [SongList]（与播放器带「歌单页」同一份列表实现：同源、
/// 同行形态、同写回语义）。头部返回按钮返回内容层；搜索跟随全局搜索框。
class PlaylistDetailView extends StatelessWidget {
  final int playlistId;

  /// 呈现形态：整页（非分栏）保留分组横滑；分栏右栏不包 SectionSwipe 且
  /// 自绘不透明底（见 [DetailPresentationShell]）。
  final DetailPresentation presentation;

  const PlaylistDetailView({
    super.key,
    required this.playlistId,
    this.presentation = DetailPresentation.page,
  });

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T012）：歌单详情的目标 playlistId 由 widget 参数承载（父级路由
    // 变更会重建本组件），build 内不读取 NavigationProvider 字段；全局搜索由内层
    // [SongList] 自行订阅，故此处不订阅导航状态、区段变更零重建。
    final nav = context.read<NavigationProvider>();
    final list = SongList(
      playlistId: playlistId,
      // 返回 = 退回歌单列表：分栏时只清右栏（左栏过滤词保留），整页时沿用原口径。
      onBack: () => nav.exitPlaylist(keepSearch: splitDetailActive(context)),
      globalSearch: true,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        DetailPresentationShell(presentation: presentation, child: list),
        Positioned(
          right: 16,
          bottom: 16,
          child: PlaylistAddSongsButton(playlistId: playlistId),
        ),
      ],
    );
  }
}
