import 'package:flutter/material.dart';

import '../utils/collection_sort.dart';
import 'toolbar_icon_button.dart';

/// 内容页排序入口（挂在 CountHeader 右侧）。
///
/// 弹窗里每项占一行的「字段名 + 方向按钮」（改进.txt）：
/// - 点字段名或方向按钮都走同一循环：升序 → 降序 → 默认（与表头列头一致）；
///   默认排序项无方向，点它即回默认。
/// - 方向按钮显示当前方向（未生效字段显示淡化的升序箭头）。
/// - 当前生效的字段+方向用强调色标出，一眼能看到「现在按什么排」。
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

  /// 弹窗展示的字段（取升序代表项，方向由箭头表达）。
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

  Future<void> _open(BuildContext context) async {
    final selected = _selected;
    final picked = await showMenu<CollectionSort>(
      context: context,
      // 贴着按钮弹出并右对齐（sort 图标在标题栏右侧，居中会跳到屏幕中间）。
      position: _anchorRect(context),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      items: [
        for (final f in _fields)
          PopupMenuItem<CollectionSort>(
            // 值由子控件的箭头/字段点击显式 pop 决定，这里不参与返回值。
            value: null,
            height: 46,
            child: _SortFieldTile(
              label: f.label,
              plain: f == CollectionSort.defaultOrder,
              active: selected.$1 == f,
              desc: selected.$1 == f && selected.$2,
              onTap: () => _pick(
                context,
                f == CollectionSort.defaultOrder
                    ? CollectionSort.defaultOrder
                    : f.nextOnClick(value),
              ),
            ),
          ),
      ],
    );
    if (picked != null) onChanged(picked);
  }

  /// 弹窗锚点：以按钮下沿为顶、右侧对齐的窄矩形（宽度够放下最长字段名）。
  static RelativeRect _anchorRect(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null || !box.hasSize || !box.attached) {
      return const RelativeRect.fromLTRB(0, 0, 200, 400);
    }
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    const width = 190.0;
    final left = (origin.dx + box.size.width - width).clamp(8.0, overlay.size.width - 8.0);
    return RelativeRect.fromLTRB(left, origin.dy + box.size.height, left + width,
        overlay.size.height);
  }

  void _pick(BuildContext context, CollectionSort v) {
    Navigator.of(context, rootNavigator: true).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final active = value != CollectionSort.defaultOrder;
    return Builder(
      builder: (ctx) => ToolbarIconButton(
        tooltip: active ? '排序：${value.lineLabel}' : '排序',
        icon: Icons.sort,
        color: active ? Theme.of(ctx).colorScheme.primary : null,
        onPressed: () => _open(ctx),
      ),
    );
  }
}

/// 弹窗内一格：字段名 + 升/降箭头（当前生效的加强调色）。
class _SortFieldTile extends StatelessWidget {
  final String label;
  final bool plain;
  final bool active;
  final bool desc;
  final VoidCallback onTap;

  const _SortFieldTile({
    required this.label,
    required this.plain,
    required this.active,
    required this.desc,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = active ? scheme.primary : scheme.onSurface;
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onTap,
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
        ),
        if (!plain)
          _Arrow(
            icon: desc ? Icons.arrow_downward : Icons.arrow_upward,
            active: active,
            color: color,
            tooltip: active ? (desc ? '恢复默认排序' : '切换为降序') : '升序',
            onTap: onTap,
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
  final VoidCallback onTap;

  const _Arrow({
    required this.icon,
    required this.active,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
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
      ),
    );
  }
}
