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
    final total = entries.fold<int>(0, (p, e) => p + e.value);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              LibrarySortButton(
                label: '数量',
                selected: _byCount,
                ascending: _ascending,
                padded: false,
                onTap: () => setState(() {
                  if (_byCount) {
                    _ascending = !_ascending;
                  } else {
                    _byCount = true;
                    _ascending = false;
                  }
                }),
              ),
              const SizedBox(width: 6),
              LibrarySortButton(
                label: '格式名',
                selected: !_byCount,
                ascending: _ascending,
                padded: false,
                onTap: () => setState(() {
                  if (!_byCount) {
                    _ascending = !_ascending;
                  } else {
                    _byCount = false;
                    _ascending = true;
                  }
                }),
              ),
              const Spacer(),
              Text('共 $total 首', style: Theme.of(context).textTheme.bodySmall),
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
                    final pct =
                        total <= 0 ? 0.0 : (e.value / total).clamp(0.0, 1.0);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 120,
                            child: Text(e.key,
                                style: Theme.of(context).textTheme.bodyMedium),
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
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
