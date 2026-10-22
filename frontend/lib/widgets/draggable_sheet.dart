import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../utils/motion.dart';
import 'count_header.dart';
import 'row_list.dart';

/// 统一拖拽式窗口的尺寸配置（`DraggableScrollableSheet` 同名参数透传）。
class AppSheetConfig {
  final double initialChildSize;
  final double minChildSize;
  final double maxChildSize;
  final bool snap;
  final List<double>? snapSizes;

  const AppSheetConfig({
    this.initialChildSize = 0.6,
    this.minChildSize = 0.25,
    this.maxChildSize = 1.0,
    this.snap = false,
    this.snapSizes,
  });
}

/// 滑动启动时「手指行程 → 悬浮层展示进度」的换算因子：上移 `0.6` 屏高度
/// 即拉满（与窗口静息高度 [AppSheetConfig.initialChildSize] 对齐）。
const double kAppSheetSwipeTravelFactor = 0.6;

/// 统一拖拽式窗口（点击启动）：底部模态路由 + `DraggableScrollableSheet`。
///
/// 适用于不需要「触发手指跟手」的入口（歌手/专辑歌曲弹层）。需要迷你条上滑
/// 跟手的队列窗口走 [AppSheetLauncher] 的悬浮层——路由 `push` 会触发
/// `NavigatorState._cancelActivePointers()`，把触发跟手的那根手指一并取消，
/// 跟手无法继续（见 [AppSheetLauncher] 注释）。
///
/// 窗口语义（与队列悬浮层一致）：头部与列表共用同一个 scroll controller——
/// 列表处按下滚动列表（列表滚到顶部后继续下拖才收起窗口）；头部
/// （[AppSheetTitleBar]）整块可抓，按下即直接改窗口高度（不先滚列表）。
/// 顶部安全区由路由 `useSafeArea` 消费，内容**不要**再套
/// `SafeArea(top: true)`（否则多出一整块状态栏空白）。关闭通道经
/// [AppSheetScope] 注入（标题栏关闭按钮见 [AppSheetTitleBar]）。
Future<T?> showAppDraggableSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, ScrollController scrollCtrl)
      builder,
  AppSheetConfig config = const AppSheetConfig(),
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (c) => _AppSheetRouteBody(builder: builder, config: config),
  );
}

/// 路由版窗口主体：持有窗口尺寸控制器（标题栏拖拽调高，见 [AppSheetTitleBar]）。
/// 控制器生命周期 = 路由子树（含退出动画）：随主体 dispose 释放，晚于
/// `DraggableScrollableSheet` 卸载时的 detach（子树先卸载）。
class _AppSheetRouteBody extends StatefulWidget {
  const _AppSheetRouteBody({required this.builder, required this.config});

  final Widget Function(BuildContext context, ScrollController scrollCtrl)
      builder;
  final AppSheetConfig config;

  @override
  State<_AppSheetRouteBody> createState() => _AppSheetRouteBodyState();
}

class _AppSheetRouteBodyState extends State<_AppSheetRouteBody> {
  final DraggableScrollableController _sheet = DraggableScrollableController();

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.config;
    return DraggableScrollableSheet(
      controller: _sheet,
      expand: false,
      initialChildSize: config.initialChildSize,
      minChildSize: config.minChildSize,
      maxChildSize: config.maxChildSize,
      snap: config.snap,
      snapSizes: config.snapSizes,
      // 路由版关闭通道：pop 本弹层路由（悬浮层版由 [AppSheetLauncher] 注入）。
      builder: (c, scrollCtrl) => AppSheetScope(
        close: () => Navigator.of(c).pop(),
        controller: _sheet,
        child: widget.builder(c, scrollCtrl),
      ),
    );
  }
}

