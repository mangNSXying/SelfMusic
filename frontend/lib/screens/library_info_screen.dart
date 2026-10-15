import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../providers/direct_source_manager.dart';
import '../services/artist_resolver.dart';
import '../utils/build_stamp.dart';
import '../utils/play_stats.dart';
import 'library_info_extra_details.dart';
import 'library_info_meta_detail.dart';
import 'library_info_play_detail.dart';

/// 侧边栏「歌曲信息」页：汇总全部歌曲的元数据读取情况 + 播放数据。
/// 口径见 [LocalIndex.metaStats] / [LocalIndex.playOverview]。
class LibraryInfoScreen extends StatelessWidget {
  const LibraryInfoScreen({super.key});

  static const _dims = [
    ('meta_read', '已读元数据'),
    ('artist', '歌手'),
    ('album', '专辑'),
    ('album_artist', '专辑歌手'),
    ('genre', '流派'),
    ('track_no', '曲目号'),
    ('year', '年份'),
    ('duration', '时长'),
    ('cover', '专辑封面'),
    ('lyrics', '歌词'),
    ('format', '格式'),
    ('bitrate', '码率（大小+时长估算）'),
  ];

  @override
  Widget build(BuildContext context) {
    final index = context.watch<DirectSourceManager>().index;
    // 歌手解析进度实时跟随（后台循环/人工绑定完成即刷新）。
    context.watch<ArtistResolver>();
    final stats = index.metaStats();
    final formats = index.formatStats();
    final artistStats = index.artistStats();
    final play = index.playOverview();
    final total = stats['total'] ?? 0;
    final valid = total - (stats['missing'] ?? 0);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('歌曲信息总览')),
      body: valid <= 0
          ? const Center(child: Text('暂无歌曲，先去播放源页扫描'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _SummaryCard(
                    total: total,
                    valid: valid,
                    missing: stats['missing'] ?? 0,
                    read: stats['meta_read'] ?? 0),
                if (kBuildStamp.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('构建：$kBuildStamp',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.6))),
                  ),
                const SizedBox(height: 12),
                _SectionHeader(
                  title: '元数据信息',
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const MetaDetailScreen())),
                ),
                const SizedBox(height: 4),
                for (final d in _dims)
                  _DimRow(
                      label: d.$2,
                      got: stats[d.$1] ?? 0,
                      total: valid,
                      accent: cs.primary),
                const SizedBox(height: 12),
                _SectionHeader(
                  title: '歌手信息',
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const ArtistDetailScreen())),
                ),
                const SizedBox(height: 4),
                _ArtistStatusRow(artistStats),
                const SizedBox(height: 12),
                _SectionHeader(
                  title: '格式分布',
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const FormatDetailScreen())),
                ),
                const SizedBox(height: 4),
                for (final e in formats.entries)
                  _DimRow(
                      label: e.key.isEmpty ? '未知' : e.key,
                      got: e.value,
                      total: valid,
                      accent: cs.primary),
                const SizedBox(height: 12),
                _SectionHeader(
                  title: '播放数据',
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const PlayDetailScreen())),
                ),
                const SizedBox(height: 4),
                _PlayOverviewCard(play: play),
                const SizedBox(height: 8),
                Text('按播放次数',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.6))),
                _DimRow(
                    label: '未播放',
                    got: play.countZero,
                    total: valid,
                    accent: cs.primary),
                _DimRow(
                    label: '小于 1 次',
                    got: play.countLt1,
                    total: valid,
                    accent: cs.primary),
                _DimRow(
                    label: '1-5 次',
                    got: play.count1to5,
                    total: valid,
                    accent: cs.primary),
                _DimRow(
                    label: '大于 5 次',
                    got: play.countGt5,
                    total: valid,
                    accent: cs.primary),
                const SizedBox(height: 4),
                Text('按播放时长',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.6))),
                _DimRow(
                    label: '未播放',
                    got: play.secZero,
                    total: valid,
                    accent: cs.primary),
                _DimRow(
                    label: '10 分钟以内',
                    got: play.secLt10m,
                    total: valid,
                    accent: cs.primary),
                _DimRow(
                    label: '10 分钟-1 小时',
                    got: play.sec10mTo1h,
                    total: valid,
                    accent: cs.primary),
                _DimRow(
                    label: '1 小时以上',
                    got: play.secGt1h,
                    total: valid,
                    accent: cs.primary),
              ],
            ),
    );
  }
}

