import 'package:flutter/material.dart';

/// 多选勾选标记：叠在行首（封面/图标）左上角，列表行与方形卡片共用同一形态。
///
/// 半透明圆形底衬保证叠在封面上也能看清勾；紧凑尺寸（`shrinkWrap` + 紧凑视觉密度）
/// 与 44×44 封面叠放不喧宾夺主。点击标记与点击整行等效（都切换本项选中）。
/// [selected] 为 null 时显示三态半选（组/文件夹只选中部分歌曲）。
class SelectionBadge extends StatelessWidget {
  /// `true` 全选、`false` 未选、`null` 半选（组/文件夹的部分歌曲被选中）。
  final bool? selected;
  final VoidCallback? onTap;
  const SelectionBadge({super.key, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Material(
        color: cs.surface.withValues(alpha: 0.85),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: Checkbox(
          tristate: selected == null,
          value: selected,
          onChanged: (_) => onTap?.call(),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          shape: const CircleBorder(),
        ),
      ),
    );
  }
}
