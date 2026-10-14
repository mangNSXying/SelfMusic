import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../utils/duration_format.dart';
import '../utils/play_stats.dart';
import '../utils/url_display.dart';

/// 歌曲信息弹窗：标题/歌手/专辑/流派/年份/时长/格式/来源/权重/收藏态
/// ＋播放次数/播放时长/码率。
///
/// 播放页封面「更多」与歌曲列表行三点菜单共用。
class SongInfoDialog extends StatelessWidget {
  final Song song;
  const SongInfoDialog({super.key, required this.song});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final states = <String>[];
    if (song.isDirect) {
      if (direct.weight.isFavorite(song)) states.add('喜欢');
      if (direct.weight.isDisliked(song)) states.add('不喜欢');
    }
    // 元数据字段：未读取 → 标注「待读取」；已读取且无值 → 留白（—）。
    String? optField(String? v) => song.metaDisplay(v);
    // 路径：优先由对应直连源解析真实可读路径（本地绝对路径/WebDAV URL/UNC），
    // 源不在本机时回落到持久化完整 URL 或源内引用；URL 百分号编码展示时解码。
    final displayPath = direct.sourceByKey(song.sourceKey)?.displayPath(song) ??
        decodeUrlForDisplay(song.sourceUrl ?? song.sourceRef);
    // 播放统计：累计秒数→时长文案＋派生次数（play_stats 口径）。
    final playSec = direct.weight.playSecOf(song);
    // 码率：fileSize×8/时长（与宽行技术信息同口径；时长未知时省略）。
    String? bitrate;
    if (song.metaUnread) {
      bitrate = Song.unreadLabel;
    } else if (song.fileSize > 0 &&
        song.duration != null &&
        song.duration! > 0) {
      bitrate = '${(song.fileSize * 8 / 1024 / song.duration!).round()} kbps';
    }
    final rows = <List<String>>[
      ['标题', song.title],
      ['歌手', optField(song.artist) ?? '—'],
      ['专辑歌手', optField(song.albumArtist) ?? '—'],
      ['专辑', optField(song.albumName) ?? '—'],
      if (song.metaUnread || (song.genre != null && song.genre!.isNotEmpty))
        ['流派', song.metaUnread ? Song.unreadLabel : song.genre!],
      if (song.metaUnread || song.year != null)
        ['年份', song.metaUnread ? Song.unreadLabel : '${song.year}'],
      if (song.metaUnread ||
          (song.duration != null && song.duration! > 0))
        ['时长',
            song.metaUnread ? Song.unreadLabel : formatDuration(song.duration)],
      if (song.format != null) ['格式', song.format!.toUpperCase()],
      if (bitrate != null) ['码率', bitrate],
      ['播放时长', playSecLabel(playSec)],
      ['播放次数', playCountLabel(playSec, song.duration)],
      ['来源', '${song.source}（${song.sourceKey}）'],
      ['路径', displayPath],
      if (song.isDirect)
        ['权重', direct.weight.factorOf(song).toStringAsFixed(1)],
      if (song.isDirect) ['状态', states.isEmpty ? '—' : states.join(' · ')],
    ];
    return AlertDialog(
      title: const Text('歌曲信息'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(r[0],
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.6))),
                      ),
                      Expanded(child: Text(r[1])),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
