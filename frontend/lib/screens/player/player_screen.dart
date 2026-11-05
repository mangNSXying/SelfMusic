import 'dart:async';

import 'dart:io';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import 'package:wakelock_plus/wakelock_plus.dart';

import '../../layout/player_metrics.dart';
import '../../providers/player_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/navigation_provider.dart';
import '../../services/bluetooth_service.dart';
import '../../utils/focus_utils.dart';
import '../../utils/motion.dart';
import '../../utils/perf_log.dart';
import '../../widgets/player_sheet_anim.dart';
import '../../widgets/song_list.dart';

import 'player_band.dart';
import 'player_layouts.dart';
import 'player_now_playing.dart';
import 'queue_page.dart';

bool useDesktopLandscape(Size size, {required bool isDesktopPlatform}) =>
    isDesktopPlatform || size.width >= 1000;

/// 全屏播放页（ui-playpage.html v5）：作为「首页」整屏展示，替换整个壳层。
///
/// 手势交互（可在设置中关闭）：
/// - 播放页/歌词页横向跟手互切（PageView 原生：跟手 + 速度/位置裁决）；
/// - 播放页【下滑跟手】整页随手指下移返回列表（松手吸附/离场，横屏仅手机
///   三列的非歌词区支持，桌面双栏左列可滚动故不接，避免与滚动打架）；
/// - 歌词页纵向滚动，右滑或按钮返回播放页；
/// - 底部迷你栏【上滑跟手】播放页从底部升起。
///
/// 桌面 ESC：在播放页（第 1 页，横竖屏不分）按 ESC 返回内容页；输入框聚焦时
/// 第一次只失焦，歌单/歌词页不拦截。悬浮层常驻挂载（非路由），系统返回管不到
/// 桌面 ESC，故经 CallbackShortcuts 自行处理。
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, this.desktopPlatformOverride});

  /// 布局回归测试用：固定平台判定，避免测试宿主（Linux）恒走桌面分支。
  @visibleForTesting
  final bool? desktopPlatformOverride;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// 冷启动首帧定位：只记第一次挂载。
  static bool _bootLogged = false;

  late final PageController _pageCtrl;

  /// 播放页下拉跟手的起点（全局 Y + 起始进度）。
  double _dragStartY = 0;
  double _dragStartP = 0;

  /// 桌面 ESC 键的焦点：悬浮层常驻挂载在 Stack 内（非路由），系统返回管不到
  /// 桌面 ESC；播放页可见时把焦点接过来，ESC 经 CallbackShortcuts 到达。
  /// 不用 autofocus——首挂载即抢焦点会干扰启动，只在可见切换时接一次。
  final FocusNode _escFocus = FocusNode(debugLabel: 'playerEsc');

  /// 播放页控件静置自动隐藏（改进.txt UI3）：无操作 N 秒后隐藏
  /// 左上返回箭头与封面右上「更多」。触摸即恢复并重新计时。
  bool _controlsHidden = false;
  bool _prevPlayerView = true;
  int _autoHideSec = 0;
  Timer? _autoHideTimer;

  /// 歌单页（PageView 第 0 页）追焦信号：每次进入歌单页递增，页内列表
  /// （[QueuePage]/[SongList]）据此重新定位到当前播放歌曲——邻页预热保活后
  /// 重进不重挂载，只靠挂载追焦（initialScrollOffset）不够。
  final ValueNotifier<int> _bandFocusTick = ValueNotifier<int>(0);

  List<Widget>? _closingPages;

  /// 首页横滑带返回：监听导航层的「回播放页」请求。
  NavigationProvider? _nav;
  VoidCallback? _homeBandListener;

  /// 当前停留的横滑带页（0=歌单 / 1=播放 / 2=歌词，横屏无第 2 页）。
  int _bandPage = 1;

  /// 是否停在播放页（播放器带的第 1 页，竖屏分页/横屏整页同位置）——
  /// 只在播放页上计时隐藏。
  bool get _onPlayerPage =>
      _pageCtrl.hasClients && (_pageCtrl.page ?? 1).round() == 1;

  /// 歌单页/播放页/歌词页已并入同一条横向跟手带（PageView），右滑进歌单页
  /// 由原生翻页接管（与播放↔歌词一致），不再需要被动右滑追踪。
  void _onBandPointerDown(PointerDownEvent _) {
    _rearmAutoHide();
  }

  /// 横滑带翻页（边缘箭头与快捷键共用）。
  void _goToBandPage(int page) {
    if (!_pageCtrl.hasClients) return;
    if ((_pageCtrl.page ?? 1).round() == page) return;
    _rearmAutoHide();
    _pageCtrl.animateToPage(
      page,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 按方向翻一页；窗口朝向决定页数（横屏两页、竖屏三页）。
  void _stepBandPage(int delta) {
    if (!mounted) return;
    if (!context.read<NavigationProvider>().playerView) return;
    if (primaryFocusIsTextInput()) return;
    final size = MediaQuery.sizeOf(context);
    final pageCount = size.width > size.height ? 2 : 3;
    final current = _bandPage.clamp(0, pageCount - 1);
    final target = (current + delta).clamp(0, pageCount - 1);
    if (target == current) return;
    _goToBandPage(target);
  }

  /// 屏幕常亮目标值与已应用值；合并调度标记。
  bool _wantWake = false;
  bool _wakeApplied = false;
  bool _platformSyncScheduled = false;

  /// 常亮蓝牙门控：限定设备时轮询其连接状态，任一选中设备连接期间保持常亮。
  final BluetoothService _bt = BluetoothService();
  List<BtDevice> _wakeDevices = const [];
  bool _btDeviceConnected = true;
  bool _btPermissionWarned = false;
  Timer? _btPoll;

  /// 首帧空闲后开启相邻页预构建（allowImplicitScrolling 给 PageView 一屏
  /// cacheExtent）：邻页 State 不再「滑走即销毁、滑回重装」——歌单页每次
  /// 重进都要同步装配整单数据（曾实测 1310 首卡在拖拽帧里 141~195ms），
  /// 保活后只在首挂载装配一次且发生在空闲帧。与 library_screen 六分组
  /// PageView 同一先例（内存/启动成本的折中）。
  ///
  /// 预热必须等悬浮层完全打开后再空闲一拍才触发：打开动画窗口
  /// （300ms）内同步装配邻页会饿死动画 ticker（真机实测 settle 751ms、
  /// 动画期仅 3 帧，见 player.open 埋点），这正是点击打开卡顿的根因。
  /// 而卡在 progress 归零当刻触发也不行——那正是动画最后一帧，
  /// 装配耗时（真机 maxGap 474ms）会冻住最后 <10px 的两帧位移
  /// （到顶顿一下、半秒后才落定）。故归零后倒计时 350ms（动画已定稿
  /// 且人大概率在看封面），中途被拖离顶部则取消计时。
  bool _warmNeighbors = false;
  bool _warmScheduled = false;
  bool _warmZeroSeen = false;
  Timer? _warmTimer;
  ValueNotifier<double>? _warmProgress;
  VoidCallback? _warmProgressListener;

  @override
  void initState() {
    super.initState();
    // 冷启动首帧定位：常驻悬浮层首挂载是否参与首帧阻塞（只记第一次）。
    if (!_bootLogged) {
      _bootLogged = true;
      perfLog('boot.firstBuild PlayerScreen.init');
    }
    // 临时埋点（播放页打开卡顿定位）：悬浮层每次打开都会重新挂载本页，
    // init→首帧的间隔即挂载构建成本（封面解码/歌词装配等）。
    perfLog('player.open screenInit');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      perfLog('player.open screenFirstFrame');
    });
    _pageCtrl = PageController(initialPage: 1);
    // 首帧后读取常亮设置目标值。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = context.read<DirectSourceManager>().settings;
      _scheduleWakeSync(s.playerKeepScreenOn, s.keepScreenOnDevice);
    });
    // 邻页预热推迟到完全打开且空闲 350ms 后（见 _warmNeighbors 注释）：
    // 已到顶（拖拽带满才松手 / 中断重进）直接开始倒计时，否则等进度归零；
    // 800ms 是最后兜底（吸附被打断停在半程等边缘情况）。300ms 内滑向邻页
    // 仍按需构建，无回归。
    final nav = context.read<NavigationProvider>();
    _nav = nav;
    _homeBandListener = _onHomeBandRequest;
    nav.homeBandRequests.addListener(_homeBandListener!);
    nav.reportHomeBand(1);
    _warmProgress = nav.playerProgress;
    if (nav.playerProgress.value <= 0.001) {
      _warmZeroSeen = true;
      _kickWarmTimer();
    } else {
      void onProgress() {
        if (_warmScheduled || !mounted) return;
        final v = _warmProgress?.value ?? 1;
        if (v <= 0.001) {
          // 刚到顶：开始 350ms 空闲倒计时（动画最后一帧，不直接装配）。
          if (!_warmZeroSeen) {
            _warmZeroSeen = true;
            _kickWarmTimer();
          }
        } else {
          // 被拖离顶部（下滑关闭等）：取消倒计时，避免在交互中途引爆重活。
          _warmZeroSeen = false;
          _warmTimer?.cancel();
          _warmTimer = null;
        }
      }

      _warmProgressListener = onProgress;
      nav.playerProgress.addListener(onProgress);
    }
    _warmTimer ??= Timer(const Duration(milliseconds: 800), () {
      if (mounted) _scheduleWarmNeighbors();
    });
  }

  /// 开始/重启 350ms 空闲倒计时（到顶时刻起算）。
  void _kickWarmTimer() {
    if (_warmScheduled || !mounted) return;
    _warmTimer?.cancel();
    _warmTimer = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _scheduleWarmNeighbors();
    });
  }

  /// 触发邻页预热（幂等）：预约后顺手拆掉进度监听与兜底计时。
  void _scheduleWarmNeighbors() {
    if (_warmScheduled || !mounted) return;
    perfLog('player.neighbors warm');
    _warmScheduled = true;
    final listener = _warmProgressListener;
    if (listener != null) {
      _warmProgress?.removeListener(listener);
      _warmProgressListener = null;
    }
    _warmProgress = null;
    _warmTimer?.cancel();
    _warmTimer = null;
    setState(() => _warmNeighbors = true);
  }

  @override
  void dispose() {
    final nav = _nav;
    final bandListener = _homeBandListener;
    if (nav != null && bandListener != null) {
      nav.homeBandRequests.removeListener(bandListener);
    }
    _nav = null;
    _homeBandListener = null;
    final listener = _warmProgressListener;
    if (listener != null) _warmProgress?.removeListener(listener);
    _warmProgressListener = null;
    _warmProgress = null;
    _warmTimer?.cancel();
    _btPoll?.cancel();
    _autoHideTimer?.cancel();
    _escFocus.dispose();
    // 离开播放页恢复熄屏策略（ohos 经 ohos_bootstrap 注册的平台实现生效）。
    unawaited(WakelockPlus.disable());
    _bandFocusTick.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 播放页可见性副作用（订阅收窄 T010）。
  ///
  /// 由 [build] 内的 `context.select` 订阅 `playerView`，变化时在此应用计时/控件
  /// 显隐。provider 的 `select` 仅在 `build` 中合法（`didChangeDependencies` 中会被
  /// 断言拒绝），故可见性逻辑从 didChangeDependencies 迁到 build。[inBuild] 透传以在
  /// build 期避免 `setState`。
  void _applyVisibility(bool visibility, {bool inBuild = false}) {
    final sec =
        context.read<DirectSourceManager>().settings.playerAutoHideIdleSec;
    if (sec != _autoHideSec) {
      _autoHideSec = sec;
      if (visibility) _rearmAutoHide(inBuild: inBuild);
    }
    if (!visibility) {
      // 播放页不可见（悬浮层收起/换列表页）：停表并复位显示。
      _autoHideTimer?.cancel();
      _autoHideTimer = null;
      _setControlsHidden(false, inBuild: inBuild);
      _escFocus.unfocus();
    } else {
      if (!_prevPlayerView) {
        // 从收起切回播放页：复位显示并重新计时。
        _rearmAutoHide(inBuild: inBuild);
      }
      // ESC 焦点：可见且焦点不在本页时接过来（冷启动首帧可见也走这里，
      // _prevPlayerView 初值 true 无切换分支可走）。
      if (!_escFocus.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!context.read<NavigationProvider>().playerView) return;
          if (_escFocus.hasFocus) return;
          // 弹窗/菜单打开时不抢焦点：ESC 先关它们（路由原生行为）。
          if (Navigator.of(context).canPop()) return;
          _escFocus.requestFocus();
        });
      }
    }
    _prevPlayerView = visibility;
  }

  /// 导航层要求回到播放页（返回键在歌词/歌单页时的第一跳）。
  void _onHomeBandRequest() {
    if (!mounted) return;
    final nav = _nav;
    if (nav == null || !nav.playerView) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageCtrl.hasClients) return;
      if ((_pageCtrl.page ?? 1).round() == 1) return;
      _goToBandPage(1);
    });
  }

  /// 桌面 ESC：首页子页先回播放页；播放页再进内容区。
  ///
  /// 弹窗/菜单打开时焦点在 dialog 路由内，事件到不了本页 shortcut，由路由
  /// 原生 ESC 关闭；输入框聚焦时第一次只失焦（防输入中误关，焦点交回本页后
  /// 第二次再关闭）。
  void _onEscape() {
    if (!mounted) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary != _escFocus && primaryFocusIsTextInput()) {
      primary.unfocus();
      // 焦点交回本页 ESC 节点：下一次 ESC 直接关闭（两次 ESC 关页）。
      _escFocus.requestFocus();
      return;
    }
    if (!context.read<NavigationProvider>().playerView) return;
    if (!_onPlayerPage) {
      _goToBandPage(1);
      return;
    }
    context.read<NavigationProvider>().closePlayer();
  }

  /// 播放页控件静置隐藏计时（改进.txt UI3）：任何触摸视为交互并重新计时。
  void _rearmAutoHide({bool inBuild = false}) {
    _autoHideTimer?.cancel();
    _autoHideTimer = null;
    if (!mounted) return;
    final visible = context.read<NavigationProvider>().playerView;
    if (!visible || !_onPlayerPage || _autoHideSec <= 0) {
      _setControlsHidden(false, inBuild: inBuild);
      return;
    }
    _setControlsHidden(false, inBuild: inBuild);
    _autoHideTimer = Timer(Duration(seconds: _autoHideSec), () {
      if (!mounted) return;
      if (!_onPlayerPage || !context.read<NavigationProvider>().playerView) {
        return;
      }
      _setControlsHidden(true);
    });
  }

  /// 设置控件显隐。[inBuild] 为真（build 阶段）时直接改字段——本次 build 已反映；
  /// 其余场景用 setState 触发重建。
  void _setControlsHidden(bool hidden, {bool inBuild = false}) {
    if (_controlsHidden == hidden) return;
    if (inBuild) {
      _controlsHidden = hidden;
    } else {
      setState(() => _controlsHidden = hidden);
    }
  }

  /// 设置变化时合并到下一帧；应用屏幕常亮。
  /// 常亮可限定蓝牙设备（可多选）：设备集合变化时重置连接门控并轮询。
  void _scheduleWakeSync(bool keepOn, String deviceSetting) {
    final devices = btDevicesFromSetting(deviceSetting);
    final deviceChanged = !_sameDeviceSet(devices, _wakeDevices);
    final changed = keepOn != _wantWake || deviceChanged;
    _wantWake = keepOn;
    _wakeDevices = devices;
    if (deviceChanged) {
      _btDeviceConnected = devices.isEmpty;
      _restartBtPoll();
    }
    if (!changed || _platformSyncScheduled) return;
    _platformSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _platformSyncScheduled = false;
      if (!mounted) return;
      _flushWakeLock();
    });
  }

  /// 按门控应用屏幕常亮：限定了蓝牙设备时，仅其处于连接状态才保持常亮。
  void _flushWakeLock() {
    if (!mounted) return;
    final wake = _wantWake && (_wakeDevices.isEmpty || _btDeviceConnected);
    if (wake != _wakeApplied) {
      // ohos 经 ohos_bootstrap 注册的平台实现走平台桥 keepScreenOn。
      unawaited(wake ? WakelockPlus.enable() : WakelockPlus.disable());
      _wakeApplied = wake;
    }
  }

  /// 限定设备时常亮轮询：每 5 秒核对一次连接状态（进入/离开设备即时切换）。
  void _restartBtPoll() {
    _btPoll?.cancel();
    _btPoll = null;
    if (!_wantWake || _wakeDevices.isEmpty) return;
    unawaited(_refreshBtConnection());
    _btPoll = Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(_refreshBtConnection()));
  }

  Future<void> _refreshBtConnection() async {
    final devices = _wakeDevices;
    if (devices.isEmpty) return;
    if (!await _bt.hasConnectPermission()) {
      // 权限被收回时查询恒为空，门控会把常亮判成「设备未连接」。记一条诊断日志，
      // 免得用户以为设置坏了（设置页会在申请权限时给出提示）。
      if (!_btPermissionWarned) {
        _btPermissionWarned = true;
        debugPrint('[wake] 缺少 BLUETOOTH_CONNECT 权限，蓝牙连接状态无法判定');
      }
      return;
    }
    final connected = await _bt.connectedAddresses();
    final ok = btWakeGateOpen(devices, connected);
    if (ok != _btDeviceConnected && mounted) {
      _btDeviceConnected = ok;
      _flushWakeLock();
    }
  }

  bool _sameDeviceSet(List<BtDevice> a, List<BtDevice> b) {
    if (a.length != b.length) return false;
    final addrs = {for (final d in a) d.address};
    return addrs.containsAll({for (final d in b) d.address});
  }

  /// 播放页下拉跟手：整页随手指下移，底下显露分组区；松手按位移/速度吸附或离场。
  void _onPlayerDragStart(DragStartDetails d) {
    final sheet = context.read<PlayerSheetAnimator>();
    _dragStartY = d.globalPosition.dy;
    _dragStartP = sheet.value;
    sheet.dragStart();
  }

  void _onPlayerDragUpdate(DragUpdateDetails d) {
    final h = MediaQuery.of(context).size.height;
    if (h <= 0) return;
    context
        .read<PlayerSheetAnimator>()
        .dragTo(_dragStartP + (d.globalPosition.dy - _dragStartY) / h);
  }

  void _onPlayerDragEnd(DragEndDetails d) {
    final sheet = context.read<PlayerSheetAnimator>();
    final v = d.primaryVelocity ?? 0;
    final p = sheet.value;
    if (v > 700 || p > 0.4) {
      sheet.settle(1, onDone: () {
        if (!mounted) return;
        context.read<NavigationProvider>().closePlayer();
      });
    } else {
      sheet.settle(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T010）：播放页只订阅 playerView（控制自动隐藏计时）；区段/搜索/
    // 队列等变更不再重建播放页。可见性副作用在 build 内安全应用（inBuild=true）。
    final playerView =
        context.select<NavigationProvider, bool>((n) => n.playerView);
    _applyVisibility(playerView, inBuild: true);
    final direct = context.watch<DirectSourceManager>();
    // 屏幕常亮设置：停留播放页期间应用（变化时下一帧生效）。
    _scheduleWakeSync(
        direct.settings.playerKeepScreenOn, direct.settings.keepScreenOnDevice);
    final player = context.watch<PlayerProvider>();
    final size = MediaQuery.sizeOf(context);
    // 横屏（宽>高）分两套（UI10 平台差异化）：
    // - 桌面（Linux/Windows/macOS）或超宽屏（大平板）：双栏居中布局，避免
    //   手机版三列被大窗口拉散（控制键散布整屏高、内容缩在角落）；
    // - 手机横屏：三列紧凑布局，贴合 ui-playpage-wide.html 稿。
    final landscape = size.width > size.height;
    final desktopLandscape = useDesktopLandscape(size,
        isDesktopPlatform: widget.desktopPlatformOverride ??
            (Platform.isLinux || Platform.isWindows || Platform.isMacOS));

    // 播放页控件静置隐藏（改进.txt UI3）：任何触摸都视为交互并重新计时。
    // 歌单页/播放页/歌词页同一页横滑带，进入歌单页由 PageView 原生右滑接管。
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _onEscape,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () =>
            _stepBandPage(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () =>
            _stepBandPage(1),
      },
      // 祖先焦点：子孙（按钮/滑杆/列表）聚焦时快捷键仍冒泡到此；弹窗路由内
      // 的焦点不在本子树，不会误触发（ESC 先关弹窗）。
      child: Focus(
        focusNode: _escFocus,
        child: Scaffold(
          body: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _onBandPointerDown,
            // 横屏铺满到屏幕底：不再让出底部系统手势条（横屏三列控件不与居中的
            // 手势条重叠），与壳层内容区（removePadding 铺满）观感一致；竖屏保留
            // 底部安全区——底部控制行居中，会与手势条打架。
            child: SafeArea(
              bottom: !landscape,
              child: PlayerControlsHidden(
                hidden: _controlsHidden,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final pageSize = constraints.biggest;
                    final mediaSize = MediaQuery.sizeOf(context);
                    return PageView(
                      // 横向由内层 PageView 原生跟手（右滑回播放页/进歌单页）；
                      // 竖向仅播放页（第 1 页）跟手下拉，歌词页纵向留给滚动。
                      controller: _pageCtrl,
                      // 完全打开后置 true：预构建/保活左右邻页（见 _warmNeighbors 注释）。
                      allowImplicitScrolling: _warmNeighbors,
                      physics: const PageScrollPhysics(),
                      // 预热前滑向邻页：即时补建，避免白板（空闲仍是主触发，见 C）。
                      onPageChanged: (i) {
                        _bandPage = i;
                        context.read<NavigationProvider>().reportHomeBand(i);
                        if (i != 1 && mounted) _scheduleWarmNeighbors();
                        // 进入歌单页（左邻页）：要求页内列表重新追焦当前播放歌曲
                        // （首歌单页可能已保活挂载，换歌后再进不会重挂载）。
                        if (i == 0) _bandFocusTick.value++;
                      },
                      children: _pagesFor(
                          playerView,
                          () => [
                                // 首帧避让（C）：邻页首帧占位，空闲预热后再装配——歌单页整单
                                // 装配（1310 首曾测 ~150ms）移出首帧；页数恒定（横屏 2 / 竖屏 3），
                                // PageController initialPage=1 不受影响。
                                BandEdgeNav(
                                  nextTooltip: '播放页',
                                  onNext: () => _goToBandPage(1),
                                  child: KeyedSubtree(
                                    key: const ValueKey('player-page-songs'),
                                    child: _warmNeighbors
                                        ? (landscape
                                            // 横屏歌单页为「左歌单右播放」分栏：滑动 settle 后左右同显，
                                            // 与横屏整页「左播放右歌词」同理；竖屏仍为整页歌单。
                                            // 左上角返回箭头悬浮于分栏之上（与横屏播放页一致）。
                                            ? Stack(
                                                children: [
                                                  Positioned.fill(
                                                    child: desktopLandscape
                                                        ? DesktopPlaylistSplit(
                                                            player: player,
                                                            direct: context.watch<
                                                                DirectSourceManager>(),
                                                            cs: Theme.of(
                                                                    context)
                                                                .colorScheme,
                                                            focusTick:
                                                                _bandFocusTick)
                                                        : LandscapePlaylistSplit(
                                                            player: player,
                                                            direct: context.watch<
                                                                DirectSourceManager>(),
                                                            cs: Theme.of(
                                                                    context)
                                                                .colorScheme,
                                                            focusTick:
                                                                _bandFocusTick),
                                                  ),
                                                  const Positioned(
                                                      top: 6,
                                                      left: 6,
                                                      child:
                                                          BackToContentButton()),
                                                ],
                                              )
                                            : BandSongPage(
                                                focusTick: _bandFocusTick))
                                        : const SizedBox.shrink(),
                                  ),
                                ),
                                BandEdgeNav(
                                  previousTooltip: '歌单',
                                  onPrevious: () => _goToBandPage(0),
                                  nextTooltip: landscape ? null : '歌词',
                                  onNext:
                                      landscape ? null : () => _goToBandPage(2),
                                  child: AnimatedSwitcher(
                                    key: const ValueKey('player-page-main'),
                                    duration: kPageMotion,
                                    switchInCurve: kPageMotionCurve,
                                    switchOutCurve: Curves.easeInCubic,
                                    layoutBuilder:
                                        (currentChild, previousChildren) =>
                                            Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        for (final child in previousChildren)
                                          IgnorePointer(child: child),
                                        if (currentChild != null) currentChild,
                                      ],
                                    ),
                                    transitionBuilder: (child, animation) {
                                      final scale =
                                          Tween<double>(begin: 0.985, end: 1.0)
                                              .animate(CurvedAnimation(
                                                  parent: animation,
                                                  curve: kPageMotionCurve));
                                      return FadeTransition(
                                        opacity: animation,
                                        child: ScaleTransition(
                                            scale: scale, child: child),
                                      );
                                    },
                                    child: PlayerOrientationFrame(
                                      key: ValueKey(
                                          'player-main-${landscape ? 'land' : 'port'}-${desktopLandscape ? 'desk' : 'touch'}'),
                                      frameSize: pageSize,
                                      mediaSize: mediaSize,
                                      child: _buildPlayerPage(
                                        player: player,
                                        direct: direct,
                                        cs: Theme.of(context).colorScheme,
                                        landscape: landscape,
                                        desktopLandscape: desktopLandscape,
                                      ),
                                    ),
                                  ),
                                ),
                                if (!landscape)
                                  BandEdgeNav(
                                    previousTooltip: '播放页',
                                    onPrevious: () => _goToBandPage(1),
                                    child: KeyedSubtree(
                                      key: const ValueKey('player-page-lyrics'),
                                      child: _warmNeighbors
                                          ? const LyricsPage()
                                          : const SizedBox.shrink(),
                                    ),
                                  ),
                              ]),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayerPage({
    required PlayerProvider player,
    required DirectSourceManager direct,
    required ColorScheme cs,
    required bool landscape,
    required bool desktopLandscape,
  }) {
    if (landscape) {
      // 横屏无歌词分页（歌词内嵌）：「左歌单右播放」分栏与整幅播放
      // 布局两页滑动；左上角返回箭头悬浮于两套横屏布局之上。
      // 下滑返回内容页仅手机三列的播放列接（桌面左列自身可滚动，
      // 包 detector 会吃掉矮窗口滚动，故不接，桌面用 ESC/按钮返回）。
      return Stack(
        children: [
          desktopLandscape
              ? DesktopLandscapePlayer(player: player, direct: direct, cs: cs)
              : LandscapePlayer(
                  player: player,
                  direct: direct,
                  cs: cs,
                  onVerticalDragStart: _onPlayerDragStart,
                  onVerticalDragUpdate: _onPlayerDragUpdate,
                  onVerticalDragEnd: _onPlayerDragEnd,
                ),
          const Positioned(top: 6, left: 6, child: BackToContentButton()),
        ],
      );
    }
    return Stack(
      // 箭头悬浮在播放页内容之上（不占布局空间，不压缩封面）；
      // 歌词页（第 2 页）按先前要求不再放箭头。
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: _onPlayerDragStart,
          onVerticalDragUpdate: _onPlayerDragUpdate,
          onVerticalDragEnd: _onPlayerDragEnd,
          child: _buildPlayerBody(context),
        ),
        const Positioned(top: 6, left: 6, child: BackToContentButton()),
      ],
    );
  }

  List<Widget> _pagesFor(bool playerView, List<Widget> Function() build) {
    if (!playerView && _closingPages != null) return _closingPages!;
    return _closingPages = build();
  }

  /// 自适应播放页：整页不滚动，封面尺寸按可用空间计算以恰好放满一屏。
  Widget _buildPlayerBody(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();

    final m = PlayerMetrics.portrait(MediaQuery.sizeOf(context));

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: m.contentMaxWidth + m.edgePadding * 2,
        ),
        child: Padding(
          padding: EdgeInsets.all(m.edgePadding),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final byHeight = constraints.maxHeight - m.fixedContentHeight;
              final coverSize = math.min(
                m.targetCover,
                math.min(
                  constraints.maxWidth,
                  math.max(0.0, byHeight),
                ),
              );
              return player.hasCurrent
                  ? NowPlaying(
                      player: player,
                      direct: direct,
                      cs: Theme.of(context).colorScheme,
                      coverSize: coverSize,
                      scale: m.uiScale,
                    )
                  : PlayerEmptyState(
                      coverSize: coverSize,
                      scale: m.uiScale,
                    );
            },
          ),
        ),
      ),
    );
  }
}