/// 供统一窗口内容调用「关闭窗口」（[closeOf]）与「标题栏拖拽调高」
/// （[controllerOf]）的祖先（路由/悬浮层通用）。
///
/// 路由版（[showAppDraggableSheet]）注入的关闭走 `Navigator.pop`；悬浮层
/// （[AppSheetLauncher]）注入其收起回调——悬浮层没有路由可 pop，误 pop 会
/// 关掉底层页面。统一标题栏的关闭按钮经 [AppSheetScope.closeOf] 工作。
class AppSheetScope extends InheritedWidget {
  const AppSheetScope({
    super.key,
    required this.close,
    this.controller,
    required super.child,
  });

  final VoidCallback close;

  /// 窗口尺寸控制器（`DraggableScrollableSheet` 挂的那个）；未挂时为 null，
  /// 标题栏退化为普通内容（拖动交回窗口自身的滚动语义）。
  final DraggableScrollableController? controller;

  /// 关闭当前统一窗口（无匹配 scope 时静默忽略）。
  static void closeOf(BuildContext context) {
    context.getInheritedWidgetOfExactType<AppSheetScope>()?.close();
  }

  /// 取窗口尺寸控制器（无匹配 scope / 未挂时返回 null）。
  static DraggableScrollableController? controllerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppSheetScope>()?.controller;

  @override
  bool updateShouldNotify(AppSheetScope oldWidget) =>
      close != oldWidget.close || controller != oldWidget.controller;
}

/// 统一窗口的置顶标题栏（`SliverPersistentHeader` 固定）。
///
/// 仍位于窗口同一个 scrollable 内（经 [showAppDraggableSheet] / 悬浮层下发的
/// scroll controller），因此「滚动时标题常驻顶部」与「任一处按下可拖拽窗口」
/// 兼得。`height` 为固定高度：`SliverPersistentHeader` 无内在高度，需由调用方
/// 按内容给出（内容超出会溢出）。
class AppSheetHeader extends StatelessWidget {
  const AppSheetHeader({super.key, required this.height, required this.child});

  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _AppSheetHeaderDelegate(
        height: height,
        color: Theme.of(context).colorScheme.surface,
        child: child,
      ),
    );
  }
}

class _AppSheetHeaderDelegate extends SliverPersistentHeaderDelegate {
  _AppSheetHeaderDelegate({
    required this.height,
    required this.color,
    required this.child,
  });

  final double height;
  final Color color;
  final Widget child;

  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    // 不透明底色（与窗口同色）：列表滚到标题栏下方时不会透出。
    return Material(color: color, child: child);
  }

  @override
  bool shouldRebuild(covariant _AppSheetHeaderDelegate old) =>
      old.height != height || old.color != color || old.child != child;
}

/// 统一窗口的置顶标题栏：拖拽把手 + 标题行（关闭按钮）+ 歌曲数（[CountHeader]）
/// + 分隔线。
///
/// 与 [AppSheetHeader] 搭配：高度由 [heightOf] 按主题字号现算（对字体缩放稳健），
/// 长标题单行省略号，钉死后不溢出/不抖动。专辑 / 歌手 / 队列三个弹层共用，
/// 保证头部同构；关闭按钮经 [AppSheetScope.closeOf] 收起窗口（路由/悬浮层由
/// 各自启动器注入 scope）。
///
/// 宽屏详情页复用同一标题栏：无 [AppSheetScope]（无尺寸控制器）时自动不画
/// 拖拽把手、[heightOf] 同步少去把手占位；用 [leading] 换成返回箭头并关掉
/// [showClose] 即可，其余（标题/计数/分隔线）与弹层一致。
class AppSheetTitleBar extends StatelessWidget {
  const AppSheetTitleBar({
    super.key,
    required this.title,
    required this.count,
    this.unit = '首',
    this.leading,
    this.showClose = true,
  });

  final String title;
  final int count;
  final String unit;

  /// 标题行最左侧的附加控件（宽屏详情页放返回箭头；弹层为 null）。
  final Widget? leading;

  /// 是否显示右侧关闭按钮（宽屏详情页用返回箭头，置 false）。
  final bool showClose;

