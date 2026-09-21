import 'package:flutter/material.dart';

/// 内容页共用计数头（改进 B6-U5）：顶部「共 N 首歌曲 / 张专辑 / 位歌手」一行，
/// 歌曲/喜欢/歌单详情/专辑/歌手各内容页共用同一套。
class CountHeader extends StatelessWidget {
  final int count;

  /// 量词：歌曲页 '首'，专辑页 '张'，歌手页 '位'。
  final String unit;

  /// 内边距（嵌入已有行内时传 [EdgeInsets.zero]，由外层负责）。
  final EdgeInsetsGeometry padding;

  const CountHeader(
      {super.key, required this.count, this.unit = '首', this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 4)});

  String get _label => switch (unit) {
        '张' => '共 $count 张专辑',
        '位' => '共 $count 位歌手',
        _ => '共 $count 首歌曲',
      };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Text(
        _label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context)
                .colorScheme
                .onSurface
                .withValues(alpha: 0.6)),
      ),
    );
  }
}
