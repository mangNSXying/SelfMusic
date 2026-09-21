import 'dart:io';

import 'package:flutter/material.dart';

/// 内容页共用方形卡片（改进 B6-U6）：方形封面 + 标题 + 副标题，
/// 专辑 / 歌手 / 播放源 / 播放列表卡片共用同一套（列表行继续用 SongTile / ListTile）。
class SquareCard extends StatelessWidget {
  /// 四卡片页共用 grid 参数（220 宽 / 16 间距 / 高宽比 0.8 近正方形）。
  static const gridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 220,
    mainAxisSpacing: 16,
    crossAxisSpacing: 16,
    childAspectRatio: 0.8,
  );

  final String title;

  /// 标题最大行数（歌单名较长用 2，其余 1）。
  final int titleMaxLines;
  final String? subtitle;

  /// 封面文件路径；为空时显示 [fallbackIcon] 占位。
  final String? coverPath;
  final IconData fallbackIcon;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// 叠加在封面右上角的小控件（如播放源的设置菜单），无则不叠加。
  final Widget? cornerAction;

  const SquareCard({
    super.key,
    required this.title,
    this.titleMaxLines = 1,
    this.subtitle,
    this.coverPath,
    this.fallbackIcon = Icons.album,
    required this.onTap,
    this.onLongPress,
    this.cornerAction,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sub = subtitle;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: coverPath != null
                      ? Image.file(File(coverPath!),
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Icon(fallbackIcon,
                              size: 48,
                              color:
                                  colorScheme.primary.withValues(alpha: 0.6)))
                      : Icon(fallbackIcon,
                          size: 48,
                          color: colorScheme.primary.withValues(alpha: 0.6)),
                ),
                if (cornerAction != null)
                  Positioned(top: 2, right: 2, child: cornerAction!),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(title,
              maxLines: titleMaxLines,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          if (sub != null)
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurface.withValues(alpha: 0.6))),
        ],
      ),
    );
  }
}
