/// 判屏口径（窄屏 / 横屏 / 大横屏）+ 内容页分栏几何的统一出口。
///
/// **为什么不用窗口宽直接判**：内容区可用宽度 = 窗口宽 − 侧边栏 260 − 队列面板
/// 360，而这两个槽各有 300ms 伸缩动画。用动画中的实时宽度判定，会在阈值附近
/// 让"分栏/整页"两种形态来回跳。所以由 `AppShell` 用**目标宽度**算好，经
/// [ScreenMetrics] 下发；内容页只认这里，不再各自 `MediaQuery.sizeOf` 拼口径。
///
/// 后续若要收敛成 `ScreenJudge`（窄屏/横屏/大横屏统一判断），改这一个文件即可。
library;

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_theme.dart';

/// 两栏可用的最低内容区宽度（左栏 280 + 右栏 360）。
const double kSplitMinContentWidth = 640;

/// 左栏宽度下限（列表行 44 封面 + 标题 + 副标题的最小可用宽度）。
const double kSplitListMinWidth = 280;

/// 左栏宽度上限（再宽就浪费详情区；列表行不需要更宽）。
const double kSplitListMaxWidth = 360;

/// 左栏占内容区宽度的比例（在大屏上让详情区占大头）。
const double kSplitListWidthRatio = 0.34;

/// 右栏内部换详情的过渡时长：只有一栏在动，比整页 300ms（`kPageMotion`）更短。
const Duration kDetailPaneMotion = Duration(milliseconds: 180);

/// 左栏宽度：内容区的 [kSplitListWidthRatio]，钳在上下限之间。
double splitListWidth(double contentWidth) =>
    (contentWidth * kSplitListWidthRatio)
        .clamp(kSplitListMinWidth, kSplitListMaxWidth)
        .toDouble();

/// 判屏口径。
///
/// - [isWide]：与 `AppShell.isWide` 同口径（宽 ≥900 或任意横屏）；
/// - [isLandscape]：横屏；
/// - [isLargeLandscape]：宽屏且内容区够放两栏 = "大横屏"；
/// - [listPaneWidth]：分栏时左栏宽度。
class ScreenMetrics extends InheritedWidget {
  const ScreenMetrics({
    super.key,
    required this.windowSize,
    required this.contentWidth,
    required super.child,
  });

  /// 窗口尺寸（含状态栏/导航栏占位）。
  final Size windowSize;

  /// 内容区可用宽度（已扣掉侧边栏与队列面板的**目标**宽度）。
  final double contentWidth;

  bool get isWide =>
      windowSize.width >= 900 || windowSize.width > windowSize.height;

  bool get isLandscape => windowSize.width > windowSize.height;

  /// 大横屏：内容区宽度够放「左列表 + 右详情」两栏。
  bool get isLargeLandscape => isWide && contentWidth >= kSplitMinContentWidth;

  /// 是否支持内容页分栏（列表 / 详情）。
  bool get supportsSplit => isLargeLandscape;

  /// 分栏时左栏宽度。
  double get listPaneWidth => splitListWidth(contentWidth);

  /// build 期取口径：**建立依赖**，窗口/侧栏/队列变化时内容页随之重建。
  static ScreenMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScreenMetrics>();

  /// 取判屏口径（含兜底）。
  ///
  /// [depend] = true（默认）建立依赖：谁在 build 里读它，谁就在"内容区宽度
  /// 跨阈值"时重建（分栏形态即时切换）。点击回调里需要读时传 false——回调中
  /// 建立依赖没有意义，还会把一次性依赖挂到行级组件上。
  ///
  /// 未挂 [ScreenMetrics]（单测/嵌入方直接挂页面）时按窗口宽兜底
  /// （视作没有侧栏/队列），与生产路径同一套阈值。
  static ScreenMetrics of(BuildContext context, {bool depend = true}) {
    final inherited = depend
        ? context.dependOnInheritedWidgetOfExactType<ScreenMetrics>()
        : context.getInheritedWidgetOfExactType<ScreenMetrics>();
    if (inherited != null) return inherited;
    final size = MediaQuery.maybeSizeOf(context) ?? Size.zero;
    return ScreenMetrics(
      windowSize: size,
      contentWidth: size.width,
      child: const SizedBox.shrink(),
    );
  }

  @override
  bool updateShouldNotify(ScreenMetrics oldWidget) =>
      oldWidget.windowSize != windowSize ||
      oldWidget.contentWidth != contentWidth;
}

/// 当前分组是否以「左列表 / 右详情」分栏呈现。
///
/// 三个条件同时满足：
/// 1. 大横屏（判屏口径见 [ScreenMetrics]）；
/// 2. 该分组有"列表 → 详情"语义（歌单 / 专辑 / 歌手）；
/// 3. 该分组的展示形式是**列表**——卡片在 280~360 的左栏只能放一列，
///    分栏毫无意义（卡片模式仍走原来的整页叠层）。
///
/// 详情入口（各页的行点击）与返回（详情页返回箭头 / 系统返回）都读它，
/// 用来决定"搜索词是否保留"：分栏时搜索框就是左栏的过滤器，不能被详情打断。
bool splitDetailActive(BuildContext context) {
  // 点击回调也会调它：不建立依赖（依赖由 build 期读 listPaneWidth 建立）。
  if (!ScreenMetrics.of(context, depend: false).supportsSplit) return false;
  final nav = context.read<NavigationProvider>();
  final settings = context.read<DirectSourceManager>().settings;
  return switch (nav.section) {
    NavSection.playlists =>
      settings.viewModePlaylists == CollectionViewMode.list,
    NavSection.albums => settings.viewModeAlbums == CollectionViewMode.list,
    NavSection.artists => settings.viewModeArtists == CollectionViewMode.list,
    NavSection.liked || NavSection.sources || NavSection.songs => false,
  };
}