  /// 标题栏总高：8+4（拖拽把手，仅弹层）+ 8 上边距 + 标题行（关闭按钮不小于
  /// 最小点按尺寸）+ 4 下边距 + 计数头 + 分隔线。
  static double heightOf(BuildContext context) =>
      (AppSheetScope.controllerOf(context) == null ? 0 : 8 + 4) +
      8 +
      math.max(kMinInteractiveDimension, _lineHeight(context)) +
      4 +
      kListHeaderHeight +
      kRowSeparatorHeight;

  static double _lineHeight(BuildContext context) {
    final text = TextPainter(
      text: TextSpan(text: '汉', style: _titleStyle(context)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return text.height;
  }

  static TextStyle _titleStyle(BuildContext context) =>
      Theme.of(context)
          .textTheme
          .titleLarge
          ?.copyWith(fontWeight: FontWeight.bold) ??
      const TextStyle(fontWeight: FontWeight.bold);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 尺寸控制器（经 [AppSheetScope] 下发）：头部当抓手拖动时直接改窗口高度。
    // 无控制器 = 整页形态（宽屏详情页）：不画把手，也少去把手占位。
    final controller = AppSheetScope.controllerOf(context);
    // 用 [heightOf] 固定总高：钉住的 head 声明高度须与子树实际高度严格一致，
    // 否则 SliverPersistentHeader 会因 layoutExtent/paintExtent 不等而断言。
    return SizedBox(
      height: heightOf(context),
      child: GestureDetector(
        // 头部整块可抓（把手/标题/计数行）：按住拖动直接改窗口高度。框架的
        // DraggableScrollableSheet 只在列表滚到顶部（pixels == 0）时才把拖拽
        // 用于改高度，否则一律滚列表——队列窗口打开即定位当前曲、列表常不在
        // 顶部，拖头部会「纹丝不动」（回归 queue_sheet_gesture_test）。
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: controller == null
            ? null
            : (DragUpdateDetails d) => _dragSize(controller, d.delta.dy),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽把手（视觉提示；整头都是拖拽/滚动入口）。
            if (controller != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  key: const ValueKey('app_sheet_handle'),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            // 标题行：单行省略 + 关闭按钮（整页形态：返回箭头，无关闭按钮）。
            Padding(
              padding: EdgeInsets.fromLTRB(leading == null ? 16 : 4, 8, 4, 4),
              child: Row(
                children: [
                  if (leading != null) leading!,
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _titleStyle(context),
                    ),
                  ),
                  if (showClose)
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: '关闭',
                      onPressed: () => AppSheetScope.closeOf(context),
                    ),
                ],
              ),
            ),
            CountHeader(count: count, unit: unit),
            const Divider(height: kRowSeparatorHeight),
          ],
        ),
      ),
    );
  }

  /// 头部拖动一帧：窗口高度随手指走。像素换算经控制器（自带尺寸上下限钳制；
  /// 结果再按 [0,1] 钳制以满足 [DraggableScrollableController.jumpTo] 断言）。
  static void _dragSize(DraggableScrollableController controller, double dy) {
    if (!controller.isAttached) return;
    final next = controller.pixelsToSize(controller.pixels - dy);
    controller.jumpTo(next.clamp(0.0, 1.0));
  }
}

/// 统一拖拽式窗口（跟手启动）的宿主启动器（Root 持有，全 App 单例，经 Provider 下发）。
///
/// 悬浮层基于 [OverlayPortal]、宿主为 [AppSheetHost]（挂在 [AppShell] 首页路由
/// 内），既非 modal 路由也非裸 `OverlayEntry`：
/// - 不 push 路由：`Navigator.push` 会同步取消进行中的手势指针，迷你条上滑
///   跟手第一帧即被打断（历史回归）。悬浮层由 [swipeTo] 逐帧写入展示进度
///   （0=隐藏 → 1=展开），点击启动则播放展开动画。
/// - 不用裸 `OverlayEntry`：每次导航历史变更 `OverlayState.rearrange` 会把非
///   路由悬浮层排到全部路由条目之上，窗口内三点菜单（导航器路由）反被窗口
///   盖住（历史 bug，回归测试 queue_sheet_menu_test.dart）。[OverlayPortal] 的
///   悬浮层固定画在宿主 OverlayEntry（首页路由）之上、随后 push 的路由之下，
///   菜单/对话框正常浮在窗口上，且不 push 路由，跟手不受影响。
class AppSheetLauncher {
  AppSheetLauncher({required TickerProvider vsync})
      : _progress = AnimationController(
          vsync: vsync,
          duration: kPageMotion,
        );

