import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../utils/cover_thumb.dart';
import '../utils/motion.dart';
import 'selection_badge.dart';

/// 内容页共用方形卡片（改进 B6-U6）：封面恒为正方形 + 标题 + 副标题，
/// 专辑 / 歌手 / 播放源 / 歌单卡片共用（列表行继续用 SongTile / ListTile）。
class SquareCard extends StatelessWidget {
  final String title;

  /// 标题最大行数（歌单名较长用 2，其余 1）。
  final int titleMaxLines;
  final String? subtitle;

  /// 富文本副标题（专辑卡主歌手正常、其余淡化用）：非空时优先渲染它，
  /// 回退 [subtitle] 纯文本。调用方保证两者文本内容一致。
  final InlineSpan? subtitleSpan;

  /// 封面文件路径；为空时显示 [fallback]（优先）或 [fallbackIcon] 占位。
  final String? coverPath;
  final IconData fallbackIcon;

  /// 自定义占位（播放源类型徽标等）；为空时退回 [fallbackIcon]。
  final Widget? fallback;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 叠加在封面右上角的小控件（如播放源的设置菜单），无则不叠加。
  final Widget? cornerAction;

  /// 桌面鼠标右键回调（在指针处弹出与右上角菜单相同的菜单）；
  /// 多选态或无可弹菜单时由调用方传 null。
  final GestureTapDownCallback? onSecondaryTapDown;

  /// 多选模式：隐藏右上角菜单、左上角固定勾选框（与列表行同一形态）。
  final bool selectionMode;

  /// 多选态被选中：封面描边加粗高亮（勾选框见 [selectionMode]）。
  final bool selected;

  /// 勾选标记点击回调（默认走卡片自身的 [onTap]）。
  final VoidCallback? onToggleSelect;

