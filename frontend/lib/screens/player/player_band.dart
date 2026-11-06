import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../providers/player_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/playlists_provider.dart';
import '../../widgets/corner_add_button.dart';
import '../../widgets/playlist_song_picker.dart';
import '../../widgets/song_list.dart';

import 'player_now_playing.dart';
import 'queue_page.dart';

/// 播放器带的「歌单页」（PageView 首页，左邻播放页）。
///
/// - 有绑定歌单（[PlayerProvider.syncPlaylistUuid] 非空且本地存在）：展示该
///   持久化歌单——与内容区歌单详情共用 [SongList]，同源、同行形态、同写回
///   语义（移除/上移/下移会改写真实歌单并联动播放器）；保留「播放 / 从头播放」
///   按钮；**无**左上返回箭头与右上关闭（横向滑动即返回播放页，切换体验与
///   播放页↔歌词页一致）。
/// - 无绑定歌单（全部歌曲/喜欢/专辑/歌手/播放源点播）：兜底展示运行时播放
///   队列（[QueuePage]），其行同样为完整形态。
/// - [embedded] 为真时队列走无 Scaffold/AppBar 的嵌入式（[SongList] 本就是
///   Column，可直接嵌），供横屏「左歌单右播放」分栏的左栏复用。
class BandSongPage extends StatelessWidget {
  final bool embedded;

  /// 重进歌单页的追焦信号（见 [_PlayerScreenState._bandFocusTick]），透传给
  /// 页内列表（[QueuePage]/[SongList]）。
  final ValueListenable<int>? focusTick;
  const BandSongPage({this.embedded = false, this.focusTick});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final uuid = player.syncPlaylistUuid;
    if (uuid == null) {
      return QueuePage(embedded: embedded, focusTick: focusTick);
    }
    final pid =
        context.watch<PlaylistsProvider>().store.index.playlistIdOfUuid(uuid);
    if (pid == null) {
      return QueuePage(embedded: embedded, focusTick: focusTick);
    }
    return CornerFabLayer(
      content: SongList(playlistId: pid, focusTick: focusTick),
      fab: PlaylistAddSongsButton(playlistId: pid),
    );
  }
}

/// 播放页左上角「回到内容页」向下箭头：悬浮覆盖（Positioned 入 Stack），
/// 不参与布局，因此不压缩封面及其他内容的显示空间；点击与下滑返回同路径
/// （置意图位 → Root 驱动悬浮层下降动画）。恒素显，无圆形底/阴影。
/// 静置隐藏时淡出并忽略命中。
class BackToContentButton extends StatelessWidget {
  const BackToContentButton();

  @override
  Widget build(BuildContext context) {
    final hidden = PlayerControlsHidden.isHidden(context);
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        child: IconButton(
          tooltip: '回到内容页',
          iconSize: 26,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: () => context.read<NavigationProvider>().closePlayer(),
        ),
      ),
    );
  }
}

/// 播放器横滑带的边缘翻页箭头（照片浏览器式）：鼠标进入页面左右边缘
/// 约 96px 区域时淡入，移开即淡出。仅鼠标悬停触发，触摸端仍走原生横滑。
class BandEdgeNav extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String? previousTooltip;
  final String? nextTooltip;

  const BandEdgeNav({
    required this.child,
    this.onPrevious,
    this.onNext,
    this.previousTooltip,
    this.nextTooltip,
  });

  @override
  State<BandEdgeNav> createState() => _BandEdgeNavState();
}

class _BandEdgeNavState extends State<BandEdgeNav> {
  static const double _edgeZone = 96;

  bool _showPrevious = false;
  bool _showNext = false;

  void _onHover(PointerHoverEvent event) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final x = event.localPosition.dx;
    final showPrevious = widget.onPrevious != null && x <= _edgeZone;
    final showNext = widget.onNext != null && x >= width - _edgeZone;
    if (showPrevious == _showPrevious && showNext == _showNext) return;
    setState(() {
      _showPrevious = showPrevious;
      _showNext = showNext;
    });
  }

  void _clearHover() {
    if (!_showPrevious && !_showNext) return;
    setState(() {
      _showPrevious = false;
      _showNext = false;
    });
  }

  void _tap(VoidCallback callback) {
    _clearHover();
    callback();
  }

  @override
  Widget build(BuildContext context) {
    final hasPrevious = widget.onPrevious != null;
    final hasNext = widget.onNext != null;
    if (!hasPrevious && !hasNext) return widget.child;
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      onHover: _onHover,
      onExit: (_) => _clearHover(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (hasPrevious)
            Align(
              alignment: Alignment.centerLeft,
              child: EdgeArrow(
                key: const Key('player-edge-previous'),
                visible: _showPrevious,
                tooltip: widget.previousTooltip ?? '上一页',
                icon: Icons.chevron_left_rounded,
                slideFrom: const Offset(-0.25, 0),
                colorScheme: cs,
                onPressed: () => _tap(widget.onPrevious!),
              ),
            ),
          if (hasNext)
            Align(
              alignment: Alignment.centerRight,
              child: EdgeArrow(
                key: const Key('player-edge-next'),
                visible: _showNext,
                tooltip: widget.nextTooltip ?? '下一页',
                icon: Icons.chevron_right_rounded,
                slideFrom: const Offset(0.25, 0),
                colorScheme: cs,
                onPressed: () => _tap(widget.onNext!),
              ),
            ),
        ],
      ),
    );
  }
}

class EdgeArrow extends StatelessWidget {
  final bool visible;
  final String tooltip;
  final IconData icon;
  final Offset slideFrom;
  final ColorScheme colorScheme;
  final VoidCallback onPressed;

  const EdgeArrow({
    super.key,
    required this.visible,
    required this.tooltip,
    required this.icon,
    required this.slideFrom,
    required this.colorScheme,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: ExcludeFocus(
        excluding: !visible,
        child: AnimatedSlide(
          offset: visible ? Offset.zero : slideFrom,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Material(
                color: colorScheme.surface.withValues(alpha: 0.82),
                elevation: 2,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: IconButton(
                  tooltip: tooltip,
                  iconSize: 30,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints.tightFor(width: 44, height: 44),
                  icon: Icon(icon),
                  onPressed: onPressed,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
