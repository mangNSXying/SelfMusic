import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/direct_source_manager.dart';
import 'detail_shared.dart';

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
    final total = entries.fold<int>(0, (sum, e) => sum + e.value);
    final cs = Theme.of(context).colorScheme;

    return Column(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kInfoContentMaxWidth),
            child: LibraryDetailToolbar(
              actions: [
                LibrarySortMenu(
                  label: '排序',
                  value: _byCount ? 0 : 1,
                  ascending: _ascending,
                  options: const [(0, '数量'), (1, '格式名')],
                  onSelected: (v) => setState(() {
                    final byCount = v == 0;
                    if (byCount == _byCount) {
                      _ascending = !_ascending;
                    } else {
                      _byCount = byCount;
                      // 格式名默认升序，数量默认降序。
                      _ascending = !byCount;
                    }
                  }),
                ),
              ],
              countLabel: '共 $total 首 · ${entries.length} 种格式',
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: entries.isEmpty
              ? const Center(child: Text('暂无格式数据'))
              : Center(
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxWidth: kInfoContentMaxWidth),
                    child: ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      itemCount: entries.length,
                      itemBuilder: (context, i) {
                        final entry = entries[i];
                        final pct = total <= 0
                            ? 0.0
                            : (entry.value / total).clamp(0.0, 1.0);
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 96,
                                child: Text(
                                  entry.key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: pct,
                                    minHeight: 8,
                                    backgroundColor:
                                        cs.primary.withValues(alpha: 0.12),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 140,
                                child: Text(
                                  '${entry.value} 首 · '
                                  '${(pct * 100).toStringAsFixed(0)}%',
                                  textAlign: TextAlign.right,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
