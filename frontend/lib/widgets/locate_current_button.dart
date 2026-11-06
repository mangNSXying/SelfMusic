import 'package:flutter/material.dart';

import 'toolbar_icon_button.dart';

/// 计数栏（「共 N 首」）右侧的「定位当前曲」按钮：滚到当前播放歌曲所在行。
///
/// [onPressed] 为 null 表示当前曲不在本列表（或列表为空），按钮置灰。
class LocateCurrentButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const LocateCurrentButton({super.key, required this.onPressed});

  @override
  Widget build(BuildContext context) => ToolbarIconButton(
        icon: Icons.my_location,
        tooltip: '定位当前曲',
        onPressed: onPressed,
      );
}