  const SquareCard({
    super.key,
    required this.title,
    this.titleMaxLines = 1,
    this.subtitle,
    this.subtitleSpan,
    this.coverPath,
    this.fallbackIcon = Icons.album,
    this.fallback,
    required this.onTap,
    this.onLongPress,
    this.cornerAction,
    this.onSecondaryTapDown,
    this.selectionMode = false,
    this.selected = false,
    this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sub = subtitle;
    final subSpan = subtitleSpan;
    // 尺寸由网格层一次性下发（R-3）：卡片自身不再做逐行 LayoutBuilder。
    // 独立使用（无网格）时退回最大卡宽估算，不影响几何（封面恒 1:1）。
    final decodeWidth = _SquareCardMetrics.maybeOf(context)?.decodeWidth ??
        squareCardDecodeWidth(
            SquareCardGrid.maxItemWidth, MediaQuery.devicePixelRatioOf(context));
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTapDown: onSecondaryTapDown,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 封面恒定 1:1（宽高比由 SquareCardGrid 的行高保证恰好放下文本）。
          AspectRatio(
            aspectRatio: 1,
            // StackFit.expand：无封面时占位底色也必须撑满正方形
            //（默认 loose 会让 Container 高度只由图标决定，显示成矮长条）。
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                    // 未选中态不描边（与既有卡片外观一致），选中时才套 2px 主色环。
                    border: Border.all(
                      color: colorScheme.primary,
                      width: selected ? 2 : 0,
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: coverPath != null
                      ? Image.file(
                          File(coverDisplayPath(coverPath!)),
                          fit: BoxFit.cover,
                          // 缩略图 + 降解码：网格滑动不再逐卡解大图。
                          cacheWidth: decodeWidth.round(),
                          cacheHeight: decodeWidth.round(),
                          // 换档位重解码时保留旧帧：不闪白。
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) =>
                              fallback ??
                              Icon(fallbackIcon,
                                  size: 48,
                                  color: colorScheme.primary
                                      .withValues(alpha: 0.6)))
                      : fallback ??
                          Icon(fallbackIcon,
                              size: 48,
                              color:
                                  colorScheme.primary.withValues(alpha: 0.6)),
                ),
                // 多选态隐藏角标菜单（避免误触），勾选框统一叠在左上角。
                if (cornerAction != null && !selectionMode)
                  Positioned(top: 2, right: 2, child: cornerAction!),
                if (selectionMode)
                  Positioned(
                    left: 2,
                    top: 2,
                    child: SelectionBadge(
                      selected: selected,
                      onTap: onToggleSelect ?? onTap,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(title,
              maxLines: titleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          if (subSpan != null)
            RichText(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                text: TextSpan(
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color:
                            colorScheme.onSurface.withValues(alpha: 0.6)),
                    children: [subSpan])),
          if (subSpan == null && sub != null)
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}

/// 卡片封面解码宽（物理像素）：卡宽按 32 逻辑像素一档向上取整、封顶
/// [SquareCardGrid.maxItemWidth]。
///
/// 为什么要量化：`Image.file(cacheWidth:)` 会包成 `ResizeImage`，其 ImageCache
/// key 含解码宽整数像素——逐像素跟随卡宽会「每帧一个新 key + 每帧重解码」，
/// 卡宽连续变化时表现为封面不停闪白。按档位取整后，一次开合最多跨 1 档。
double squareCardDecodeWidth(double itemWidth, double devicePixelRatio) {
  const step = 32.0;
  final logical = math.min(itemWidth, SquareCardGrid.maxItemWidth);
  final bucket =
      math.min(SquareCardGrid.maxItemWidth, (logical / step).ceil() * step);
  return (bucket * devicePixelRatio).roundToDouble();
}

/// 网格层下发的卡片尺寸（InheritedWidget）：让卡片免于逐行 LayoutBuilder，
/// 又可独立使用（取不到时为 null → 退回最大卡宽估算）。
class _SquareCardMetrics extends InheritedWidget {
  /// 已量化的解码宽（物理像素）。
  final double decodeWidth;
  const _SquareCardMetrics({required this.decodeWidth, required super.child});

  static _SquareCardMetrics? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SquareCardMetrics>();

  /// 只比较解码档位：卡宽连续变化（补间）但没换档位时不通知，
  /// 卡片连 rebuild 都不做（旧实现比较原始卡宽，每帧全卡重建）。
  @override
  bool updateShouldNotify(_SquareCardMetrics oldWidget) =>
      oldWidget.decodeWidth != decodeWidth;
}

/// 方形卡片网格：卡宽走补间、列数跟着可用空间走，保证每张卡片的封面恰为正方形
///（固定 childAspectRatio 会在窄列时把封面压成长方形——改进反馈 #3）。
///
/// ## 为什么「卡宽」和「列数」用不同的输入源
///
/// 旧实现先算列数再反算卡宽：
///
/// ```dart
/// cols  = ceil((可用宽 + gap) / (maxItemWidth + gap));   // 阶梯函数
/// itemW = (可用宽 - (cols - 1) * gap) / cols;            // 由 cols 反算
/// ```
///
/// `itemW` 因此是 `cols` 的函数，而 `cols` 是宽度阶梯函数 ⇒ 卡宽必然锯齿。
/// 侧栏/队列面板 300ms 伸缩期间内容区逐帧变窄，一次开合要穿越 2 个列数档位，
/// 每穿一次卡宽先缩小再猛地放大（实测 1020→660：173 → 220 → 161 → 220 → 198.7，
/// 两次 +27% / +36% 暴涨）——观感就是「卡片疯狂切换大小」。
///
/// 因为 `itemW` 逐帧变，`Image.file(cacheWidth:)` 的 ImageCache key 也随之逐帧变，
/// 每张可见卡每帧重解码；又没设 `gaplessPlayback`，解码完成前旧帧被丢弃 ⇒ 封面闪白，
/// 整体观感即「刷新页面」。
///
/// 现在反过来：卡宽由 [kPageMotion] 补间驱动（**连续**），列数由当前卡宽反推
/// （**离散**）。列数变化的那一刻卡宽不变，只换位置；网格自身宽度按
/// `cols * itemW + gap` 显式给出（恒 ≤ 可用宽，静止时恰好铺满），
/// 动画期间行尾留白 ≤ 一卡，等放得下更多列时补上。这就是「自适应移动」。
class SquareCardGrid extends StatefulWidget {
  /// 单项最大宽度（与旧 maxCrossAxisExtent 语义一致）。
  static const double maxItemWidth = 220;
  static const double gap = 16;
  static const double sidePadding = 16;

  /// 卡宽补间的最短触发量：内容区一次跳变 ≥ 该值才走补间
  ///（开/关队列 360、侧栏 260 命中；窗口拖拽每帧只有几像素 → 直接跟手，
  /// 不引入 300ms 滞后）。
  static const double motionTriggerDelta = 64;

  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;

  /// 标题最大行数（与卡片保持一致，用于估算文本高度）。
  final int titleMaxLines;

  /// 网格滚动控制器（计数栏双击回顶用）；为空时自带位置。
  final ScrollController? controller;

  /// **终态**可用宽度（来自 [ScreenMetrics.contentWidth]）。
  ///
  /// 内容区宽度是离散目标值：一次开合只跳一次，不受侧栏/队列 300ms 伸缩影响。
  /// 用它判断「是否发生了足以补间的跳变」，实际布局仍按 [LayoutBuilder] 的
  /// 实时约束（所以补间被打断、窗口拖拽时都能无缝接续）。
  /// 为 null 时退回实时约束（独立使用/测试，行为与旧实现一致）。
  final double? targetWidth;

  const SquareCardGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.titleMaxLines = 1,
    this.controller,
    this.targetWidth,
  });

  @override
  State<SquareCardGrid> createState() => _SquareCardGridState();
}

class _SquareCardGridState extends State<SquareCardGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: kPageMotion,
  );

  /// 补间段：屏幕上已有的卡宽 → 终态卡宽（逻辑像素）。用裸 controller + 曲线
  /// 在 build 里求值，避免每次重定向都新建 `Tween`/`CurvedAnimation`（需释放）。
  double _fromItemW = 0;
  double _toItemW = 0;

