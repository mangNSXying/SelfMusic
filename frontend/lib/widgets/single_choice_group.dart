import 'package:flutter/material.dart';

import '../services/haptics.dart';
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
///
/// [expanded] 为 true 时选项等分整行（4 个类型、EQ 预设这类定长选项组
/// 用它消除右侧空档）；等分后不再换行，容器过窄时由外层负责折行。
class SingleChoiceGroup<T> extends StatelessWidget {
  final List<SingleChoiceOption<T>> options;

  /// 当前选中值；传 null 表示「全部未选中」（如 EQ 手调后不匹配任何预设）。
  final T? value;
  final ValueChanged<T>? onChanged;
  final bool expanded;

  const SingleChoiceGroup({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    // Align 撑满可用宽度，Wrap 自身保持内容宽度；选项始终从左侧开始，
    // 不因父级 Column 的居中对齐而整组居中。
    final buttons = [
      for (final option in options)
        _SingleChoiceButton<T>(
          key: ValueKey(option.value),
          option: option,
          selected: option.value == value,
          onTap: onChanged == null
              ? null
              : () {
                  Haptics.fire(HapticStrength.selection);
                  onChanged!(option.value);
                },
        ),
    ];
    if (expanded) {
      // 等分整行。但容器过窄时不能硬挤（4 个协议在 320 宽下会各自被压到
      // 放不下文字），此时退回内容宽度的自然换行，与 expanded=false 一致。
      // 用 MediaQuery 而不是 LayoutBuilder：AlertDialog 内容在 IntrinsicWidth
      // 里，LayoutBuilder 不支持 intrinsic 计算。
      final perItem = MediaQuery.sizeOf(context).width / options.length;
      if (perItem >= 84) {
        return Row(
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: buttons[i]),
            ],
          ],
        );
      }
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: buttons,
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
        ? selected
            ? cs.onPrimaryContainer.withValues(alpha: 0.55)
            : cs.onSurface.withValues(alpha: 0.38)
        : selected
            ? cs.onPrimaryContainer
            : cs.onSurfaceVariant;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(kButtonRadius),
      side: BorderSide(
        color: selected
            ? cs.primary.withValues(alpha: disabled ? 0.4 : 1)
            : disabled
                ? cs.outlineVariant.withValues(alpha: 0.5)
                : cs.outlineVariant,
      ),
    );

    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected
            ? cs.primaryContainer.withValues(alpha: disabled ? 0.42 : 1)
            : disabled
                ? cs.onSurface.withValues(alpha: 0.05)
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
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (option.icon != null) ...[
                    Icon(option.icon, size: 18, color: fg),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      option.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      ),
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
