import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/direct_source_manager.dart';
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

  /// 用户拖动歌词后到空闲计时结束前暂停自动跟随，避免与手指抢滚动；
  /// 计时时长由「播放」设置里的歌词追焦等待决定。
  bool _followSuppressed = false;
  Timer? _idleTimer;
  int _idleSec = 5;

  /// 当前行二次校正（等放大/折行样式动画结束后回中）。
  Timer? _recenter;

  @override
  void dispose() {
    _idleTimer?.cancel();
    _recenter?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.player;
    final cs = Theme.of(context).colorScheme;
    // 歌词追焦等待时长（用户拖动后多久恢复自动跟随），设置改动即时生效。
    _idleSec = context
        .watch<DirectSourceManager>()
        .settings
        .lyricFocusIdleSec;

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
          if (n.dragDetails != null) {
            // 手指开始拖动：暂停跟随并取消空闲计时（含惯性滚动期间）。
            _followSuppressed = true;
            _idleTimer?.cancel();
            _idleTimer = null;
          }
        } else if (n is ScrollEndNotification &&
            _followSuppressed &&
            _idleTimer == null) {
          // 拖动/惯性滚动结束后开始计时，超时恢复追焦并立即回中当前行。
          _idleTimer = Timer(Duration(seconds: _idleSec), () {
            _idleTimer = null;
            _followSuppressed = false;
            if (mounted) _scrollToCurrent(_current);
          });
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
                        child: lines[i].translation == null
                            ? Text(lines[i].text, textAlign: TextAlign.center)
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(lines[i].text,
                                      textAlign: TextAlign.center),
                                  const SizedBox(height: 2),
                                  Text(
                                    lines[i].translation!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: active ? 16 : 14,
                                      height: 1.4,
                                      fontWeight: FontWeight.w400,
                                      color: active
                                          ? cs.primary
                                              .withValues(alpha: 0.85)
                                          : cs.onSurface.withValues(
                                              alpha: near ? 0.62 : 0.32),
                                    ),
                                  ),
                                ],
                              ),
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
    if (idx < 0 || _followSuppressed || !mounted) return;
    final ctx = _keys[idx]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.42,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    // 当前行放大/长句折行的样式动画（200ms）结束后行高才稳定；
    // 二次校正一次，避免「行高变化导致居中像素偏掉」。
    _recenter?.cancel();
    _recenter = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _followSuppressed || _current != idx) return;
      final ctx2 = _keys[idx]?.currentContext;
      if (ctx2 == null) return;
      Scrollable.ensureVisible(
        ctx2,
        alignment: 0.42,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }
}
