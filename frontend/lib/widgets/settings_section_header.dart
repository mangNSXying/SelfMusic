import 'package:flutter/material.dart';

/// 设置页组标题：统一 16/8 内边距、主色、titleSmall w600。
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const SettingsSectionHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final text = Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: trailing == null
          ? Row(children: [Expanded(child: text)])
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: 8),
                trailing!,
              ],
            ),
    );
  }
}
