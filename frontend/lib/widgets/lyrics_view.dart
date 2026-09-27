import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  /// 当前高亮行（-1 = 尚无高亮行，如歌还没到第一句歌词）。
  int _current = -1;

  /// 本段内容的首次归位用瞬时跳转（进歌词页 / 切歌），之后换行才用动画，
  /// 避免从顶部一路滑到很后面。
  bool _firstAlign = true;

  /// 目标行还没被 ListView 构建出来时临时加宽 cacheExtent（见 [_followCurrent]）。
  bool _wideCache = false;

  /// 目标行未构建时的补滚重试次数上限。
  int _retry = 0;

  /// 一帧内只安排一次跟焦（位置事件比帧频快）。
  bool _followScheduled = false;

  /// 正在飞向的目标偏移：动画途中位置事件不再重复发起同目标的滚动。
  double? _flying;

  /// 用户拖动歌词后到空闲计时结束前暂停自动跟随，避免与手指抢滚动；
  /// 计时时长由「播放」设置里的歌词追焦等待决定。
  bool _followSuppressed = false;
  Timer? _idleTimer;
  int _idleSec = 5;

  /// 当前行二次校正（等放大/折行样式动画结束后回中）。
  Timer? _recenter;

  /// 当前行在视口中的对齐位（与列表上下留白一致）。
  static const double _align = 0.42;

  /// 目标行未构建时临时把 cacheExtent 提到这个值（约 300 行歌词），
  /// 正常状态用 ListView 默认的 250。
  static const ScrollCacheExtent _wideCacheExtent =
      ScrollCacheExtent.pixels(12000);

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
      _firstAlign = true;
      _flying = null;
      _keys
        ..clear()
        ..addEntries(
            List.generate(lines.length, (i) => MapEntry(i, GlobalKey())));
      // 切歌/重载不预跳顶部：本次内容的第一帧会瞬时归位到当前行。
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is ScrollStartNotification) {
          if (n.dragDetails != null) _suppressFollow();
        } else if (_followSuppressed &&
            (n is ScrollUpdateNotification || n is ScrollEndNotification)) {
          // 拖动/惯性期间不断续期：即使手势被中断（没有 ScrollEnd）也能恢复。
          _armIdleTimer();
        } else if (n is ScrollMetricsNotification) {
          // 视口尺寸变化（转屏、歌词页刚可见）：重新核对当前行位置。
          _scheduleFollow();
        }
        return false;
      },
      child: StreamBuilder<Duration>(
        stream: p.lyricPositionStream,
        builder: (context, snap) {
          final pos = snap.data ?? Duration.zero;
          _current = lyricIndexAt(lines, pos);
          // 每次位置事件都核对「当前行是否真的在位」：行号没变也可能滚丢了
          // （懒构建导致上次跟焦取不到 context、页面刚可见等）。
          _scheduleFollow();
          return LayoutBuilder(
            builder: (context, c) {
              // 上下留出近半屏空白，使当前行始终居中。
              final pad = c.maxHeight * _align;
              return ListView.builder(
                controller: _scroll,
                padding: EdgeInsets.symmetric(vertical: pad),
                scrollCacheExtent: _wideCache ? _wideCacheExtent : null,
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final active = i == _current;
                  final near = (i - _current).abs() <= 1;
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

  /// 把跟焦安排到本帧末执行（build 期间不能直接动滚动/ setState）。
  void _scheduleFollow() {
    if (_followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      _followCurrent();
    });
  }

  /// 自愈式跟焦：核对当前行是否已在 [_align] 对齐位，不在就滚过去。
  ///
  /// 不再以「行号是否变化」为触发条件——行号已经记住但滚动失败时（如 ListView
  /// 懒构建导致目标行尚未构建、从播放页滑入时该页才刚创建）会永久卡住，
  /// 必须每次都按真实布局状态复核。
  void _followCurrent({bool quick = false}) {
    if (!mounted || _followSuppressed) return;
    final idx = _current;
    final pos = _scroll.position;
    if (idx < 0 || !_scroll.hasClients) return;
    // 视口/内容尺寸未就绪时算出的目标偏移不可信，等下一次触发。
    if (!pos.hasViewportDimension || !pos.hasContentDimensions) return;

    final ro = _keys[idx]?.currentContext?.findRenderObject();
    if (ro == null) {
      // 目标行不在已构建范围内：先加宽 cacheExtent 让它被构建出来再滚。
      if (!_wideCache) {
        setState(() => _wideCache = true);
        _scheduleFollow();
      } else if (_retry < 3) {
        _retry++;
        _scheduleFollow();
      }
      return;
    }
    final vp = RenderAbstractViewport.maybeOf(ro);
    if (vp == null) return;
    final target = vp
        .getOffsetToReveal(ro, _align)
        .offset
        .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _retry = 0;
    if ((target - pos.pixels).abs() <= 0.5) {
      _flying = null;
      // 目标行已构建，把临时加宽的 cacheExtent 收回去。
      if (_wideCache) setState(() => _wideCache = false);
      return;
    }
    // 已在飞向同一目标：等动画自己走完（位置事件比帧频快，别打断它）。
    if (_flying != null && (_flying! - target).abs() <= 0.5) return;

    _flying = target;
    if (_firstAlign) {
      // 首次归位（进页面/切歌）：瞬时到位，避免长距离滑行。
      _firstAlign = false;
      pos.jumpTo(target);
      if (_wideCache) setState(() => _wideCache = false);
      return;
    }
    unawaited(pos
        .animateTo(
          target,
          duration: quick
              ? const Duration(milliseconds: 140)
              : const Duration(milliseconds: 320),
          curve: quick ? Curves.easeOut : Curves.easeOutCubic,
        )
        .then<void>((_) => _flying = null, onError: (Object e, StackTrace s) {
          _flying = null;
          debugPrint('[lyrics] 跟焦滚动失败: $e');
        }));
    if (_wideCache) setState(() => _wideCache = false);
    // 当前行放大/长句折行的样式动画（200ms）结束后行高才稳定；
    // 二次校正一次，避免「行高变化导致居中像素偏掉」。
    _recenter?.cancel();
    _recenter = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _followSuppressed || _current != idx) return;
      _followCurrent(quick: true);
    });
  }

  /// 用户开始拖动：暂停跟焦并开始空闲计时。
  void _suppressFollow() {
    _followSuppressed = true;
    _recenter?.cancel();
    _armIdleTimer();
  }

  /// 空闲计时（续期式）：拖动/惯性期间反复重置，超时后恢复跟焦并立即回中当前行。
  /// 计时在 ScrollStart 就启动，因此手势被中断（收不到 ScrollEnd）时也不会卡住。
  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(Duration(seconds: _idleSec), () {
      _idleTimer = null;
      _followSuppressed = false;
      _followCurrent();
    });
  }
}
