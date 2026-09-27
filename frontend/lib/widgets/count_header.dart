import 'package:flutter/material.dart';

import 'row_list.dart';

/// 内容页共用计数头（改进 B6-U5 / 效果修复）：图标 + 「共 N …」一行。
///
/// 歌曲 / 喜欢 / 歌单详情 / 专辑 / 歌手 / 歌单 / 播放源共用同一套；
/// 样式对齐设计稿（UI-mobile「♪ 共 36 首」）：正文级字号 + 次要前景色，
/// 不用浅灰小字；右侧可挂 [trailing]（列表/卡片切换按钮）。
class CountHeader extends StatelessWidget {
  final int count;

  /// 量词：'首' / '张' / '位' / '个歌单' / '个播放源'。
  final String unit;

  /// 行尾控件（如 ViewModeToggle）；为空时右侧留常规内边距。
  final Widget? trailing;

  const CountHeader({
    super.key,
    required this.count,
    this.unit = '首',
    this.trailing,
  });

  String get _label => switch (unit) {
        '张' => '共 $count 张专辑',
        '位' => '共 $count 位歌手',
        '个歌单' => '共 $count 个歌单',
        '个播放源' => '共 $count 个播放源',
        _ => '共 $count 首歌曲',
      };

  IconData get _icon => switch (unit) {
        '张' => Icons.album,
        '位' => Icons.person_outline,
        '个歌单' => Icons.queue_music,
        '个播放源' => Icons.storage,
        _ => Icons.music_note,
      };

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    // 总高与多选栏一致（[kListHeaderHeight]）：进出多选模式时下方内容不跳动。
    const inner = kListHeaderHeight - 12;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 6, trailing == null ? 16 : 8, 6),
      child: SizedBox(
        height: inner,
        child: Row(
          children: [
            Icon(_icon, size: 17, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: muted),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
