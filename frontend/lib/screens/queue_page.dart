import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song.dart';
import '../data/local/app_settings.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../utils/song_title_format.dart';
import '../widgets/row_list.dart';
import '../widgets/song_tile.dart';

/// 当前播放队列全屏页（改进.txt UI6）：播放页右滑进入。
///
/// 全屏 + 顶部搜索框，保留队列面板的能力：点行 [PlayerProvider.playAt] 切歌、
/// 当前播放曲高亮。搜索按展示标题/歌手过滤当前队列，不影响原始播放顺序。
class QueuePage extends StatefulWidget {
  const QueuePage({super.key});

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Song s, String q, SongTitleFormat fmt) {
    if (q.isEmpty) return true;
    if (formatSongTitle(s, fmt).toLowerCase().contains(q)) return true;
    final artist = (s.artist ?? '').toLowerCase();
    return artist.contains(q);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();
    final queue = player.queue;
    final q = _query.trim().toLowerCase();
    late final List<int> indices;
    if (q.isEmpty) {
      indices = [for (var i = 0; i < queue.length; i++) i];
    } else {
      indices = [
        for (var i = 0; i < queue.length; i++)
          if (_matches(queue[i], q, direct.settings.songTitleFormat)) i,
      ];
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('播放队列（${queue.length}）'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: '搜索当前队列',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清除',
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
        ),
      ),
      body: indices.isEmpty
          ? const Center(child: Text('队列为空'))
          : RowList(
              count: indices.length,
              itemBuilder: (c, i) {
                final realIndex = indices[i];
                final s = queue[realIndex];
                final isCurrent = player.isCurrent(s);
                return SongTile(
                  song: s,
                  source: null,
                  compact: true,
                  playing: isCurrent,
                  onPlay: () => player.playAt(realIndex),
                );
              },
            ),
    );
  }
}