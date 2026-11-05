import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../data/local/app_settings.dart';
import '../../layout/screen_metrics.dart';
import '../../theme/app_theme.dart';
import '../../utils/perf_log.dart';
import '../../utils/motion.dart';
import '../../widgets/content_stack.dart';
import '../../widgets/page_transition.dart';
import '../about_screen.dart';
import '../library_info_screen.dart';
import '../settings/settings_screen.dart';
import '../source_browse_view.dart';
import '../playlists_view.dart';
import 'detail_pages.dart';
import 'section_pager.dart';

/// 内容区：常驻六分组基座 + 一条内容栈（设置/歌单/源内/详情/歌曲信息）。
class AppContent extends StatelessWidget {
  const AppContent({super.key});

  /// 冷启动首帧定位：只记第一次 build（后续路由切换不再刷屏）。
  static bool _bootLogged = false;

  @override
  Widget build(BuildContext context) {
    if (!_bootLogged) {
      _bootLogged = true;
      perfLog('boot.firstBuild AppContent');
    }
    // 订阅收窄：只关注分组 + 内容栈版本；搜索/队列/播放页等通知不牵连重建。
    final nav = context.read<NavigationProvider>();
    context.select<NavigationProvider, (NavSection, int)>(
        (n) => (n.section, n.contentRevision));
    // 判屏口径（只在此建立依赖）：窗口宽、侧栏/队列槽变化时内容页跟着重建。
    ScreenMetrics.maybeOf(context);
    final transition =
        context.watch<DirectSourceManager>().settings.playerTransition;
    final split = splitDetailActive(context);
    final routes = nav.contentRoutes;
    // 分栏时歌单/源内/专辑/歌手由右栏渲染；整页层只留设置/歌曲信息。
    final visible = split
        ? [
            for (final route in routes)
              if (!_isInlineRoute(route)) route,
          ]
        : routes;
    return ContentStack(
      base: const SectionPager(),
      routes: visible,
      builder: contentPageOf,
      transition: transition,
      // 分组变化或分栏/整页切换时内容层直接消失，不残留到新形态上。
      baseKey: '${nav.section.name}/${split ? 'split' : 'full'}',
    );
  }
}

bool _isInlineRoute(ContentRoute route) =>
    route is PlaylistRoute ||
    route is SourceBrowseRoute ||
    route is AlbumDetailRoute ||
    route is ArtistDetailRoute;

Widget contentPageOf(BuildContext context, ContentRoute route) {
  return switch (route) {
    SettingsRoute(:final item) => _SettingsContentHost(item: item),
    LibraryInfoRoute(:final page) => LibraryInfoContent(page: page),
    AboutRoute() => const AboutScreen(),
    PlaylistRoute(:final id) => PlaylistDetailView(playlistId: id),
    SourceBrowseRoute(:final sourceKey, :final dir) =>
      SourceBrowseView(sourceKey: sourceKey, dirOverride: dir),
    AlbumDetailRoute() => detailPageOf(context, route),
    ArtistDetailRoute() => detailPageOf(context, route),
  };
}

class _SettingsContentHost extends StatelessWidget {
  const _SettingsContentHost({required this.item});

  final SettingsItem item;

  @override
  Widget build(BuildContext context) {
    final transition =
        context.watch<DirectSourceManager>().settings.playerTransition;
    final child = KeyedSubtree(
      key: ValueKey(item),
      child: SettingsScreen(item: item),
    );
    if (transition == PlayerTransition.none) return child;
    return AnimatedSwitcher(
      duration: kPageMotion,
      switchInCurve: kPageMotionCurve,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [
          for (final page in previous) IgnorePointer(child: page),
          if (current != null) current,
        ],
      ),
      transitionBuilder: (child, anim) => pageTransition(
        transition,
        child,
        anim,
        slideOffset: const Offset(1, 0),
        backdrop: Theme.of(context).scaffoldBackgroundColor,
      ),
      child: child,
    );
  }
}
