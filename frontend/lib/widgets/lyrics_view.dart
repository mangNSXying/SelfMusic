import 'package:flutter/material.dart';

import '../providers/player_provider.dart';
import '../utils/lrc_parser.dart';

/// 歌词视图：LRC 时间轴同步滚动 + 当前行高亮（点击行跳转播放位置）；
/// 纯文本歌词居中滚动展示；无歌词时显示空态。
class LyricsView extends StatefulWidget {
  final PlayerProvider player;
  const LyricsView({super.key, required this.player});

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _keys = {};

  /// 歌词内容标识：变化时重建行 key（切歌/重新加载）。
  String? _contentKey;
  int _current = -1;

  /// 用户正在手动拖动歌词：暂停自动跟随，避免与手指抢滚动。
  bool _userScrolling = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final cs = Theme.of(context).colorScheme;

    if (p.lyricsLoading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }

    final lines = p.lyricLines;
    if (lines.isEmpty) {
      final plain = p.plainLyrics;
      if (plain != null) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
          child: Text(
            plain,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              height: 1.7,
              color: cs.onSurface.withValues(alpha: 0.85),
            ),
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_outlined,
                size: 56, color: cs.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 14),
            Text('暂无歌词', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '歌曲内嵌歌词或同目录 .lrc 会自动同步显示',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
            ),
          ],
        ),
      );
    }

    final key = '${p.current?.sourceKey}|${p.current?.sourceRef}'
        '|${lines.length}|${lines.first.time.inMilliseconds}';
    if (key != _contentKey) {
      _contentKey = key;
      _current = -1;
      _keys
        ..clear()
        ..addEntries(
            List.generate(lines.length, (i) => MapEntry(i, GlobalKey())));
      // 切歌/重载后先回到顶部，再由同步逻辑滚到当前行。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification) {
          if (n.dragDetails != null) _userScrolling = true;
        } else if (n is ScrollEndNotification) {
          _userScrolling = false;
        }
        return false;
      },
      child: StreamBuilder<Duration>(
        stream: p.player.positionStream,
        builder: (context, snap) {
          final pos = snap.data ?? Duration.zero;
          final idx = lyricIndexAt(lines, pos);
          if (idx != _current) {
            _current = idx;
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _scrollToCurrent(idx));
          }
          return LayoutBuilder(
            builder: (context, c) {
              // 上下留出近半屏空白，使当前行始终居中。
              final pad = c.maxHeight * 0.42;
              return ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.symmetric(vertical: pad),
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final active = i == idx;
                  final near = (i - idx).abs() <= 1;
                  return InkWell(
                    key: _keys[i],
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => p.seek(lines[i].time),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 9),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: active ? 19 : 16,
                          height: 1.5,
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w400,
                          color: active
                              ? cs.primary
                              : cs.onSurface
                                  .withValues(alpha: near ? 0.72 : 0.38),
                        ),
                        child: Text(lines[i].text, textAlign: TextAlign.center),
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  void _scrollToCurrent(int idx) {
    if (idx < 0 || _userScrolling) return;
    final ctx = _keys[idx]?.currentContext;
    if (ctx == null || !mounted) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.42,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }
}
