import 'package:flutter/material.dart';

import '../utils/collection_sort.dart';

/// 内容页排序入口（挂在 CountHeader 右侧）：勾选当前排序方式。
///
/// [scope] 决定可选字段：歌曲类内容页给权重/播放时长/播放次数/时长，
/// 集合类内容页给曲数。
class SortMenuButton extends StatelessWidget {
  final CollectionSort value;
  final SortScope scope;
  final ValueChanged<CollectionSort> onChanged;

  const SortMenuButton({
    super.key,
    required this.value,
    required this.onChanged,
    this.scope = SortScope.songs,
  });

  @override
  Widget build(BuildContext context) {
    final options = CollectionSort.values
        .where((s) => s.availableIn(scope))
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
            child: Text(o.lineLabel),
          ),
      ],
    );
  }
}
