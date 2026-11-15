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

/// 歌手身份卡：状态占比 + 映射覆盖率。
class _ArtistCard extends StatelessWidget {
  final Map<String, int> stats;

  const _ArtistCard({required this.stats});

  @override
  Widget build(BuildContext context) {
    final total = stats['total'] ?? 0;
    final mapped = stats['mapped'] ?? 0;
    final withArtist = stats['withArtist'] ?? 0;
    final statusItems = [
      CoverageItem(
        '已解析',
        stats['resolved'] ?? 0,
        valueLabel: infoCountLabel(stats['resolved'] ?? 0, total, '个'),
      ),
      CoverageItem(
        '待确认',
        stats['ambiguous'] ?? 0,
        valueLabel: infoCountLabel(stats['ambiguous'] ?? 0, total, '个'),
      ),
      CoverageItem(
        '未命中',
        stats['local'] ?? 0,
        valueLabel: infoCountLabel(stats['local'] ?? 0, total, '个'),
      ),
      CoverageItem(
        '待解析',
        stats['pending'] ?? 0,
        valueLabel: infoCountLabel(stats['pending'] ?? 0, total, '个'),
      ),
    ];

    final content = total <= 0
        ? const Text('暂无歌手数据')
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CoverageGrid(
                items: statusItems,
                total: total,
                lowIsBad: false,
              ),
              const SizedBox(height: 10),
              CoverageCell(
                label: '歌曲映射',
                got: mapped,
                total: withArtist,
                valueLabel: '$mapped / $withArtist 首 · '
                    '${infoPercent(mapped, withArtist)}',
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

/// 格式分布卡：Top 5 + 其他 的条状展示。
class _FormatCard extends StatelessWidget {
  final Map<String, int> formats;

  const _FormatCard({required this.formats});

  @override
  Widget build(BuildContext context) {
    final entries = formats.entries.toList();
    final top = entries.take(5).toList();
    final rest =
        entries.skip(5).fold<int>(0, (sum, entry) => sum + entry.value);
    final total = entries.fold<int>(0, (sum, entry) => sum + entry.value);
    final items = [
      for (final entry in top)
        CoverageItem(
          entry.key.isEmpty ? '未知' : entry.key,
          entry.value,
          valueLabel: infoCountLabel(entry.value, total, '首'),
        ),
      if (rest > 0)
        CoverageItem(
          '其他',
          rest,
          valueLabel: infoCountLabel(rest, total, '首'),
        ),
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
          : CoverageGrid(items: items, total: total, lowIsBad: false),
    );
  }
}

/// 播放数据卡：累计值 + 次数/时长两条条状分布。
class _PlayCard extends StatelessWidget {
  final PlayOverview play;

  const _PlayCard({required this.play});

  @override
  Widget build(BuildContext context) {
    final total = play.total;
    final countItems = [
      CoverageItem(
        '未播放',
        play.countZero,
        valueLabel: infoCountLabel(play.countZero, total, '首'),
      ),
      CoverageItem(
        '小于 1 次',
        play.countLt1,
        valueLabel: infoCountLabel(play.countLt1, total, '首'),
      ),
      CoverageItem(
        '1-5 次',
        play.count1to5,
        valueLabel: infoCountLabel(play.count1to5, total, '首'),
      ),
      CoverageItem(
        '大于 5 次',
        play.countGt5,
        valueLabel: infoCountLabel(play.countGt5, total, '首'),
      ),
    ];
    final secItems = [
      CoverageItem(
        '未播放',
        play.secZero,
        valueLabel: infoCountLabel(play.secZero, total, '首'),
      ),
      CoverageItem(
        '10 分钟以内',
        play.secLt10m,
        valueLabel: infoCountLabel(play.secLt10m, total, '首'),
      ),
      CoverageItem(
        '10 分钟-1 小时',
        play.sec10mTo1h,
        valueLabel: infoCountLabel(play.sec10mTo1h, total, '首'),
      ),
      CoverageItem(
        '1 小时以上',
        play.secGt1h,
        valueLabel: infoCountLabel(play.secGt1h, total, '首'),
      ),
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
          CoverageCell(
            label: '有播放记录',
            got: play.withPlay,
            total: total,
            lowIsBad: false,
            valueLabel: '${play.withPlay} / $total 首 · '
                '${infoPercent(play.withPlay, total)}',
          ),
          const SizedBox(height: 12),
          _DistributionGroup(
            title: '按播放次数',
            items: countItems,
            total: total,
          ),
          const SizedBox(height: 12),
          _DistributionGroup(
            title: '按播放时长',
            items: secItems,
            total: total,
          ),
        ],
      ),
    );
  }
}

class _DistributionGroup extends StatelessWidget {
  final String title;
  final List<CoverageItem> items;
  final int total;

  const _DistributionGroup({
    required this.title,
    required this.items,
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
        CoverageGrid(items: items, total: total, lowIsBad: false),
      ],
    );
  }
}
