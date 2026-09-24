import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 内容页共用方形卡片（改进 B6-U6）：封面恒为正方形 + 标题 + 副标题，
/// 专辑 / 歌手 / 播放源 / 歌单卡片共用（列表行继续用 SongTile / ListTile）。
class SquareCard extends StatelessWidget {
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
        mainAxisSize: MainAxisSize.min,
        children: [
          // 封面恒定 1:1（宽高比由 SquareCardGrid 的行高保证恰好放下文本）。
          AspectRatio(
            aspectRatio: 1,
            // StackFit.expand：无封面时占位底色也必须撑满正方形
            //（默认 loose 会让 Container 高度只由图标决定，显示成矮长条）。
            child: Stack(
              fit: StackFit.expand,
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
                          // 卡片最大 220 宽：按 ~2× 目标尺寸降采样解码，避免网格全分辨率尖峰。
                          cacheWidth: 440,
                          cacheHeight: 440,
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

/// 方形卡片网格：按可用宽度计算列数与行高，保证每张卡片的封面恰为正方形
///（固定 childAspectRatio 会在窄列时把封面压成长方形——改进反馈 #3）。
class SquareCardGrid extends StatelessWidget {
  /// 单项最大宽度（与旧 maxCrossAxisExtent 语义一致）。
  static const double maxItemWidth = 220;
  static const double gap = 16;
  static const double sidePadding = 16;

  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;

  /// 标题最大行数（与卡片保持一致，用于估算文本高度）。
  final int titleMaxLines;

  const SquareCardGrid({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.titleMaxLines = 1,
  });

  /// 卡片底部文本区高度（间距 + 标题 + 副标题），带少量余量防溢出。
  double _textHeight(BuildContext context) {
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    double line(TextStyle? s) {
      final size = s?.fontSize ?? 14;
      return scaler.scale(size) * (s?.height ?? 1.3);
    }

    return 8 +
        line(theme.textTheme.bodyMedium) * titleMaxLines +
        line(theme.textTheme.bodySmall) +
        6;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = math.max(0.0, constraints.maxWidth - sidePadding * 2);
        final cols = math.max(
            1, ((avail + gap) / (maxItemWidth + gap)).ceil());
        final itemW = (avail - (cols - 1) * gap) / cols;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(sidePadding, 0, sidePadding, 16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            mainAxisExtent: itemW + _textHeight(context),
          ),
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        );
      },
    );
  }
}
