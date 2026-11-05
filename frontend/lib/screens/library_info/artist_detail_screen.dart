import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../providers/direct_source_manager.dart';

/// 歌曲信息 → 歌手详情：放大版统计（与总览页同口径）。
class ArtistDetailScreen extends StatelessWidget {
  const ArtistDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final index = context.watch<DirectSourceManager>().index;
    final s = index.artistStats();
    final cs = Theme.of(context).colorScheme;
    final total = s['total'] ?? 0;
    final mapped = s['mapped'] ?? 0;
    final withArtist = s['withArtist'] ?? 0;
    final pct = withArtist <= 0 ? 0.0 : (mapped / withArtist).clamp(0.0, 1.0);
    final rows = [
      ('已解析', s['resolved'] ?? 0),
      ('待确认', s['ambiguous'] ?? 0),
      ('未命中', s['local'] ?? 0),
      ('待解析', s['pending'] ?? 0),
      ('成员关系', s['members'] ?? 0),
      ('已展开组合', s['expanded'] ?? 0),
      ('回落组合', s['fallback'] ?? 0),
    ];
    return total <= 0
        ? const Center(child: Text('暂无歌手数据'))
        : ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('共 $total 个歌手身份',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: pct),
                      const SizedBox(height: 4),
                      Text(
                        '歌曲映射 $mapped / $withArtist 首 · ${(pct * 100).toStringAsFixed(0)}%',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurface.withValues(alpha: 0.6)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: [
                    for (final e in rows)
                      ListTile(
                        dense: true,
                        title: Text(e.$1),
                        trailing: Text('${e.$2}',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                  ],
                ),
              ),
            ],
          );
  }
}