  /// 当前渲染出的卡宽（每帧在 build 里回写，作为下一次补间的起点）。
  double _currentItemW = 0;

  /// 上一次的目标宽度，用来判断本次变化是否达到 [SquareCardGrid.motionTriggerDelta]。
  double? _lastTargetWidth;

  @override
  void initState() {
    super.initState();
    _lastTargetWidth = widget.targetWidth;
  }

  /// `targetWidth` 走构造函数，变化时由这里到达（不是 didChangeDependencies：
  /// 页面读 `ScreenMetrics` → 重建 → 传新终态宽，本组件自身不依赖该 InheritedWidget）。
  @override
  void didUpdateWidget(SquareCardGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.targetWidth;
    if (target == null) {
      _lastTargetWidth = null;
      _ctrl.stop();
      return;
    }
    final last = _lastTargetWidth;
    _lastTargetWidth = target;
    if (last == null) return; // 刚拿到终态宽：交给 build 的实时约束跟手。
    final delta = (target - last).abs();
    if (delta == 0) return; // 无关重建（播放/收藏/搜索等）：不要打断在飞的补间。
    if (delta < SquareCardGrid.motionTriggerDelta) {
      // 窗口拖拽等小幅变化：跟手。若正在补间，说明拖拽接管了，立即停下
      // （否则会拖着一格错的终态跑完 300ms）。
      if (_ctrl.isAnimating) _ctrl.stop();
      return;
    }
    // 轨道开合（侧栏 260 / 队列 360）：卡宽从屏幕上当前值补间到终态，
    // 与槽的 AnimatedContainer 同一时长同一条曲线。
    _fromItemW = _currentItemW > 0 ? _currentItemW : _itemWidthFor(target);
    _toItemW = _itemWidthFor(target);
    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 目标宽下「恰好铺满」的卡宽（静止态口径，与旧实现逐像素一致）。
  static double _itemWidthFor(double width) {
    final avail = math.max(0.0, width - SquareCardGrid.sidePadding * 2);
    final cols = math.max(
        1,
        ((avail + SquareCardGrid.gap) /
                (SquareCardGrid.maxItemWidth + SquareCardGrid.gap))
            .ceil());
    return (avail - (cols - 1) * SquareCardGrid.gap) / cols;
  }

  /// 补间中的卡宽（曲线与槽的 `AnimatedContainer` 一致）。
  double get _animatedItemW =>
      _fromItemW + (_toItemW - _fromItemW) * kPageMotionCurve.transform(_ctrl.value);

  /// 卡片底部文本区高度（间距 + 标题 + 副标题），带少量余量防溢出。
  double _textHeight(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle? s) {
      final size = s?.fontSize ?? 14;
      return scaler.scale(size) * (s?.height ?? 1.3);
    }

    return 8 +
        line(theme.textTheme.bodyMedium) * widget.titleMaxLines +
        line(theme.textTheme.bodySmall) +
        6;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final avail = math.max(
              0.0, constraints.maxWidth - SquareCardGrid.sidePadding * 2);
          // 补间进行中用动画值；静止 / 拖拽时用实时约束的铺满值。
          final itemW = _ctrl.isAnimating
              ? math.max(1.0, _animatedItemW)
              : _itemWidthFor(constraints.maxWidth);
          _currentItemW = itemW;
          // 列数由「当前卡宽」反推：卡宽连续 ⇒ 只在真放得下时变，
          // 且变的那一刻卡宽不变（只换位置）。epsilon 只为抵消浮点欠冲，
          // 保证 gridW ≤ 可用宽（不溢出、不裁剪）。
          final cols = math.max(
              1,
              ((avail + SquareCardGrid.gap + 0.01) /
                      (itemW + SquareCardGrid.gap))
                  .floor());
          final gridW = SquareCardGrid.sidePadding * 2 +
              cols * itemW +
              (cols - 1) * SquareCardGrid.gap;
          return Align(
            // 行尾留白落在右侧（不居中），避免动画期间整格来回平移。
            alignment: Alignment.topLeft,
            child: SizedBox(
              // 显式宽度：SliverGridDelegate 恒把自身宽均分给各列，
              // 只由它才能精确控制「补间出的卡宽」。
              width: gridW,
              child: _SquareCardMetrics(
                decodeWidth: squareCardDecodeWidth(
                    itemW, MediaQuery.devicePixelRatioOf(context)),
                child: GridView.builder(
                  controller: widget.controller,
                  padding: const EdgeInsets.fromLTRB(
                      SquareCardGrid.sidePadding,
                      0,
                      SquareCardGrid.sidePadding,
                      16),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: SquareCardGrid.gap,
                    crossAxisSpacing: SquareCardGrid.gap,
                    mainAxisExtent: itemW + _textHeight(context),
                  ),
                  itemCount: widget.itemCount,
                  itemBuilder: widget.itemBuilder,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
