import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../providers/direct_source_manager.dart';

/// 歌曲信息 → 元数据详情：精确到每一首歌，各维度“有没有 / 是什么”。
///
/// 过滤：搜索（歌名/歌手/专辑）+ 维度缺失过滤；排序：歌曲名 / 歌手 / 缺失数。
class MetaDetailScreen extends StatefulWidget {
  const MetaDetailScreen({super.key});

  @override
  State<MetaDetailScreen> createState() => _MetaDetailScreenState();
}

class _MetaDetailScreenState extends State<MetaDetailScreen> {
  String _query = '';
  String? _dimFilter; // null=全部，'missing_any'=有缺失，否则为维度 key
  int _sortMode = 0; // 0=歌曲名，1=歌手，2=缺失数
  bool _ascending = true;
  final _searchCtrl = TextEditingController();

  static const dims = [
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
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = context.watch<DirectSourceManager>().index;
    final all = index.metaDetailRows();

    final q = _query.trim().toLowerCase();
    var rows = all.where((r) {
      if (q.isNotEmpty) {
        final hit = r.title.toLowerCase().contains(q) ||
            (r.artist ?? '').toLowerCase().contains(q) ||
            (r.album ?? '').toLowerCase().contains(q);
        if (!hit) return false;
      }
      if (_dimFilter == null) return true;
      if (_dimFilter == 'missing_any') return r.missingCount > 0;
      return !r.hasDim(_dimFilter!);
    }).toList();

    int cmp(MetaDetailRow a, MetaDetailRow b) {
      int c;
      switch (_sortMode) {
        case 1:
          c = (a.artist ?? '').toLowerCase()
              .compareTo((b.artist ?? '').toLowerCase());
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 2:
          c = a.missingCount.compareTo(b.missingCount);
          if (c == 0) {
            c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          }
          break;
        case 0:
        default:
          c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
      }
      return _ascending ? c : -c;
    }

    rows.sort(cmp);

    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('元数据信息')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '按歌曲名 / 歌手 / 专辑过滤',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('全部'),
                    selected: _dimFilter == null,
                    onSelected: (_) =>
                        setState(() => _dimFilter = null),
                  ),
                  ChoiceChip(
                    label: const Text('有缺失'),
                    selected: _dimFilter == 'missing_any',
                    onSelected: (_) =>
                        setState(() => _dimFilter = 'missing_any'),
                  ),
                  for (final d in dims)
                    ChoiceChip(
                      label: Text('缺${d.$2}'),
                      selected: _dimFilter == d.$1,
                      onSelected: (_) =>
                          setState(() => _dimFilter = d.$1),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                _sortBtn(context, 0, '歌曲名'),
                const SizedBox(width: 6),
                _sortBtn(context, 1, '歌手'),
                const SizedBox(width: 6),
                _sortBtn(context, 2, '缺失数'),
                const Spacer(),
                Text('${rows.length} / ${all.length} 首',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: rows.isEmpty
                ? const Center(child: Text('无匹配歌曲'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: rows.length,
                    itemBuilder: (context, i) {
                      final r = rows[i];
                      final missing = r.missingCount;
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: ExpansionTile(
                          dense: true,
                          title: Text(r.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            '${(r.artist == null || r.artist!.isEmpty) ? '未知歌手' : r.artist} · ${(r.album == null || r.album!.isEmpty) ? '未知专辑' : r.album} · ${r.sourceKey}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: (missing == 0
                                      ? cs.primary
                                      : cs.error)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              missing == 0 ? '全齐' : '缺 $missing 项',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: missing == 0
                                        ? cs.primary
                                        : cs.error,
                                  ),
                            ),
                          ),
                          children: [
                            for (final d in dims)
                              _dimLine(context, d.$2, _dimValue(r, d.$1),
                                  ok: r.hasDim(d.$1)),
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

  Widget _sortBtn(BuildContext context, int mode, String label) {
    final selected = _sortMode == mode;
    final arrow = selected ? (_ascending ? ' ↑' : ' ↓') : '';
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      onPressed: () => setState(() {
        if (_sortMode == mode) {
          _ascending = !_ascending;
        } else {
          _sortMode = mode;
          _ascending = mode == 2 ? false : true;
        }
      }),
      child: Text('$label$arrow'),
    );
  }

  String _dimValue(MetaDetailRow r, String dim) => switch (dim) {
        'meta_read' => r.metaRead ? '已读' : '待读取',
        'artist' => _v(r.artist),
        'album' => _v(r.album),
        'album_artist' => _v(r.albumArtist),
        'genre' => _v(r.genre),
        'track_no' => r.trackNo?.toString() ?? '缺失',
        'year' => r.year?.toString() ?? '缺失',
        'duration' => r.duration != null && r.duration! > 0
            ? '${r.duration} 秒'
            : '缺失',
        'cover' => r.hasCover ? '有' : '缺失',
        'lyrics' => r.hasLyrics ? '有' : '缺失',
        'format' => _v(r.format),
        'bitrate' => r.bitrateEstimable ? '可估算' : '缺失',
        _ => '',
      };

  String _v(String? s) =>
      (s == null || s.isEmpty) ? '缺失' : s;

  Widget _dimLine(BuildContext context, String label, String value,
      {required bool ok}) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.7))),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: ok ? null : cs.error,
                    fontWeight: ok ? null : FontWeight.w600,
                  ),
            ),
          ),
          Icon(ok ? Icons.check : Icons.close,
              size: 14, color: ok ? cs.primary : cs.error),
        ],
      ),
    );
  }
}
