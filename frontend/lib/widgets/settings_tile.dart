import 'package:flutter/material.dart';

/// 设置页统一行：左侧上为名称、下为解释，右侧为当前设置。
///
/// 右侧可以是开关、当前值文本、加载指示或动作图标；不再使用右侧箭头，
/// 当前值本身即「可点开修改」的提示。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    super.key,
    required this.title,
    this.description,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  /// 开关行：整行点击与开关本身都可切换。
  factory SettingsTile.toggle({
    Key? key,
    required String title,
    String? description,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return SettingsTile(
      key: key,
      title: title,
      description: description,
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: onChanged == null ? null : () => onChanged(!value),
      enabled: onChanged != null,
    );
  }

  /// 取值行：右侧显示当前设置，点击整行打开选择器。
  factory SettingsTile.value({
    Key? key,
    required String title,
    String? description,
    required String value,
    VoidCallback? onTap,
    bool enabled = true,
  }) {
    return SettingsTile(
      key: key,
      title: title,
      description: description,
      trailing: SettingsValueText(value, enabled: enabled),
      onTap: enabled ? onTap : null,
      enabled: enabled,
    );
  }

  final String title;
  final String? description;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final titleColor =
        enabled ? cs.onSurface : cs.onSurface.withValues(alpha: 0.38);
    final descColor =
        enabled ? cs.onSurfaceVariant : cs.onSurface.withValues(alpha: 0.38);

    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: textTheme.bodyLarge?.copyWith(color: titleColor),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      description!,
                      style: textTheme.bodySmall?.copyWith(color: descColor),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
          ],
        ),
      ),
    );

    if (onTap == null || !enabled) return row;
    return InkWell(onTap: onTap, child: row);
  }
}

/// 设置行右侧的当前值文本（单行、超长省略）。
class SettingsValueText extends StatelessWidget {
  const SettingsValueText(
    this.value, {
    super.key,
    this.enabled = true,
    this.maxWidth = 180,
  });

  final String value;
  final bool enabled;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // 开关控件宽 60、轨道宽 52，左右各留 4；文字右缘对齐轨道而非控件外框。
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.right,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: enabled
                    ? cs.onSurfaceVariant
                    : cs.onSurface.withValues(alpha: 0.38),
              ),
        ),
      ),
    );
  }
}
