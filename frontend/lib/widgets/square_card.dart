import 'dart:io';

import 'package:flutter/material.dart';

/// 内容页共用方形卡片（改进 B6-U6）：方形封面 + 标题 + 副标题，
/// 专辑 / 歌手 / 播放源卡片共用同一套（列表行继续用 SongTile / ListTile）。
class SquareCard extends StatelessWidget {
  final String title;
  final String? subtitle;

  /// 封面文件路径；为空时显示 [fallbackIcon] 占位。
  final String? coverPath;
  final IconData fallbackIcon;
  final VoidCallback onTap;

  /// 叠加在封面右上角的小控件（如播放源的设置菜单），无则不叠加。
  final Widget? cornerAction;

  const SquareCard({
    super.key,
    required this.title,
    this.subtitle,
    this.coverPath,
    this.fallbackIcon = Icons.album,
    required this.onTap,
    this.cornerAction,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final sub = subtitle;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
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
              maxLines: 1,
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
