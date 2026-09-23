import 'package:flutter/material.dart';

import '../utils/collection_sort.dart';

/// 内容页排序入口（挂在 CountHeader 右侧）：勾选当前排序方式。
/// [withWeight] 为 true 时提供权重升/降（仅歌曲类内容页）。
class SortMenuButton extends StatelessWidget {
  final CollectionSort value;
  final bool withWeight;
  final ValueChanged<CollectionSort> onChanged;

  const SortMenuButton({
    super.key,
    required this.value,
    required this.onChanged,
    this.withWeight = false,
  });

  @override
  Widget build(BuildContext context) {
    final options = CollectionSort.values
        .where((s) => withWeight || !s.isWeight)
        .toList();
    return PopupMenuButton<CollectionSort>(
      tooltip: '排序',
      icon: const Icon(Icons.sort, size: 20),
      initialValue: value,
      onSelected: onChanged,
      itemBuilder: (c) => [
        for (final o in options)
          CheckedPopupMenuItem(
            value: o,
            checked: o == value,
            child: Text(o.label),
          ),
      ],
    );
  }
}
