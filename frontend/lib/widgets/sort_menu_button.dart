import 'package:flutter/material.dart';

import '../utils/collection_sort.dart';
import 'toolbar_icon_button.dart';

/// 内容页排序入口（挂在 CountHeader 右侧，与其它工具条菜单同一实现）。
///
/// 弹窗里每项占一行「字段名 + 方向图标」：
/// - 点整行按 升序 → 降序 → 默认 循环（与表头列头一致）；默认排序项回默认。
/// - 方向图标显示当前方向（未生效字段显示淡化的升序箭头）。
/// - 当前生效的字段+方向用强调色标出，一眼能看到「现在按什么排」。
///
/// 锚点交给 [PopupMenuButton] 按按钮矩形自动计算（与项目其它菜单同一入口），
/// 不再手写 Overlay 坐标。
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

  /// 弹窗展示的字段（取升序代表项，方向由图标表达）。
  List<CollectionSort> get _fields => [
        CollectionSort.defaultOrder,
        CollectionSort.charAsc,
        if (scope == SortScope.songs) ...[
          CollectionSort.artistAsc,
          CollectionSort.albumAsc,
          CollectionSort.weightAsc,
          CollectionSort.playTimeAsc,
          CollectionSort.playCountAsc,
          CollectionSort.durationAsc,
        ] else ...[
          CollectionSort.countAsc,
        ],
      ];

  /// 当前值归到「字段 + 方向」（默认排序没有字段概念，单独处理）。
  (CollectionSort?, bool) get _selected {
    if (value == CollectionSort.defaultOrder) return (null, false);
    return (value.isDesc ? value.flipped : value, value.isDesc);
  }

  @override
  Widget build(BuildContext context) {
    final active = value != CollectionSort.defaultOrder;
    final selected = _selected;
    return ToolbarPopupMenuButton<CollectionSort>(
      icon: Icons.sort,
      tooltip: active ? '排序：${value.lineLabel}' : '排序',
      color: active ? Theme.of(context).colorScheme.primary : null,
      menuColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      menuShape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      // 保持「贴着按钮下沿弹出」（框架默认 over 会盖住按钮）。
      menuPosition: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final f in _fields)
          PopupMenuItem<CollectionSort>(
            value: f == CollectionSort.defaultOrder
                ? CollectionSort.defaultOrder
                : f.nextOnClick(value),
            height: 46,
            child: _SortFieldTile(
              label: f.label,
              plain: f == CollectionSort.defaultOrder,
              active: selected.$1 == f,
              desc: selected.$1 == f && selected.$2,
            ),
          ),
      ],
    );
  }
}

/// 弹窗内一格：字段名 + 单个方向图标（整行都属于 [PopupMenuItem] 的点击区）。
class _SortFieldTile extends StatelessWidget {
  final String label;
  final bool plain;
  final bool active;
  final bool desc;

  const _SortFieldTile({
    required this.label,
    required this.plain,
    required this.active,
    required this.desc,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurface;
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 46,
            alignment: Alignment.centerLeft,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: color,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  ),
            ),
          ),
        ),
        if (!plain)
          _Arrow(
            icon: desc ? Icons.arrow_downward : Icons.arrow_upward,
            active: active,
            color: color,
            tooltip: active ? (desc ? '恢复默认排序' : '切换为降序') : '升序',
          ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color color;
  final String tooltip;

  const _Arrow({
    required this.icon,
    required this.active,
    required this.color,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 34,
        height: 34,
        margin: const EdgeInsets.only(right: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active
              ? Theme.of(context).colorScheme.primaryContainer
              : Colors.transparent,
        ),
        child: Icon(
          icon,
          size: 16,
          color: active
              ? Theme.of(context).colorScheme.onPrimaryContainer
              : color.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}
