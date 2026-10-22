import 'package:flutter/material.dart';

import '../theme/app_metrics.dart';

/// 内容页头部（歌单详情、播放源浏览等）的动作按钮。
///
/// 与全局按钮主题共用 12px 圆角，但使用紧凑尺寸，保证标题、播放/扫描
/// 和工具图标能排在同一行。[primary] 为 true 时用 Filled，否则用 Outlined。
class HeaderActionButton extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  const HeaderActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    final style = primary
        ? FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, kHeaderButtonHeight),
            padding: const EdgeInsets.symmetric(
              horizontal: kHeaderButtonHorizontalPadding,
            ),
          )
        : OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, kHeaderButtonHeight),
            padding: const EdgeInsets.symmetric(
              horizontal: kHeaderButtonHorizontalPadding,
            ),
          );
    return primary
        ? FilledButton.icon(
            style: style,
            onPressed: onPressed,
            icon: icon,
            label: Text(label),
          )
        : OutlinedButton.icon(
            style: style,
            onPressed: onPressed,
            icon: icon,
            label: Text(label),
          );
  }
}