  final AnimationController _progress;

  /// 悬浮层显示控制（[AppSheetHost] 挂到 `OverlayPortal` 上）。
  final OverlayPortalController _portal =
      OverlayPortalController(debugLabel: 'AppSheetLauncher');

  /// 本次窗口内容与尺寸配置；显示期间 [AppSheetHost] 重建悬浮层时读取。
  Widget Function(BuildContext context, ScrollController scrollCtrl)? _builder;
  AppSheetConfig _config = const AppSheetConfig();

  VoidCallback? _onClosed;

  /// 窗口悬浮层是否已展示（含展开动画 / 跟手进行中）。
  bool get isShowing => _portal.isShowing;

  /// 跟手进行中的展示进度（0=隐藏 → 1=展开），供宿主松手吸附判定。
  double get swipeValue => _progress.value;

  /// 挂上窗口内容并显示悬浮层（宿主未挂载时先记录意图，随宿主挂载补显）。
  void _show({
    required Widget Function(BuildContext context, ScrollController scrollCtrl)
        builder,
    required AppSheetConfig config,
  }) {
    _builder = builder;
    _config = config;
    _portal.show();
  }

  /// 悬浮层内容构建（作为 [AppSheetHost] 的 `overlayChildBuilder`）。
  Widget _buildOverlay(BuildContext context) {
    final builder = _builder;
    if (builder == null) return const SizedBox.shrink();
    return _SheetOverlay(launcher: this, builder: builder, config: _config);
  }

  /// 点击启动：显示悬浮层并播放展开动画。窗口已在展示则忽略。
  Future<T?> openTap<T>({
    required Widget Function(BuildContext context, ScrollController scrollCtrl)
        builder,
    AppSheetConfig config = const AppSheetConfig(),
    VoidCallback? onOpen,
    VoidCallback? onClose,
  }) {
    if (isShowing) return Future.value(null);
    _onClosed = onClose;
    _progress.value = 0;
    _show(builder: builder, config: config);
    onOpen?.call();
    _progress.animateTo(1.0, curve: kPageMotionCurve);
    return Future.value(null);
  }

  /// 滑动启动①：显示进度 0 的悬浮层，交由宿主手指驱动。
  /// 返回 false 表示窗口已在展示，宿主应忽略本次手势。
  bool beginSwipe<T>({
    required Widget Function(BuildContext context, ScrollController scrollCtrl)
        builder,
    AppSheetConfig config = const AppSheetConfig(),
    VoidCallback? onOpen,
    VoidCallback? onClose,
  }) {
    if (isShowing) return false;
    _onClosed = onClose;
    _progress.value = 0;
    _show(builder: builder, config: config);
    onOpen?.call();
    return true;
  }

  /// 滑动启动②：逐帧写入展示进度（0=隐藏 → 1=展开）。
  void swipeTo(double shown) {
    if (!isShowing) return;
    _progress.value = shown.clamp(0.0, 1.0);
  }

  /// 滑动启动③：松手定稿。`open` 为真播完剩余行程；为假倒播收起。
  void endSwipe({required bool open}) {
    if (!isShowing) return;
    if (open) {
      _progress.animateTo(1.0, curve: kPageMotionCurve);
    } else {
      close();
    }
  }

  /// 收起并隐藏悬浮层（遮罩 / 关闭按钮 / 返回意图共用，幂等）。
  void close() {
    if (!isShowing) return;
    if (_progress.value <= 0.001) {
      _remove();
      return;
    }
    _progress
        .animateTo(0.0, curve: kPageMotionCurve)
        .whenComplete(_remove);
  }