/// 总览页分区标题：右侧 `>` 点击进入对应详情页。
class _SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback onTap;
  const _SectionHeader({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const Spacer(),
            Icon(Icons.chevron_right,
                size: 20,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}

/// 播放数据总览卡：累计次数/时长 + 有记录歌曲数。
class _PlayOverviewCard extends StatelessWidget {
  final PlayOverview play;
  const _PlayOverviewCard({required this.play});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = play.total;
    final withPlay = play.withPlay;
    final totalSec = play.totalSec;
    final totalCount = play.totalCount;
    final pct = total <= 0 ? 0.0 : withPlay / total;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '累计 ${totalCount.toStringAsFixed(1)} 次 · ${playSecLabel(totalSec)}',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pct),
            const SizedBox(height: 4),
            Text(
              '有播放记录 $withPlay / $total 首 · ${(pct * 100).toStringAsFixed(0)}%',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final int total;
  final int valid;
  final int missing;
  final int read;
  const _SummaryCard(
      {required this.total,
      required this.valid,
      required this.missing,
      required this.read});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = valid <= 0 ? 0.0 : read / valid;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('共 $total 首（有效 $valid 首${missing > 0 ? '，失效 $missing 首' : ''}）',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: pct),
            const SizedBox(height: 4),
            Text('已读元数据 $read 首 · ${(pct * 100).toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6))),
          ],
        ),
      ),
    );
  }
}

class _DimRow extends StatelessWidget {
  final String label;
  final int got;
  final int total;
  final Color accent;
  const _DimRow(
      {required this.label,
      required this.got,
      required this.total,
      required this.accent});

  @override
  Widget build(BuildContext context) {
    final pct = total <= 0 ? 0.0 : (got / total).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
              width: 150,
              child: Text(label, style: Theme.of(context).textTheme.bodyMedium)),
          Expanded(
            child: LinearProgressIndicator(
                value: pct,
                backgroundColor: accent.withValues(alpha: 0.15)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: Text('$got / $total',
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// 歌手身份解析进度（歌手处理.txt）：状态分布 + 歌曲映射覆盖率。
class _ArtistStatusRow extends StatelessWidget {
  final Map<String, int> s;
  const _ArtistStatusRow(this.s);

  @override
  Widget build(BuildContext context) {
    final total = s['total'] ?? 0;
    if (total <= 0) {
      return const Text('暂无歌手数据');
    }
    final mapped = s['mapped'] ?? 0;
    final withArtist = s['withArtist'] ?? 0;
    final cs = Theme.of(context).colorScheme;
    final pct = withArtist <= 0 ? 0.0 : (mapped / withArtist).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _chip(context, '已解析 ${s['resolved'] ?? 0}', cs.primary),
                const SizedBox(width: 6),
                _chip(context, '待确认 ${s['ambiguous'] ?? 0}', Colors.orange),
                const SizedBox(width: 6),
                _chip(context, '未命中 ${s['local'] ?? 0}',
                    cs.onSurfaceVariant),
                const SizedBox(width: 6),
                _chip(context, '待解析 ${s['pending'] ?? 0}', cs.outline),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                _chip(context, '成员 ${s['members'] ?? 0} 条', cs.primary),
                const SizedBox(width: 6),
                _chip(context, '已展开 ${s['expanded'] ?? 0} 个组合',
                    cs.onSurfaceVariant),
                const SizedBox(width: 6),
                // 展开不出成员的身份：歌手页回落显示组合本身（如纯创作歌手）。
                _chip(context, '回落组合 ${s['fallback'] ?? 0}', cs.outline),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: pct),
            const SizedBox(height: 4),
            Text('歌曲映射 $mapped / $withArtist 首 · ${(pct * 100).toStringAsFixed(0)}%',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6))),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: color)),
      );
}
