import 'package:flutter/material.dart';

/// 内容页「左列表 / 右详情」分栏容器（大横屏 + 列表模式）。
///
/// 设计口径：
/// - [enabled] 为 false 时**原样返回 [list]**：窄屏与卡片模式保持既有形态，
///   没有额外一层布局/绘制成本；
/// - 两栏各自包 [RepaintBoundary]：一侧滚动、播放行高亮、封面回填不脏另一侧；
/// - 分隔线用 1px `outlineVariant`，与 `RowList` 的行分隔线同色阶。
///
/// 后续若要收敛成统一的 `ShowDetailPage`（窄屏拖拽弹层 / 宽屏整页叠层 /
/// 宽屏分栏右栏共用同一份详情实现），**右栏这一侧就是它的落点**：三种呈现
/// 只差外壳，详情本体与数据快照语义完全一致。
class ListDetailSplit extends StatelessWidget {
  const ListDetailSplit({
    super.key,
    required this.enabled,
    required this.listWidth,
    required this.list,
    required this.detail,
  });

  /// 是否启用分栏（判屏 + 列表模式，见 `splitDetailActive`）。
  final bool enabled;

  /// 左栏宽度（`ScreenMetrics.listPaneWidth`）。
  final double listWidth;

  /// 左栏：列表页本体（含自己的计数头/排序/视图切换）。
  final Widget list;

  /// 右栏：[DetailPane]。
  final Widget detail;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return list;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: listWidth, child: RepaintBoundary(child: list)),
        // 1px 竖分隔线：与行分隔线同宽同色，两栏视觉上同属一块面板。
        ColoredBox(
          color: Theme.of(context).colorScheme.outlineVariant,
          child: const SizedBox(width: 1),
        ),
        Expanded(child: RepaintBoundary(child: detail)),
      ],
    );
  }
}

/// 分栏右栏：详情（[detail] 为空时是空态占位）。
///
/// 换选中项时只在**栏内**做一次轻量过渡（[duration] 由调用方按全局
/// 「页面切换」档换算：关闭档传 [Duration.zero]），不像整页叠层那样滑入一整屏。
/// [detailKey] 变化即触发过渡（通常是专辑分组键/歌手身份键）。
class DetailPane extends StatelessWidget {
  const DetailPane({
    super.key,
    required this.detail,
    required this.detailKey,
    required this.emptyIcon,
    required this.emptyText,
    this.duration = Duration.zero,
  });

  /// 详情页本体；null = 右侧还没有选中任何条目。
  final Widget? detail;

  /// 详情标识（变化时播栏内过渡）。
  final Object? detailKey;

  final IconData emptyIcon;

  /// 空态文案（可用 `\n` 折行）。
  final String emptyText;

  /// 栏内过渡时长；[Duration.zero] = 不做过渡（全局「关闭」档）。
  final Duration duration;

  static const Key _emptyKey = ValueKey<String>('detail-pane-empty');

  @override
  Widget build(BuildContext context) {
    final body = detail;
    final child = body == null
        ? _DetailPaneEmpty(
            key: _emptyKey, icon: emptyIcon, text: emptyText)
        // 用详情标识做 Key：换条目时旧页淡出、新页淡入，不混用 State。
        : KeyedSubtree(key: ObjectKey(detailKey ?? body), child: body);
    if (duration == Duration.zero) return child;
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      // 默认 layoutBuilder 会把子项按自身尺寸居中；详情页需要铺满整栏。
      layoutBuilder: (currentChild, previousChildren) => Stack(
        fit: StackFit.expand,
        children: [
          ...previousChildren,
          if (currentChild != null) currentChild,
        ],
      ),
      transitionBuilder: (c, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          // 极轻的横向位移：只有一栏在动，位移必须收敛（整页滑入会显得跳）。
          position: Tween<Offset>(
            begin: const Offset(0.015, 0),
            end: Offset.zero,
          ).animate(anim),
          child: c,
        ),
      ),
      child: child,
    );
  }
}

class _DetailPaneEmpty extends StatelessWidget {
  const _DetailPaneEmpty({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: cs.primary.withValues(alpha: 0.30)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
