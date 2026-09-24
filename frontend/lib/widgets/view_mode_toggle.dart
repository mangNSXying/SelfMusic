import 'package:flutter/material.dart';

/// 列表 / 卡片展示切换按钮（歌单、播放源、专辑、歌手四页共用）。
///
/// 紧凑尺寸（32px），避免把计数行撑成占位栏（UI4）。
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
      iconSize: 20,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(card ? Icons.view_list : Icons.grid_view),
      onPressed: () => onChanged(!card),
    );
  }
}