  void _remove() {
    // 宿主已卸载时控制器处于未挂载态，hide() 反而会断言（仅在展示时收起）。
    if (_portal.isShowing) _portal.hide();
    _builder = null;
    final cb = _onClosed;
    _onClosed = null;
    cb?.call();
  }

  void dispose() {
    if (_portal.isShowing) _portal.hide();
    _builder = null;
    _progress.dispose();
  }
}

/// [AppSheetLauncher] 的悬浮层宿主：挂在 [AppShell]（首页路由）内、Scaffold 之外。
///
/// `OverlayPortal` 需要 [Overlay] 祖先（根导航器自带）。宿主放在 Scaffold 之外，
/// 让悬浮层继承到未被 `MediaQuery.removePadding` 裁剪的真实安全区（窗口顶部
/// 让开状态栏，历史 bug）。悬浮层只画在宿主所在 OverlayEntry（首页路由条目）
/// 之上、随后 push 的路由（菜单/对话框）之下（详见 [AppSheetLauncher]）。
///
/// 未接入 Provider 的调用方（AppShell 裸渲染的旧测试）降级为占位空盒。
class AppSheetHost extends StatelessWidget {
  const AppSheetHost({super.key});

  @override
  Widget build(BuildContext context) {
    // 可空查找：没有 AppSheetLauncher 时返回 null（而非抛异常）。
    final launcher = context.read<AppSheetLauncher?>();
    if (launcher == null) return const SizedBox.shrink();
    return OverlayPortal(
      controller: launcher._portal,
      overlayChildBuilder: launcher._buildOverlay,
      child: const SizedBox.shrink(),
    );
  }
}

/// 悬浮层内容：遮罩 + 底部统一窗口（`DraggableScrollableSheet`），整体按
/// [_progress] 位移。顶部让开状态栏（顶部区域透明，触摸穿透到遮罩）。
/// 持有窗口尺寸控制器（标题栏拖拽调高，见 [AppSheetTitleBar]）：生命周期 =
/// 悬浮层子树，随移除卸载而释放（晚于 `DraggableScrollableSheet` 的 detach）。
class _SheetOverlay extends StatefulWidget {
  const _SheetOverlay({
    required this.launcher,
    required this.builder,
    required this.config,
  });

  final AppSheetLauncher launcher;
  final Widget Function(BuildContext, ScrollController) builder;
  final AppSheetConfig config;

  @override
  State<_SheetOverlay> createState() => _SheetOverlayState();
}

class _SheetOverlayState extends State<_SheetOverlay> {
  final DraggableScrollableController _sheet = DraggableScrollableController();

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final launcher = widget.launcher;
    final config = widget.config;
    final media = MediaQuery.of(context);
    final top = media.padding.top;
    final available = media.size.height - top;
    final sheetHeight = config.initialChildSize.clamp(0.0, 1.0) * available;
    final surface = Theme.of(context).colorScheme.surface;
    return AnimatedBuilder(
      animation: launcher._progress,
      builder: (c, _) {
        final p = launcher._progress.value;
        if (p <= 0.001) return const SizedBox.shrink();
        return Stack(
          children: [
            // 遮罩：点外部关闭。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: launcher.close,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.32 * p),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: top,
              bottom: 0,
              child: Transform.translate(
                offset: Offset(0, (1 - p) * sheetHeight),
                child: DraggableScrollableSheet(
                  controller: _sheet,
                  expand: false,
                  initialChildSize: config.initialChildSize,
                  minChildSize: config.minChildSize,
                  maxChildSize: config.maxChildSize,
                  snap: config.snap,
                  snapSizes: config.snapSizes,
                  builder: (c2, scrollCtrl) => Material(
                    key: const ValueKey('app_sheet_surface'),
                    color: surface,
                    elevation: 8,
                    clipBehavior: Clip.antiAlias,
                    shape: const RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(16)),
                    ),
                    child: AppSheetScope(
                      close: launcher.close,
                      controller: _sheet,
                      child: widget.builder(c2, scrollCtrl),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
