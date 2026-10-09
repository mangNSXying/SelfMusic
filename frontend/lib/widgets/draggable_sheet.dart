import 'package:flutter/material.dart';

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
/// 跟手的队列窗口走 [AppSheetLauncher] 的根悬浮层——路由 `push` 会触发
/// `NavigatorState._cancelActivePointers()`，把触发跟手的那根手指一并取消，
/// 跟手无法继续（见 [AppSheetLauncher] 注释）。
///
/// 窗口语义（与队列悬浮层一致）：头部与列表共用同一个 scroll controller，
/// 任意位置按下都可拖拽窗口或滚动列表；顶部安全区由路由 `useSafeArea`
/// 消费，内容**不要**再套 `SafeArea(top: true)`（否则多出一整块状态栏空白）。
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
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: config.initialChildSize,
      minChildSize: config.minChildSize,
      maxChildSize: config.maxChildSize,
      snap: config.snap,
      snapSizes: config.snapSizes,
      builder: (c, scrollCtrl) => builder(c, scrollCtrl),
    ),
  );
}

/// 供统一窗口内容调用「关闭窗口」的祖先（路由/悬浮层通用）。
///
/// 路由版可继续用 `Navigator.pop`；根悬浮层没有路由可 pop，必须经此回调收起
/// （否则会误 pop 底层页面）。
class AppSheetScope extends InheritedWidget {
  const AppSheetScope({super.key, required this.close, required super.child});

  final VoidCallback close;

  /// 关闭当前统一窗口（无匹配 scope 时静默忽略）。
  static void closeOf(BuildContext context) {
    context.getInheritedWidgetOfExactType<AppSheetScope>()?.close();
  }

  @override
  bool updateShouldNotify(AppSheetScope oldWidget) => close != oldWidget.close;
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

/// 统一窗口的置顶标题行：一行标题 + 歌曲数（[CountHeader]）+ 分隔线。
///
/// 与 [AppSheetHeader] 搭配：高度由 [heightOf] 按主题字号现算（对字体缩放稳健），
/// 长标题单行省略号，钉死后不溢出/不抖动。专辑与歌手弹层共用，保证头部同构；
/// 队列窗口头部另有拖拽把手与关闭按钮，不套用本组件。
class AppSheetTitleBar extends StatelessWidget {
  const AppSheetTitleBar({
    super.key,
    required this.title,
    required this.count,
    this.unit = '首',
  });

  final String title;
  final int count;
  final String unit;

  /// 标题行总高：上内边距 16 + 标题一行 + 下内边距 8 + 计数头 + 分隔线。
  static double heightOf(BuildContext context) =>
      16 + _lineHeight(context) + 8 + kListHeaderHeight + kRowSeparatorHeight;

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
    // 用 [heightOf] 固定总高：钉住的 head 声明高度须与子树实际高度严格一致，
    // 否则 SliverPersistentHeader 会因 layoutExtent/paintExtent 不等而断言。
    return SizedBox(
      height: heightOf(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _titleStyle(context),
              ),
            ),
          ),
          CountHeader(count: count, unit: unit),
          const Divider(height: kRowSeparatorHeight),
        ],
      ),
    );
  }
}

/// 统一拖拽式窗口的根悬浮层宿主（Root 持有，全 App 单例，经 Provider 下发）。
///
/// 用 `OverlayEntry`（而非 `showModalBottomSheet` 路由）承载窗口：迷你条上滑
/// 跟手时窗口已插入，但**不 push 路由**——`Navigator.push` 会同步取消进行中的
/// 手势指针，跟手第一帧即被打断（历史回归）。悬浮层由 [swipe] 逐帧写入展示
/// 进度（0=隐藏 → 1=展开），点击启动则播放展开动画。
class AppSheetLauncher {
  AppSheetLauncher({required TickerProvider vsync})
      : _progress = AnimationController(
          vsync: vsync,
          duration: const Duration(milliseconds: 220),
        );

  final AnimationController _progress;
  OverlayEntry? _entry;
  VoidCallback? _onClosed;

  /// 窗口悬浮层是否已插入（含展开动画 / 跟手进行中）。
  bool get isShowing => _entry != null;

  /// 跟手进行中的展示进度（0=隐藏 → 1=展开），供宿主松手吸附判定。
  double get swipeValue => _progress.value;

  void _insert(
    BuildContext context, {
    required Widget Function(BuildContext context, ScrollController scrollCtrl)
        builder,
    required AppSheetConfig config,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry = OverlayEntry(
      builder: (c) => _SheetOverlay(
        launcher: this,
        builder: builder,
        config: config,
      ),
    );
    overlay.insert(_entry!);
  }

  /// 点击启动：插入悬浮层并播放展开动画。窗口已在展示则忽略。
  Future<T?> openTap<T>(
    BuildContext context, {
    required Widget Function(BuildContext context, ScrollController scrollCtrl)
        builder,
    AppSheetConfig config = const AppSheetConfig(),
    VoidCallback? onOpen,
    VoidCallback? onClose,
  }) {
    if (isShowing) return Future.value(null);
    _onClosed = onClose;
    _progress.value = 0;
    _insert(context, builder: builder, config: config);
    onOpen?.call();
    _progress.forward();
    return Future.value(null);
  }

  /// 滑动启动①：插入进度 0 的悬浮层，交由宿主手指驱动。
  /// 返回 false 表示窗口已在展示，宿主应忽略本次手势。
  bool beginSwipe<T>(
    BuildContext context, {
    required Widget Function(BuildContext context, ScrollController scrollCtrl)
        builder,
    AppSheetConfig config = const AppSheetConfig(),
    VoidCallback? onOpen,
    VoidCallback? onClose,
  }) {
    if (isShowing) return false;
    _onClosed = onClose;
    _progress.value = 0;
    _insert(context, builder: builder, config: config);
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
      _progress.forward();
    } else {
      close();
    }
  }

  /// 收起并移除悬浮层（遮罩 / 关闭按钮 / 返回意图共用，幂等）。
  void close() {
    if (!isShowing) return;
    if (_progress.value <= 0.001) {
      _remove();
      return;
    }
    _progress
        .animateTo(0.0, duration: const Duration(milliseconds: 180))
        .whenComplete(_remove);
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
    final cb = _onClosed;
    _onClosed = null;
    cb?.call();
  }

  void dispose() {
    _entry?.remove();
    _entry = null;
    _progress.dispose();
  }
}

/// 悬浮层内容：遮罩 + 底部统一窗口（`DraggableScrollableSheet`），整体按
/// [_progress] 位移。顶部让开状态栏（顶部区域透明，触摸穿透到遮罩）。
class _SheetOverlay extends StatelessWidget {
  const _SheetOverlay({
    required this.launcher,
    required this.builder,
    required this.config,
  });

  final AppSheetLauncher launcher;
  final Widget Function(BuildContext, ScrollController) builder;
  final AppSheetConfig config;

  @override
  Widget build(BuildContext context) {
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
                      child: builder(c2, scrollCtrl),
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
