import 'package:flutter/material.dart';

import 'row_list.dart';

/// 批量操作项：统一收进多选栏右侧的纵向三点菜单。
class SelectionAction {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  const SelectionAction(
      {required this.icon, required this.label, this.onPressed});
}

/// 列表多选模式顶栏：显示已选数量、「全选/取消全选」，批量操作收进右侧三点菜单。
class SelectionBar extends StatelessWidget {
  final int total;

  /// 已选总数（可包含当前列表之外的歌曲，如源页文件夹递归选中的子目录）。
  final int selectedCount;

  /// 当前列表是否已全选；为空时回退到 [selectedCount] == [total]。
  ///
  /// [selectedCount] 可能是整个集合的已选数（大于当前显示条数），因此全选
  /// 文案不能只靠两者相等判断。
  final bool? allSelected;

  final VoidCallback? onToggleAll;
  final VoidCallback? onCancel;
  final List<SelectionAction> actions;
  const SelectionBar({
    super.key,
    required this.total,
    required this.selectedCount,
    this.allSelected,
    this.onToggleAll,
    this.onCancel,
    this.actions = const [],
  });

  bool get _allSelected =>
      allSelected ?? (total > 0 && selectedCount == total);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SizedBox(
        // 与计数头等高（[kListHeaderHeight]）：进出多选模式内容不跳动。
        height: kListHeaderHeight,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消选择',
              onPressed: onCancel,
            ),
            Text(
              '已选 $selectedCount',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (onToggleAll != null)
              TextButton(
                onPressed: onToggleAll,
                child: Text(_allSelected ? '取消全选' : '全选'),
              ),
            if (actions.isNotEmpty)
              PopupMenuButton<int>(
                tooltip: '更多操作',
                icon: const Icon(Icons.more_vert),
                onSelected: (i) => actions[i].onPressed?.call(),
                itemBuilder: (c) => [
                  for (var i = 0; i < actions.length; i++)
                    PopupMenuItem(
                      value: i,
                      enabled: actions[i].onPressed != null,
                      child: Row(
                        children: [
                          Icon(actions[i].icon),
                          const SizedBox(width: 12),
                          Text(actions[i].label),
                        ],
                      ),
                    ),
                ],
              )
            else
              const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}
