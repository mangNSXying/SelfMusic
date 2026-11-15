import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/local/local_index.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/navigation_provider.dart';
import '../../services/artist_resolver.dart';
import '../../utils/build_stamp.dart';
import '../../utils/play_stats.dart';
import 'detail_shared.dart';

/// 总览的元数据维度（「已读元数据」进入概览 KPI，不重复列在这里）。
const _overviewDims = <(String, String)>[
  ('artist', '歌手'),
  ('album', '专辑'),
  ('album_artist', '专辑歌手'),
  ('genre', '流派'),
  ('track_no', '曲目号'),
  ('year', '年份'),
  ('duration', '时长'),
  ('cover', '封面'),
  ('lyrics', '歌词'),
  ('format', '格式'),
  ('bitrate', '码率'),
];

/// 侧边栏「歌曲信息」总览：曲库概览 + 元数据 / 歌手 / 格式 / 播放四张分区卡。
/// 口径见 [LocalIndex.metaStats] / [LocalIndex.playOverview]。
class LibraryInfoScreen extends StatelessWidget {
  const LibraryInfoScreen({super.key});

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
    final missing = stats['missing'] ?? 0;
    final valid = total - missing;
    if (valid <= 0) {
      return const Center(child: Text('暂无歌曲，先去播放源页扫描'));
    }

    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          math.min(constraints.maxWidth, kInfoContentMaxWidth) - 32,
        );
        final twoCol = available >= kInfoTwoColumnMinWidth;
        final half = (available - kInfoCardGap) / 2;

        final metaCard = _MetadataCard(stats: stats, valid: valid);
        final artistCard = _ArtistCard(stats: artistStats);
        final formatCard = _FormatCard(formats: formats);
        final playCard = _PlayCard(play: play);

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kInfoContentMaxWidth),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                _OverviewHero(
                  total: total,
                  valid: valid,
                  missing: missing,
                  read: stats['meta_read'] ?? 0,
                  cover: stats['cover'] ?? 0,
                  lyrics: stats['lyrics'] ?? 0,
                ),
                const SizedBox(height: kInfoCardGap),
                if (twoCol) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: half, child: metaCard),
                      const SizedBox(width: kInfoCardGap),
                      SizedBox(width: half, child: artistCard),
                    ],
                  ),
                  const SizedBox(height: kInfoCardGap),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: half, child: formatCard),
                      const SizedBox(width: kInfoCardGap),
                      SizedBox(width: half, child: playCard),
                    ],
                  ),
                ] else ...[
                  metaCard,
                  const SizedBox(height: kInfoCardGap),
                  artistCard,
                  const SizedBox(height: kInfoCardGap),
                  formatCard,
                  const SizedBox(height: kInfoCardGap),
                  playCard,
                ],
                if (kBuildStamp.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '构建：$kBuildStamp',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 曲库概览 KPI 卡。
class _OverviewHero extends StatelessWidget {
  final int total;
  final int valid;
  final int missing;
  final int read;
  final int cover;
  final int lyrics;

  const _OverviewHero({
    required this.total,
    required this.valid,
    required this.missing,
    required this.read,
    required this.cover,
    required this.lyrics,
  });

  @override
  Widget build(BuildContext context) {
    return InfoCard(
      title: '曲库概览',
      child: LayoutBuilder(
        builder: (context, c) {
          const gap = 16.0;
          final cols = c.maxWidth >= 560 ? 4 : 2;
          final width = (c.maxWidth - gap * (cols - 1)) / cols - 0.5;
          return Wrap(
            spacing: gap,
            runSpacing: 16,
            children: [
              SizedBox(
                width: width,
                child: StatTile(
                  label: '曲目总数',
                  value: '$total',
                  hint: missing > 0 ? '有效 $valid · 失效 $missing' : '有效 $valid',
                ),
              ),
              SizedBox(
                width: width,
                child: StatTile(
                  label: '元数据已读',
                  value: infoPercent(read, valid),
                  hint: '$read / $valid 首',
                ),
              ),
              SizedBox(
                width: width,
                child: StatTile(
                  label: '有封面',
                  value: infoPercent(cover, valid),
                  hint: '$cover 首',
                ),
              ),
              SizedBox(
                width: width,
                child: StatTile(
                  label: '有歌词',
                  value: infoPercent(lyrics, valid),
                  hint: '$lyrics 首',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 元数据覆盖卡：11 个维度的紧凑网格。
class _MetadataCard extends StatelessWidget {
  final Map<String, int> stats;
  final int valid;

  const _MetadataCard({required this.stats, required this.valid});

  @override
  Widget build(BuildContext context) {
    final items = [
      for (final dim in _overviewDims) CoverageItem(dim.$2, stats[dim.$1] ?? 0),
    ];
    return InfoCard(
      title: '元数据覆盖',
      subtitle: '有效 $valid 首',
      trailing: const InfoCardLink(),
      onTap: () => context
          .read<NavigationProvider>()
          .openLibraryInfo(LibraryInfoPage.meta),
      child: CoverageGrid(items: items, total: valid),
    );
  }
}

/// 歌手身份卡：状态占比 + 映射覆盖率 + 关系进度。
class _ArtistCard extends StatelessWidget {
  final Map<String, int> stats;

  const _ArtistCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = stats['total'] ?? 0;
    final mapped = stats['mapped'] ?? 0;
    final withArtist = stats['withArtist'] ?? 0;
    final pct = withArtist <= 0 ? 0.0 : (mapped / withArtist).clamp(0.0, 1.0);
    final segments = [
      ShareSegment('已解析', stats['resolved'] ?? 0, cs.primary),
      ShareSegment('待确认', stats['ambiguous'] ?? 0, cs.tertiary),
      ShareSegment('未命中', stats['local'] ?? 0, cs.secondary),
      ShareSegment('待解析', stats['pending'] ?? 0, cs.outlineVariant),
    ];

    final content = total <= 0
        ? const Text('暂无歌手数据')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShareBar(segments: segments),
              const SizedBox(height: 10),
              ShareLegend(segments: segments, total: total),
              const SizedBox(height: 10),
              Text(
                '歌曲映射 $mapped / $withArtist 首 · '
                '${(pct * 100).toStringAsFixed(0)}%',
                style: text.bodySmall,
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 4,
                  backgroundColor: cs.primary.withValues(alpha: 0.12),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '成员 ${stats['members'] ?? 0} 条 · '
                '已展开 ${stats['expanded'] ?? 0} 个 · '
                '回落 ${stats['fallback'] ?? 0} 个',
                style: text.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          );

    return InfoCard(
      title: '歌手身份',
      subtitle: total <= 0 ? null : '共 $total 个身份',
      trailing: const InfoCardLink(),
      onTap: () => context
          .read<NavigationProvider>()
          .openLibraryInfo(LibraryInfoPage.artists),
      child: content,
    );
  }
}

/// 格式分布卡：Top 5 + 其他 的堆叠条与图例。
class _FormatCard extends StatelessWidget {
  final Map<String, int> formats;

  const _FormatCard({required this.formats});

  @override
  Widget build(BuildContext context) {
    final entries = formats.entries.toList();
    final cs = Theme.of(context).colorScheme;
    final palette = sharePalette(cs);
    final top = entries.take(5).toList();
    final rest =
        entries.skip(5).fold<int>(0, (sum, entry) => sum + entry.value);
    final total = entries.fold<int>(0, (sum, entry) => sum + entry.value);
    final segments = [
      for (var i = 0; i < top.length; i++)
        ShareSegment(
          top[i].key.isEmpty ? '未知' : top[i].key,
          top[i].value,
          palette[i % palette.length],
        ),
      if (rest > 0) ShareSegment('其他', rest, cs.outlineVariant),
    ];

    return InfoCard(
      title: '格式分布',
      subtitle: entries.isEmpty ? null : '${entries.length} 种格式',
      trailing: const InfoCardLink(),
      onTap: () => context
          .read<NavigationProvider>()
          .openLibraryInfo(LibraryInfoPage.formats),
      child: entries.isEmpty
          ? const Text('暂无格式数据')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShareBar(segments: segments),
                const SizedBox(height: 10),
                for (final segment in segments)
                  _LegendRow(segment: segment, total: total),
              ],
            ),
    );
  }
}

/// 播放数据卡：累计值 + 次数/时长两条分布。
class _PlayCard extends StatelessWidget {
  final PlayOverview play;

  const _PlayCard({required this.play});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = play.total;
    final pct = total <= 0 ? 0.0 : (play.withPlay / total).clamp(0.0, 1.0);
    final countSegments = [
      ShareSegment('未播放', play.countZero, cs.outlineVariant),
      ShareSegment('小于 1 次', play.countLt1, cs.primary.withValues(alpha: 0.35)),
      ShareSegment('1-5 次', play.count1to5, cs.primary.withValues(alpha: 0.65)),
      ShareSegment('大于 5 次', play.countGt5, cs.primary),
    ];
    final secSegments = [
      ShareSegment('未播放', play.secZero, cs.outlineVariant),
      ShareSegment(
          '10 分钟以内', play.secLt10m, cs.primary.withValues(alpha: 0.35)),
      ShareSegment(
          '10 分钟-1 小时', play.sec10mTo1h, cs.primary.withValues(alpha: 0.65)),
      ShareSegment('1 小时以上', play.secGt1h, cs.primary),
    ];

    return InfoCard(
      title: '播放数据',
      subtitle: '累计 ${play.totalCount.toStringAsFixed(1)} 次 · '
          '${playSecLabel(play.totalSec)}',
      trailing: const InfoCardLink(),
      onTap: () => context
          .read<NavigationProvider>()
          .openLibraryInfo(LibraryInfoPage.play),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '有播放记录 ${play.withPlay} / $total 首 · '
            '${(pct * 100).toStringAsFixed(0)}%',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
          ),
          const SizedBox(height: 10),
          _MiniDistribution(
            title: '按播放次数',
            segments: countSegments,
            total: total,
          ),
          const SizedBox(height: 12),
          _MiniDistribution(
            title: '按播放时长',
            segments: secSegments,
            total: total,
          ),
        ],
      ),
    );
  }
}

class _MiniDistribution extends StatelessWidget {
  final String title;
  final List<ShareSegment> segments;
  final int total;

  const _MiniDistribution({
    required this.title,
    required this.segments,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.55),
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 6),
        ShareBar(segments: segments, height: 8),
        const SizedBox(height: 6),
        ShareLegend(segments: segments, total: total),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  final ShareSegment segment;
  final int total;

  const _LegendRow({required this.segment, required this.total});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final pct = total <= 0 ? 0.0 : segment.value / total;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: segment.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              segment.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${segment.value} 首 · ${(pct * 100).toStringAsFixed(0)}%',
            style: text.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}
