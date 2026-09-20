import 'package:flutter/material.dart';

/// 列表 / 卡片展示切换按钮（播放列表、播放源、专辑、歌手四页共用）。
class ViewModeToggle extends StatelessWidget {
  /// 当前是否卡片形态。
  final bool card;
  final ValueChanged<bool> onChanged;

  const ViewModeToggle({
    super.key,
    required this.card,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: card ? '切换为列表' : '切换为卡片',
      icon: Icon(card ? Icons.view_list : Icons.grid_view),
      onPressed: () => onChanged(!card),
    );
  }
}
