import 'package:flutter/material.dart';

/// 列表多选模式顶栏：显示已选数量、「全选/取消全选」与批量操作按钮。
class SelectionBar extends StatelessWidget {
  final int total;
  final int selectedCount;
  final VoidCallback? onToggleAll;
  final VoidCallback? onCancel;
  final List<Widget> actions;
  const SelectionBar({
    super.key,
    required this.total,
    required this.selectedCount,
    this.onToggleAll,
    this.onCancel,
    this.actions = const [],
  });

  bool get _allSelected => total > 0 && selectedCount == total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: SizedBox(
        height: 48,
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
            ...actions,
          ],
        ),
      ),
    );
  }
}