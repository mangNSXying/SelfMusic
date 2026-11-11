import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../data/local/app_settings.dart';
import '../../theme/app_theme.dart';
import '../../utils/interaction_gate.dart';
import '../../utils/motion.dart';
import '../../widgets/page_transition.dart';
import '../../widgets/section_swipe.dart';
import '../library/albums_view.dart';
import '../library/artists_view.dart';
import '../library/liked_view.dart';
import '../library/songs_view.dart';
import '../sources/sources_screen.dart';
import '../playlists/playlists_view.dart';

/// 六个顶级分组的容器（歌单/喜欢/播放源/歌曲/专辑/歌手）。
///
/// - 滑动档：跟手 PageView（原生跟手 + 位置/速度吸附）；
///   程序驱动（顶栏点击/返回键）`animateToPage`，方向天然正确；
///   双向同步防抢：手指拖拽中不调 `animateToPage`（`_programmatic` +
///   `isScrolling` 双条件）。
/// - 淡入/缩放/关闭档：单页 + 按设置的过渡（横滑松手触发切换）。
class SectionPager extends StatefulWidget {
  const SectionPager({super.key});

  @override
  State<SectionPager> createState() => _SectionPagerState();
}

class _SectionPagerState extends State<SectionPager>
    with SingleTickerProviderStateMixin {
  late final PageController _ctrl;
  late int _applied;
  bool _programmatic = false;
  bool _slideActive = false;

  /// 非相邻分组的入场动画（不穿中间页）：整页从目标方向滑入。
  late final AnimationController _enterCtrl;
  late final CurvedAnimation _enterCurve;
  int _enterDir = 1;

  /// 跨多页切换的退场快照：PageView 必须立即跳到目标页（不穿中间页），
  /// 旧页元素随之下线；快照留住旧页最后一帧，让新旧两页同时反向滑动，
  /// 而不是旧页瞬间消失、新页从空白里滑入。
  ui.Image? _exitSnapshot;

  /// 退场快照的取景边界（包在进场位移之内，截到的是未位移的页面）。
  final GlobalKey _viewportKey = GlobalKey();

  /// 跨页切换代次：迟到的退场快照只允许插入自己那一趟动画。
  int _farGen = 0;

  /// 首帧空闲后开启相邻页预构建（allowImplicitScrolling 给 PageView 一屏
  /// cacheExtent）：不在启动首帧多背两页，又让首次横滑不必现场建目标页。
  /// 页内是固定行高懒列表，预构建只建「可能显示的行」，不会整表构建。
  bool _warmNeighbors = false;

  /// 交互门控（横滑/入场动画期间聚合后台数据通知）。
  InteractionGate? _gate;

  static int _indexOf(NavSection s) => NavSection.values.indexOf(s);

  /// 六个分组页（顺序与 NavSection.values 一致）。
  static const _pages = [
    PlaylistsView(),
    LikedView(),
    SourcesScreen(),
    SongsView(),
    AlbumsView(),
    ArtistsView(),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gate = InteractionGate.maybeOf(context);
  }

  @override
  void initState() {
    super.initState();
    final nav = context.read<NavigationProvider>();
    final initial = _indexOf(nav.section);
    _applied = initial;
    _ctrl = PageController(initialPage: initial);
    _ctrl.addListener(_syncOffset);
    _enterCtrl =
        AnimationController(vsync: this, duration: kPageMotion, value: 1);
    _enterCurve = CurvedAnimation(parent: _enterCtrl, curve: kPageMotionCurve);
    // 跨页入场动画进行中 → 门控视为「过渡中」。
    _enterCtrl.addStatusListener((s) {
      if (s == AnimationStatus.forward) {
        _gate?.setTransitioning(true);
      } else if (s == AnimationStatus.completed) {
        // 退场快照末帧已移出视口，落定即释放。
        // 注意不能在 dismissed 时清：forward(from: 0) 会先把值归零并同步
        // 触发一次 dismissed，此时动画才刚要开始。
        _clearExitSnapshot(notify: true);
        _refreshTransitionSignal();
      } else if (s == AnimationStatus.dismissed) {
        _refreshTransitionSignal();
      }
    });
    // 首帧空闲后再预构建左右邻页（内存/启动成本的折中，见字段注释）。
    // pageOffset 也必须等帧后再写：Pager 可能在 TopBar 的
    // ValueListenableBuilder 构建期间挂载，同步写会触发
    // “setState() called during build”，导致顶栏高亮停在旧分组。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = _indexOf(nav.section).toDouble();
      if (nav.pageOffset.value != target) nav.pageOffset.value = target;
      setState(() => _warmNeighbors = true);
    });
  }

  @override
  void dispose() {
    // 组件销毁时若仍在动画中，避免门控停留在「过渡中」。
    _gate?.setTransitioning(false);
    _exitSnapshot?.dispose();
    _ctrl.removeListener(_syncOffset);
    _ctrl.dispose();
    _enterCurve.dispose();
    _enterCtrl.dispose();
    super.dispose();
  }

  /// 丢弃退场快照。默认在下一帧后释放：当前帧可能仍在绘制它。
  ///
  /// 同时推进代次：仍在引擎线程栅格化的旧快照到达后会被丢弃，
  /// 不会串进下一趟动画（切模式/连续点击）。
  void _clearExitSnapshot({bool notify = false}) {
    _farGen++;
    final shot = _exitSnapshot;
    if (shot == null) return;
    if (notify) {
      setState(() => _exitSnapshot = null);
    } else {
      _exitSnapshot = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => shot.dispose());
  }

  /// 发起 PageView 当前画面的退场快照。
  ///
  /// 同步部分只克隆当前图层（构建 scene），栅格化在引擎线程完成：调用方
  /// 不能等待它再跳页，否则慢后端会把换页阻塞到栅格化结束。取帧失败
  /// 返回 null（退化为旧行为：只有新页滑入）。
  Future<ui.Image>? _startViewportCapture() {
    try {
      final boundary = _viewportKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary || boundary.debugNeedsPaint) {
        return null;
      }
      // 快照只用于 300ms 过渡：DPR 封顶 2、总像素封顶 ~6MP，
      // 避免大窗口每次切页产生上百 MB 的临时纹理。
      final size = boundary.size;
      final byArea =
          size.isEmpty ? 1.0 : math.sqrt(6.0e6 / (size.width * size.height));
      final ratio = math.min(
          MediaQuery.devicePixelRatioOf(context), math.min(2.0, byArea));
      return boundary.toImage(pixelRatio: ratio);
    } catch (_) {
      return null;
    }
  }

  /// 帧后执行跨页跳转：先发起退场快照（同步只克隆图层），随即跳页并
  /// 启动动画；栅格化在引擎线程完成，快照就绪后按当前进度插入。
  ///
  /// 控制器暂时未挂载（页面树重挂载的瞬间）时下帧重试，绝不让
  /// `section` 已变而 PageView 停在旧页。
  void _scheduleFarTransition([int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_ctrl.hasClients) {
        if (attempt < 4) _scheduleFarTransition(attempt + 1);
        return;
      }
      // 落点以当前分组的实时值为准：即使期间又有新目标，也先让
      // PageView 与 section 对齐，避免两者永久错位。
      final to = _indexOf(context.read<NavigationProvider>().section);
      final gen = ++_farGen;
      final pending = _startViewportCapture();
      _enterCtrl.forward(from: 0);
      _ctrl.jumpToPage(to);
      if (pending == null) return;
      pending.then((shot) {
        if (!mounted || gen != _farGen || !_enterCtrl.isAnimating) {
          shot.dispose();
          return;
        }
        setState(() => _exitSnapshot = shot);
      }, onError: (Object _) {});
    });
  }

  /// 依据 PageView 拖拽/吸附与入场动画状态刷新门控的「过渡中」信号。
  void _refreshTransitionSignal() {
    final gate = _gate;
    if (gate == null) return;
    final scrolling =
        _ctrl.hasClients && _ctrl.position.isScrollingNotifier.value;
    gate.setTransitioning(scrolling || _enterCtrl.isAnimating);
  }

  /// 控制器页码（含拖拽小数）同步给顶栏，顶栏据此跟手高亮/滚动。
  void _syncOffset() {
    if (!_ctrl.hasClients) return;
    final nav = context.read<NavigationProvider>();
    nav.pageOffset.value = _ctrl.page ?? _applied.toDouble();
    _refreshTransitionSignal();
  }

  void _onPageChanged(int i) {
    _applied = i;
    _programmatic = false;
    context.read<NavigationProvider>().select(NavSection.values[i]);
  }

  /// 手指是否正在拖动 PageView（松手后的吸附/惯性不算）。
  ///
  /// 不能用 `isScrollingNotifier`：它在松手后的吸附阶段仍为 true（页码视觉
  /// 已落定后还要持续数百毫秒）。若用它拦截，滑动后立刻点 tab 会被跳过且
  /// 永不补执行——表现为 tab 已切换、内容停在旧页（历史 bug）。
  bool _dragging = false;

  /// 记录拖拽状态；滚动结束（吸附/惯性落定）时补一次被跳过的分组切换，
  /// 避免 `section` 与页码永久错位。
  bool _onPagerScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification) {
      _dragging = n.dragDetails != null;
    } else if (n is ScrollUpdateNotification) {
      // 松手后的吸附/惯性滚动不带 dragDetails。
      if (n.dragDetails == null) _dragging = false;
    } else if (n is ScrollEndNotification) {
      _dragging = false;
      final target = _indexOf(context.read<NavigationProvider>().section);
      if (target != _applied) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_dragging) setState(() {});
        });
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T009）：Pager 只关注目标 `section`；拖拽期跟手页码由 pageOffset
    // （ValueNotifier）独立驱动。
    final nav = context.read<NavigationProvider>();
    final section =
        context.select<NavigationProvider, NavSection>((n) => n.section);
    final transition =
        context.watch<DirectSourceManager>().settings.playerTransition;
    final target = _indexOf(section);

    // 非滑动档：单页按设置过渡（松手触发切换）；顶栏高亮随后同步。
    // 滑动档：跟手 PageView，顶栏由控制器监听逐帧同步。
    if (transition != PlayerTransition.slide) {
      _slideActive = false;
      _programmatic = false;
      _applied = target;
      _enterCtrl.stop();
      // 先清快照再落值：value=1 会同步触发 completed 监听里的 setState。
      _clearExitSnapshot();
      _enterCtrl.value = 1;
      if (nav.pageOffset.value != target.toDouble()) {
        final t = target.toDouble();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && nav.pageOffset.value != t) nav.pageOffset.value = t;
        });
      }
      final page = KeyedSubtree(key: ValueKey(target), child: _pages[target]);
      if (transition == PlayerTransition.none) {
        return SectionSwipe(child: page);
      }
      return SectionSwipe(
        child: AnimatedSwitcher(
          duration: kPageMotion,
          switchInCurve: kPageMotionCurve,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) => pageTransition(
              transition, child, anim,
              backdrop: Theme.of(context).scaffoldBackgroundColor),
          child: page,
        ),
      );
    }

    // 从非滑动档切回：控制器可能停留在旧页，首帧对齐到当前分组。
    if (!_slideActive) {
      _slideActive = true;
      _applied = target;
      _programmatic = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ctrl.hasClients && _ctrl.page?.round() != target) {
          _ctrl.jumpToPage(target);
        }
      });
    }

    if (target != _applied) {
      // 手指拖拽中跳过，避免拽手指（拖拽结束由 [_onPagerScroll] 补对齐）；
      // 程序飞行中可重定向。
      if (!_dragging || _programmatic) {
        // 上一段入场动画未跑完：先落定，再按新目标重排。
        _enterCtrl.stop();
        // 先清快照再落值：value=1 会同步触发 completed 监听里的 setState。
        _clearExitSnapshot();
        _enterCtrl.value = 1;
        final current =
            _ctrl.hasClients ? (_ctrl.page?.round() ?? _applied) : _applied;
        _programmatic = true;
        _applied = target;
        if (_ctrl.hasClients && (target - current).abs() > 1) {
          // 跨多页：截旧页快照 → 跳页 → 快照与目标页反向同步滑动，
          // 不再高速扫过中间分组，也不会出现“旧页瞬间消失”的空白帧。
          // 方向必须在本次 build 内落位：退场/进场 Tween 在 build 时读取
          // _enterDir，帧后回调只改字段不会触发重建（section 未变，select
          // 不标记本组件重建），动画会沿用上一次的方向——
          // 历史 bug：反向跨页也从右滑入（方向滞后一跳）。
          // jumpToPage 同步通知会踩 build 期 markNeedsBuild，仍放到帧后执行。
          _enterDir = target > current ? 1 : -1;
          _scheduleFarTransition();
        } else if (_ctrl.hasClients) {
          _ctrl.animateToPage(target,
              duration: kPageMotion, curve: kPageMotionCurve);
        } else {
          // PageView 暂时未挂载：挂载后直接对齐到当前分组。
          _scheduleFarTransition();
        }
      }
    } else if (_slideActive &&
        !_enterCtrl.isAnimating &&
        _ctrl.hasClients &&
        !_ctrl.position.isScrollingNotifier.value &&
        (_ctrl.page?.round() ?? target) != target) {
      // 兜底自愈：静止态页码与分组不一致（上一次跳转被重挂载/异常打断），
      // 帧后补一次对齐，避免“tab 已变、内容停在旧页”的永久错位。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ctrl.hasClients && _ctrl.page?.round() != target) {
          _ctrl.jumpToPage(target);
        }
      });
    }

    final pageView = SlideTransition(
      position: _enterCurve.drive(Tween<Offset>(
          begin: Offset(_enterDir.toDouble(), 0), end: Offset.zero)),
      child: RepaintBoundary(
        // 退场快照的取景边界：在进场位移之内，截到的是未位移的整页。
        key: _viewportKey,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onPagerScroll,
          child: PageView(
            controller: _ctrl,
            onPageChanged: _onPageChanged,
            // 首次横滑前预构建左右邻页（只建可见范围的行），降低滑动首帧构建开销。
            allowImplicitScrolling: _warmNeighbors,
            // 每页独立图层：横滑期间页面平移只重合成、不重栅格化（降低滑动掉帧）。
            children: [for (final p in _pages) RepaintBoundary(child: p)],
          ),
        ),
      ),
    );
    final shot = _exitSnapshot;
    if (shot == null) return pageView;
    // 快照 0 → -dir 退出，PageView dir → 0 进入：两页同速反向、首尾相接。
    return Stack(
      fit: StackFit.expand,
      children: [
        pageView,
        IgnorePointer(
          child: SlideTransition(
            position: _enterCurve.drive(Tween<Offset>(
                begin: Offset.zero, end: Offset(-_enterDir.toDouble(), 0))),
            child: ExcludeSemantics(
              child: RawImage(
                image: shot,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.low,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
