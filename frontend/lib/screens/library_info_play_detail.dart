import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../providers/direct_source_manager.dart';
import '../utils/play_stats.dart';

/// 歌曲信息 → 播放数据详情：全部有效歌曲的播放次数与播放时长。
///
/// 口径：次数 = play_sec / 歌曲时长（见 [playCountOf]），未知时长按 0 次。
class PlayDetailScreen extends StatefulWidget {
  const PlayDetailScreen({super.key});

  @override
  State<PlayDetailScreen> createState() => _PlayDetailScreenState();
}

class _PlayDetailScreenState extends State<PlayDetailScreen> {
  String _query = '';
  bool _onlyWithPlay = false;
  int _sortColumn = 3;
  bool _ascending = false;
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSort(int column, bool ascending) {
    setState(() {
      _sortColumn = column;
      _ascending = ascending;
    });
  }

  static double _countOf(PlayDetailRow r) {
    if (r.playSec <= 0) return 0;
    final d = r.duration;
    if (d == null || d <= 0) return 0;
    return r.playSec / d;
  }

  @override
  Widget build(BuildContext context) {
    final index = context.watch<DirectSourceManager>().index;
    final all = index.playDetailRows();
    var totalSec = 0;
    var totalCount = 0.0;
    for (final r in all) {
      totalSec += r.playSec;
      totalCount += _countOf(r);
    }

    final q = _query.trim().toLowerCase();
    var rows = all.where((r) {
      if (_onlyWithPlay && r.playSec <= 0) return false;
      if (q.isEmpty) return true;
      final t = r.title.toLowerCase().contains(q);
      final a = (r.artist ?? '').toLowerCase().contains(q);
      return t || a;
    }).toList();

    int cmp(PlayDetailRow a, PlayDetailRow b) {
      int c;
      switch (_sortColumn) {
        case 0:
          c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
        case 1:
          c = (a.artist ?? '').toLowerCase()
              .compareTo((b.artist ?? '').toLowerCase());
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 2:
          c = a.sourceKey.toLowerCase().compareTo(b.sourceKey.toLowerCase());
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 3:
          c = _countOf(a).compareTo(_countOf(b));
          if (c == 0) c = a.playSec.compareTo(b.playSec);
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 4:
        default:
          c = a.playSec.compareTo(b.playSec);
          if (c == 0) c = _countOf(a).compareTo(_countOf(b));
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
      }
      return _ascending ? c : -c;
    }

    rows.sort(cmp);

    return Scaffold(
      appBar: AppBar(title: const Text('播放数据')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共 ${all.length} 首 · '
                        '累计 ${totalCount.toStringAsFixed(1)} 次 · '
                        '${playSecLabel(totalSec)}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '按歌曲名 / 歌手过滤',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('仅看有播放'),
                  selected: _onlyWithPlay,
                  onSelected: (v) => setState(() => _onlyWithPlay = v),
                ),
                const SizedBox(width: 8),
                Text('${rows.length} 首',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('无匹配歌曲'))
                : SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        sortColumnIndex: _sortColumn,
                        sortAscending: _ascending,
                        columns: [
                          DataColumn(
                            label: const Text('歌曲名'),
                            onSort: (i, asc) => _onSort(0, asc),
                          ),
                          DataColumn(
                            label: const Text('歌手'),
                            onSort: (i, asc) => _onSort(1, asc),
                          ),
                          DataColumn(
                            label: const Text('播放源'),
                            onSort: (i, asc) => _onSort(2, asc),
                          ),
                          DataColumn(
                            label: const Text('播放次数'),
                            numeric: true,
                            onSort: (i, asc) => _onSort(3, asc),
                          ),
                          DataColumn(
                            label: const Text('播放时长'),
                            numeric: true,
                            onSort: (i, asc) => _onSort(4, asc),
                          ),
                        ],
                        rows: [
                          for (final r in rows)
                            DataRow(cells: [
                              DataCell(ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 220),
                                child: Text(r.title,
                                    overflow: TextOverflow.ellipsis),
                              )),
                              DataCell(Text(
                                (r.artist == null || r.artist!.isEmpty)
                                    ? '—'
                                    : r.artist!,
                                overflow: TextOverflow.ellipsis,
                              )),
                              DataCell(Text(r.sourceKey,
                                  overflow: TextOverflow.ellipsis)),
                              DataCell(Text(playCountLabel(
                                  r.playSec, r.duration))),
                              DataCell(
                                  Text(playSecLabel(r.playSec))),
                            ]),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
