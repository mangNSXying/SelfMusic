import 'package:flutter/material.dart';

import '../theme/app_metrics.dart';

/// 单选组中的一个选项。
class SingleChoiceOption<T> {
  final T value;
  final String label;
  final IconData? icon;

  const SingleChoiceOption({
    required this.value,
    required this.label,
    this.icon,
  });
}

/// 自适应换行的单选按钮组：选项按内容宽度排列，窄屏自动换行，
/// 不使用横向滚动，也不强制拉满整行。
///
/// 视觉上与全局按钮体系一致：12px 圆角、40px 最小高度。选中态用
/// `primaryContainer` 底 + `primary` 边框，弱于实心主操作按钮。
class SingleChoiceGroup<T> extends StatelessWidget {
  final List<SingleChoiceOption<T>> options;
  final T value;
  final ValueChanged<T>? onChanged;

  const SingleChoiceGroup({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Align 撑满可用宽度，Wrap 自身保持内容宽度；选项始终从左侧开始，
    // 不因父级 Column 的居中对齐而整组居中。
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final option in options)
            _SingleChoiceButton<T>(
              key: ValueKey(option.value),
              option: option,
              selected: option.value == value,
              onTap: onChanged == null ? null : () => onChanged!(option.value),
            ),
        ],
      ),
    );
  }
}

class _SingleChoiceButton<T> extends StatelessWidget {
  final SingleChoiceOption<T> option;
  final bool selected;
  final VoidCallback? onTap;

  const _SingleChoiceButton({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = onTap == null;
    final fg = disabled
        ? cs.onSurface.withValues(alpha: 0.38)
        : selected
            ? cs.onPrimaryContainer
            : cs.onSurfaceVariant;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(kButtonRadius),
      side: BorderSide(
        color: disabled
            ? cs.outlineVariant.withValues(alpha: 0.5)
            : selected
                ? cs.primary
                : cs.outlineVariant,
      ),
    );

    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: disabled
            ? cs.onSurface.withValues(alpha: 0.05)
            : selected
                ? cs.primaryContainer
                : cs.surfaceContainerHighest,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kButtonHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (option.icon != null) ...[
                    Icon(option.icon, size: 18, color: fg),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    option.label,
                    style: TextStyle(
                      color: fg,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
