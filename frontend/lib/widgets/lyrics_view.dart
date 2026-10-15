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

  /// 跟焦动画代次：被换行/跳转/拖动取代的旧动画，其完成回调不得再改写飞行状态。
  int _animGen = 0;

  /// 是否有跟焦动画在飞（与 [_flying] 同生共死；只用 [_animating] 判定）。
  bool _animating = false;

  /// 在飞动画瞄准的行号（判断「换行了才重定目标」）。
  int _flightIdx = -1;

  /// 动画途中目标偏移漂移的容忍值（px）。
  ///
  /// 来源：当前行字号动画（16→19，height 1.5）让**行高**在 200ms 内从 42 长到
  /// 46.5，带译文的行还要多 ~3px——即换行后目标最多漂 5~7px。取 4px：既让这类
  /// 漂移大多被动画吸收（最多在换行窗口内微调 1~2 次），又远小于真实布局变化
  /// （折行数变化 / 译文行出现 ≥20px，必须重定目标）。重开动画等于丢一帧位移，
  /// 密集重开就是爬行卡顿（见 [_followCurrent]）。
  static const double _retargetTolerance = 4;

  /// 用户拖动歌词后到空闲计时结束前暂停自动跟随，避免与手指抢滚动；
  /// 计时时长由「播放」设置里的歌词追焦等待决定。
  bool _followSuppressed = false;
  Timer? _idleTimer;
  int _idleSec = 5;

  /// 当前行二次校正（等放大/折行样式动画结束后回中）。
  Timer? _recenter;

  /// 歌词位置订阅：改为「订阅流 + 仅在行号变化时 setState」，避免每个位置事件
  /// （每秒数十次）都触发整表 ListView 重建（R-1/T017）。
  StreamSubscription<Duration>? _posSub;

  @override
  void initState() {
    super.initState();
    _posSub = widget.player.lyricPositionStream.listen(_onPosition);
  }

  /// 位置事件：仅在「当前高亮行号」变化时重建；无论是否变化都安排一次跟焦
  /// （自愈式复核，行号没变也可能因懒构建/页面刚可见而滚丢）。
  void _onPosition(Duration pos) {
    if (!mounted) return;
    final lines = widget.player.lyricLines;
    if (lines.isEmpty) return;
    final idx = lyricIndexAt(lines, pos);
    if (idx != _current) {
      setState(() => _current = idx);
    }
    _scheduleFollow();
  }

  /// 当前行在视口中的对齐位（与列表上下留白一致）。
  static const double _align = 0.42;

  /// 目标行未构建时临时把 cacheExtent 提到这个值（约 300 行歌词），
  /// 正常状态用 ListView 默认的 250。
  /// 经典 double cacheExtent：stable 3.47 与 ohos 3.41.9 双 SDK 兼容
  /// （ohos 分支无 ScrollCacheExtent/scrollCacheExtent 新 API）。
  static const double _wideCacheExtent = 12000;

  @override
  void dispose() {
    _posSub?.cancel();
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
        } else if (n is ScrollEndNotification) {
          // 普通滚动结束：复核当前行是否在位（自愈）。不再依赖每次 build 触发。
          _scheduleFollow();
        } else if (n is ScrollMetricsNotification) {
          // 视口尺寸变化（转屏、歌词页刚可见）：重新核对当前行位置。
          _scheduleFollow();
        }
        return false;
      },
      // 不再用 StreamBuilder：位置流在 [_onPosition] 里订阅，仅在行号变化时
      // setState 重建（避免每个位置事件整表重建），此处直接渲染当前行状态。
      child: LayoutBuilder(
        builder: (context, c) {
          // 上下留出近半屏空白，使当前行始终居中。
          final pad = c.maxHeight * _align;
          return ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.symmetric(vertical: pad),
            cacheExtent: _wideCache ? _wideCacheExtent : null,
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final active = i == _current;
              final near = (i - _current).abs() <= 1;
              return InkWell(
                key: _keys[i],
                borderRadius: BorderRadius.circular(10),
                onTap: () => p.seek(lines[i].time),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
                  child: _LyricRowText(
                    text: lines[i].text,
                    translation: lines[i].translation,
                    mainStyle: TextStyle(
                      fontSize: active ? 19 : 16,
                      height: 1.5,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                      color: active
                          ? cs.primary
                          : cs.onSurface
                              .withValues(alpha: near ? 0.72 : 0.38),
                    ),
                    subStyle: lines[i].translation == null
                        ? null
                        : TextStyle(
                            fontSize: active ? 16 : 14,
                            height: 1.4,
                            fontWeight: FontWeight.w400,
                            color: active
                                ? cs.primary.withValues(alpha: 0.85)
                                : cs.onSurface.withValues(
                                    alpha: near ? 0.62 : 0.32),
                          ),
                  ),
                ),
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
  ///
  /// 但「每次复核」不等于「每次都重开动画」：位置事件可能比帧频还快。just_audio
  /// 的 positionStream = 播放事件 + `Timer.periodic(duration/800)`（夹在
  /// [16ms, 200ms]），实际频率取决于后端播放事件频率——真机 2026-10-15 实测：
  /// 同一首歌手机 68 次/秒（≈帧率、鸿蒙 fvp 媒体状态事件按帧触发）、平板 10 次/秒，
  /// 这正是「手机卡、平板不复现」的根因。对进行中的动画逐次重开时，每段新动画的
  /// 第一次 tick 位移恒为 0（ticker 起始时间在首帧才记），滚动退化成「逐帧微移的
  /// 爬行」——现象就是追焦一卡一卡、高亮正常、手指一碰即停（拖动抑制跟焦）。
  /// 因此动画进行中只做「目标是否真的变了」的裁决（换行/布局大幅变化才重定目标）。
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

    if (_animating) {
      // 动画进行中：同一行且目标基本一致 → 交给动画自己走完（**不重开**）。
      // 换行或布局大幅变化（行高动画、折行数变化）才打断旧动画、按新目标重开。
      if (_flightIdx == idx && (_flying! - target).abs() <= _retargetTolerance) {
        return;
      }
    } else if ((target - pos.pixels).abs() <= 0.5) {
      // 静止复核：已在位，无需动作（自愈通过）。
      // 目标行已构建，把临时加宽的 cacheExtent 收回去。
      if (_wideCache) setState(() => _wideCache = false);
      return;
    }

    if (_firstAlign) {
      // 首次归位（进页面/切歌）：瞬时到位，避免长距离滑行。
      _firstAlign = false;
      _invalidateFlight(); // 作废可能的在飞动画（切歌/重载竞态）
      pos.jumpTo(target);
      if (_wideCache) setState(() => _wideCache = false);
      return;
    }
    // 剩余距离短时用短动画：否则「只差几像素」也要磨 320ms，看着发滞。
    final dist = (target - pos.pixels).abs();
    final shortHop = quick || dist < 24;
    final gen = ++_animGen;
    _animating = true;
    _flying = target;
    _flightIdx = idx;
    unawaited(pos
        .animateTo(
          target,
          duration: shortHop
              ? const Duration(milliseconds: 140)
              : const Duration(milliseconds: 320),
          curve: shortHop ? Curves.easeOut : Curves.easeOutCubic,
        )
        .then<void>((_) {
      // 只有「当前这一段」动画的完成才能改写飞行状态：被换行/跳转取代的旧动画
      // 完成回调不能把新动画的 _flying 清成 null（否则下一次复核会误判为
      // 「没在飞」而重开，退化成逐帧爬行——旧实现的隐式 bug）。
      if (gen == _animGen) {
        _animating = false;
        _flying = null;
        _flightIdx = -1;
      }
    }, onError: (Object e, StackTrace s) {
      if (gen == _animGen) {
        _animating = false;
        _flying = null;
        _flightIdx = -1;
      }
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

  /// 作废在飞动画的记账（不主动打断滚动，交给新的滚动/手势接管）。
  void _invalidateFlight() {
    _animGen++;
    _animating = false;
    _flying = null;
    _flightIdx = -1;
  }

  /// 用户开始拖动：暂停跟焦并开始空闲计时。
  void _suppressFollow() {
    _followSuppressed = true;
    // 拖动会接管滚动（在飞动画被 Scrollable 的 hold 顶掉），清理飞行记账，
    // 让空闲超时恢复跟焦时从干净状态重新起一段动画。
    _invalidateFlight();
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

/// 歌词行文本：**布局属性（字号/字重）同帧切换，只有颜色补间**（200ms）。
///
/// 为什么不让字号参与补间：字号/字重一变，该行的折行与行高就变（当前行变高
/// ~4.5px、带译文行再多 ~3px，上一行同步变矮），补间意味着这些变化在 200ms 里
/// 持续发生——跟焦目标随之漂移，动画落点必然差几像素，收尾还得再挪一次
/// （2026-10-15 真机反馈的「每次换行都补一下 4px」就是这么来的）。
/// 改成同帧定稿后：换行那一帧排版即最终值，跟焦一次动画到位、复核即 noop。
/// 颜色不影响排版，照旧补间，保留高亮渐变观感。
class _LyricRowText extends StatelessWidget {
  final String text;
  final String? translation;

  /// 主文本样式（含当前状态的字号/字重/颜色）。
  final TextStyle mainStyle;

  /// 译文样式（无译文为 null）。
  final TextStyle? subStyle;

  const _LyricRowText({
    required this.text,
    required this.translation,
    required this.mainStyle,
    required this.subStyle,
  });

  static const Duration _fade = Duration(milliseconds: 200);

  @override
  Widget build(BuildContext context) {
    final main = _FadingText(text: text, style: mainStyle);
    final sub = subStyle;
    if (translation == null || sub == null) return main;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        main,
        const SizedBox(height: 2),
        _FadingText(text: translation!, style: sub),
      ],
    );
  }
}

/// 单行文本：颜色从当前值补间到目标值（布局属性不参与补间）。
class _FadingText extends StatelessWidget {
  final String text;
  final TextStyle style;
  const _FadingText({required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: style.color),
      duration: _LyricRowText._fade,
      builder: (context, color, _) => Text(
        text,
        textAlign: TextAlign.center,
        style: style.copyWith(color: color ?? style.color),
      ),
    );
  }
}
