import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/direct_source_manager.dart';

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
    final pct =
        withArtist <= 0 ? 0.0 : (mapped / withArtist).clamp(0.0, 1.0);
    final rows = [
      ('已解析', s['resolved'] ?? 0),
      ('待确认', s['ambiguous'] ?? 0),
      ('未命中', s['local'] ?? 0),
      ('待解析', s['pending'] ?? 0),
      ('成员关系', s['members'] ?? 0),
      ('已展开组合', s['expanded'] ?? 0),
      ('回落组合', s['fallback'] ?? 0),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('歌手信息')),
      body: total <= 0
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
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: cs.onSurface
                                      .withValues(alpha: 0.6)),
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
            ),
    );
  }
}

/// 歌曲信息 → 格式详情：放大版统计，可按格式名 / 数量排序。
class FormatDetailScreen extends StatefulWidget {
  const FormatDetailScreen({super.key});

  @override
  State<FormatDetailScreen> createState() => _FormatDetailScreenState();
}

class _FormatDetailScreenState extends State<FormatDetailScreen> {
  bool _byCount = true;
  bool _ascending = false;

  @override
  Widget build(BuildContext context) {
    final index = context.watch<DirectSourceManager>().index;
    final formats = index.formatStats();
    var entries = formats.entries.toList();
    entries.sort((a, b) {
      final c = _byCount
          ? a.value.compareTo(b.value)
          : a.key.toLowerCase().compareTo(b.key.toLowerCase());
      return _ascending ? c : -c;
    });
    final total = entries.fold<int>(0, (p, e) => p + e.value);
    return Scaffold(
      appBar: AppBar(title: const Text('格式分布')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  onPressed: () => setState(() {
                    if (_byCount) {
                      _ascending = !_ascending;
                    } else {
                      _byCount = true;
                      _ascending = false;
                    }
                  }),
                  child: Text('数量${_byCount ? (_ascending ? ' ↑' : ' ↓') : ''}'),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                  onPressed: () => setState(() {
                    if (!_byCount) {
                      _ascending = !_ascending;
                    } else {
                      _byCount = false;
                      _ascending = true;
                    }
                  }),
                  child: Text('格式名${!_byCount ? (_ascending ? ' ↑' : ' ↓') : ''}'),
                ),
                const Spacer(),
                Text('共 $total 首',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('暂无格式数据'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final pct = total <= 0
                          ? 0.0
                          : (e.value / total).clamp(0.0, 1.0);
                      return Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 5),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 120,
                              child: Text(e.key,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium),
                            ),
                            Expanded(
                              child: LinearProgressIndicator(
                                value: pct,
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.15),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 110,
                              child: Text(
                                '${e.value} 首 · ${(pct * 100).toStringAsFixed(0)}%',
                                textAlign: TextAlign.right,
                                style:
                                    Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
