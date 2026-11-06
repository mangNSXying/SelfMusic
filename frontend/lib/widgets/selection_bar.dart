import 'package:flutter/material.dart';

import '../theme/app_metrics.dart';
import '../utils/toggle_cycle.dart';
import 'row_list.dart';
import 'toolbar_icon_button.dart';

/// 批量操作项：统一收进多选栏右侧的纵向三点菜单。
class SelectionAction {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  const SelectionAction(
      {required this.icon, required this.label, this.onPressed});
}

/// 列表多选模式顶栏：显示已选数量，右侧为「全选 / 全不选」单图标切换
/// （已全选 → 全不选；否则 → 全选），批量操作收进三点菜单。
class SelectionBar extends StatelessWidget {
  final int total;

  /// 已选总数（可包含当前列表之外的歌曲，如源页文件夹递归选中的子目录）。
  final int selectedCount;

  /// 当前列表是否已全选；为空时回退到 [selectedCount] == [total]。
  ///
  /// [selectedCount] 可能是整个集合的已选数（大于当前显示条数），因此全选
  /// 禁用态不能只靠两者相等判断。
  final bool? allSelected;

  /// 全选：把当前可见项加入选择集；为空时不显示该按钮。
  final VoidCallback? onSelectAll;

  /// 全不选：清空整个选择集（保持多选模式）；为空时不显示该按钮。
  final VoidCallback? onSelectNone;

  final VoidCallback? onCancel;
  final List<SelectionAction> actions;
  const SelectionBar({
    super.key,
    required this.total,
    required this.selectedCount,
    this.allSelected,
    this.onSelectAll,
    this.onSelectNone,
    this.onCancel,
    this.actions = const [],
  });

  bool get _allSelected => allSelected ?? (total > 0 && selectedCount == total);

  @override
  Widget build(BuildContext context) {
    final scale = appUiScaleOf(context);
    final textTheme = Theme.of(context).textTheme;
    // 全选/全不选单按钮：已全选 → 全不选；否则 → 全选。
    final selectAll = nextInCycle(_allSelected, const [true, false]);
    final VoidCallback? onToggle = selectAll
        ? (onSelectAll != null && total > 0 ? onSelectAll : null)
        : (onSelectNone != null && selectedCount > 0 ? onSelectNone : null);
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: SizedBox(
        // 与计数头等高（[listHeaderHeightOf]）：进出多选模式内容不跳动。
        height: listHeaderHeightOf(context),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close),
              iconSize: 24 * scale,
              tooltip: '取消选择',
              onPressed: onCancel,
            ),
            Text(
              '已选 $selectedCount',
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: (textTheme.titleSmall?.fontSize ?? 14) * scale,
              ),
            ),
            const Spacer(),
            if (onSelectAll != null || onSelectNone != null)
              ToolbarIconButton(
                icon: selectAll ? Icons.select_all : Icons.deselect,
                tooltip: selectAll ? '全选' : '全不选',
                onPressed: onToggle,
              ),
            if (actions.isNotEmpty)
              PopupMenuButton<int>(
                tooltip: '更多操作',
                icon: const Icon(Icons.more_vert),
                iconSize: 24 * scale,
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
              SizedBox(width: 8 * scale),
          ],
        ),
      ),
    );
  }
}
