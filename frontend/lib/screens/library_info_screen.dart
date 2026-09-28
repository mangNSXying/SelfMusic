import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/direct_source_manager.dart';
import '../services/artist_resolver.dart';
import '../utils/build_stamp.dart';

/// 侧边栏「信息」页（改进 B6-4）：汇总全部歌曲的元数据读取情况。
/// 口径见 [LocalIndex.metaStats]：总数/已读/失效 + 各维度已获取数 + 格式分组。
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
                Text('各维度已获取',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final d in _dims)
                  _DimRow(
                      label: d.$2,
                      got: stats[d.$1] ?? 0,
                      total: valid,
                      accent: cs.primary),
                const SizedBox(height: 12),
                Text('歌手身份',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _ArtistStatusRow(artistStats),
                const SizedBox(height: 12),
                Text('格式分布',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                for (final e in formats.entries)
                  _DimRow(
                      label: e.key.isEmpty ? '未知' : e.key,
                      got: e.value,
                      total: valid,
                      accent: cs.primary),
              ],
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
