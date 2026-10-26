import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../layout/player_metrics.dart';
import '../models/song.dart';
import '../data/sources/music_source.dart' show SourceLine, parseSourceLine;
import '../providers/player_provider.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/playlists_provider.dart';
import 'queue_page.dart';
import '../services/bluetooth_service.dart';
import '../utils/duration_format.dart';
import '../utils/focus_utils.dart';
import '../utils/motion.dart';
import '../utils/perf_log.dart';
import '../utils/song_title_format.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/app_toast.dart';
import '../widgets/edit_song_meta_dialog.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/marquee_text.dart';
import '../widgets/online_meta_dialog.dart';
import '../widgets/pressable.dart';
import '../widgets/player_sheet_anim.dart';
import '../widgets/sleep_timer_dialog.dart';
import '../widgets/song_info_dialog.dart';
import '../widgets/song_list.dart';

/// 横屏播放页布局分流（UI10 平台差异化）：
/// 桌面平台（鼠标+大窗口）或超宽屏（≥1000，大平板）→ 双栏居中布局；
/// 手机等窄屏横屏 → 三列紧凑布局（ui-playpage-wide.html）。
@visibleForTesting
bool useDesktopLandscape(Size size, {required bool isDesktopPlatform}) =>
    isDesktopPlatform || size.width >= 1000;

TextStyle? _scaleTextStyle(TextStyle? style, double scale) {
  final size = style?.fontSize;
  if (style == null || size == null) return style;
  return style.copyWith(fontSize: size * scale);
}

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

  /// 是否停在播放页（播放器带的第 1 页，竖屏分页/横屏整页同位置）——
  /// 只在播放页上计时隐藏。
  bool get _onPlayerPage =>
      _pageCtrl.hasClients && (_pageCtrl.page ?? 1).round() == 1;

  /// 歌单页/播放页/歌词页已并入同一条横向跟手带（PageView），右滑进歌单页
  /// 由原生翻页接管（与播放↔歌词一致），不再需要被动右滑追踪。
  void _onBandPointerDown(PointerDownEvent _) {
    _rearmAutoHide();
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

  /// 桌面 ESC 返回内容页（横竖屏播放页都生效，仅播放页）。
  ///
  /// 弹窗/菜单打开时焦点在 dialog 路由内，事件到不了本页 shortcut，由路由
  /// 原生 ESC 关闭；输入框聚焦时第一次只失焦（防输入中误关，焦点交回本页后
  /// 第二次再关闭）；歌单/歌词页不拦截（避免与横滑带手势语义混乱）。
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
    if (!_onPlayerPage) return;
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
    final gestureOn = direct.settings.playerGestureSwipe;
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
              child: _PlayerControlsHidden(
                hidden: _controlsHidden,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final pageSize = constraints.biggest;
                    final mediaSize = MediaQuery.sizeOf(context);
                    return PageView(
                      // 横向由内层 PageView 原生跟手（右滑回播放页/进歌单页）；
                      // 竖向仅播放页（第 1 页）跟手下拉，歌词页纵向留给滚动。
                      // 关闭手势后 PageView 禁滑、下拉停用。
                      controller: _pageCtrl,
                      // 完全打开后置 true：预构建/保活左右邻页（见 _warmNeighbors 注释）。
                      allowImplicitScrolling: _warmNeighbors,
                      physics: gestureOn
                          ? const PageScrollPhysics()
                          : const NeverScrollableScrollPhysics(),
                      // 预热前滑向邻页：即时补建，避免白板（空闲仍是主触发，见 C）。
                      onPageChanged: (i) {
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
                                KeyedSubtree(
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
                                                          cs: Theme.of(context)
                                                              .colorScheme,
                                                          focusTick:
                                                              _bandFocusTick)
                                                      : LandscapePlaylistSplit(
                                                          player: player,
                                                          direct: context.watch<
                                                              DirectSourceManager>(),
                                                          cs: Theme.of(context)
                                                              .colorScheme,
                                                          focusTick:
                                                              _bandFocusTick),
                                                ),
                                                const Positioned(
                                                    top: 6,
                                                    left: 6,
                                                    child:
                                                        _BackToContentButton()),
                                              ],
                                            )
                                          : _BandSongPage(
                                              focusTick: _bandFocusTick))
                                      : const SizedBox.shrink(),
                                ),
                                AnimatedSwitcher(
                                  key: const ValueKey('player-page-main'),
                                  duration: kPageMotion,
                                  switchInCurve: kPageMotionCurve,
                                  switchOutCurve: Curves.easeInCubic,
                                  layoutBuilder:
                                      (currentChild, previousChildren) => Stack(
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
                                  child: _OrientationFrame(
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
                                      gestureOn: gestureOn,
                                    ),
                                  ),
                                ),
                                if (!landscape)
                                  KeyedSubtree(
                                    key: const ValueKey('player-page-lyrics'),
                                    child: _warmNeighbors
                                        ? const _LyricsPage()
                                        : const SizedBox.shrink(),
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
    required bool gestureOn,
  }) {
    if (landscape) {
      // 横屏无歌词分页（歌词内嵌）：「左歌单右播放」分栏与整幅播放
      // 布局两页滑动；左上角返回箭头悬浮于两套横屏布局之上。
      // 下滑返回内容页仅手机三列的播放列接（桌面左列自身可滚动，
      // 包 detector 会吃掉矮窗口滚动，故不接，桌面用 ESC/按钮返回）。
      return Stack(
        children: [
          desktopLandscape
              ? _DesktopLandscapePlayer(player: player, direct: direct, cs: cs)
              : LandscapePlayer(
                  player: player,
                  direct: direct,
                  cs: cs,
                  onVerticalDragStart: gestureOn ? _onPlayerDragStart : null,
                  onVerticalDragUpdate: gestureOn ? _onPlayerDragUpdate : null,
                  onVerticalDragEnd: gestureOn ? _onPlayerDragEnd : null,
                ),
          const Positioned(top: 6, left: 6, child: _BackToContentButton()),
        ],
      );
    }
    return Stack(
      // 箭头悬浮在播放页内容之上（不占布局空间，不压缩封面）；
      // 歌词页（第 2 页）按先前要求不再放箭头。
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onVerticalDragStart: gestureOn ? _onPlayerDragStart : null,
          onVerticalDragUpdate: gestureOn ? _onPlayerDragUpdate : null,
          onVerticalDragEnd: gestureOn ? _onPlayerDragEnd : null,
          child: _buildPlayerBody(context),
        ),
        const Positioned(top: 6, left: 6, child: _BackToContentButton()),
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
    // 手势关闭时 PageView 禁滑，歌单页无法右滑进入：封面「更多」菜单补
    // 「歌单」入口，点按跳转第 0 页。
    final onOpenSongs = direct.settings.playerGestureSwipe
        ? null
        : () {
            _rearmAutoHide();
            _pageCtrl.animateToPage(0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut);
          };

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
                  ? _NowPlaying(
                      player: player,
                      direct: direct,
                      cs: Theme.of(context).colorScheme,
                      coverSize: coverSize,
                      scale: m.uiScale,
                      onOpenSongs: onOpenSongs,
                    )
                  : _EmptyState(
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

/// 横竖屏切换时把旧布局按原尺寸等比缩放后淡出，避免直接吃新约束被拉伸。
///
/// 旧子树的 frameSize/mediaSize 是它上一帧作为当前朝向时捕获的；新子树用
/// 当前尺寸，FittedBox 保持 1:1。切换动画结束后旧子树销毁。
class _OrientationFrame extends StatelessWidget {
  final Size frameSize;
  final Size mediaSize;
  final Widget child;

  const _OrientationFrame({
    super.key,
    required this.frameSize,
    required this.mediaSize,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: frameSize.width,
        height: frameSize.height,
        child: MediaQuery(
          data: media.copyWith(size: mediaSize),
          child: child,
        ),
      ),
    );
  }
}

/// 播放页控件静置隐藏标记（改进.txt UI3）：下行控件据此淡出并停止响应。
/// 用 InheritedWidget 避免把状态穿过 _NowPlaying/横屏两套玩家组件层层下传。
class _PlayerControlsHidden extends InheritedWidget {
  final bool hidden;
  const _PlayerControlsHidden({required this.hidden, required super.child});

  static bool isHidden(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_PlayerControlsHidden>()
          ?.hidden ??
      false;

  @override
  bool updateShouldNotify(_PlayerControlsHidden old) => hidden != old.hidden;
}

/// 播放器带的「歌单页」（PageView 首页，左邻播放页）。
///
/// - 有绑定歌单（[PlayerProvider.syncPlaylistUuid] 非空且本地存在）：展示该
///   持久化歌单——与内容区歌单详情共用 [SongList]，同源、同行形态、同写回
///   语义（移除/上移/下移会改写真实歌单并联动播放器）；保留「播放 / 从头播放」
///   按钮；**无**左上返回箭头与右上关闭（横向滑动即返回播放页，切换体验与
///   播放页↔歌词页一致）。
/// - 无绑定歌单（全部歌曲/喜欢/专辑/歌手/播放源点播）：兜底展示运行时播放
///   队列（[QueuePage]），其行同样为完整形态。
/// - [embedded] 为真时队列走无 Scaffold/AppBar 的嵌入式（[SongList] 本就是
///   Column，可直接嵌），供横屏「左歌单右播放」分栏的左栏复用。
class _BandSongPage extends StatelessWidget {
  final bool embedded;

  /// 重进歌单页的追焦信号（见 [_PlayerScreenState._bandFocusTick]），透传给
  /// 页内列表（[QueuePage]/[SongList]）。
  final ValueListenable<int>? focusTick;
  const _BandSongPage({this.embedded = false, this.focusTick});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final uuid = player.syncPlaylistUuid;
    if (uuid == null) {
      return QueuePage(embedded: embedded, focusTick: focusTick);
    }
    final pid =
        context.watch<PlaylistsProvider>().store.index.playlistIdOfUuid(uuid);
    if (pid == null) {
      return QueuePage(embedded: embedded, focusTick: focusTick);
    }
    return SongList(playlistId: pid, focusTick: focusTick);
  }
}

/// 播放页左上角「回到内容页」向下箭头：悬浮覆盖（Positioned 入 Stack），
/// 不参与布局，因此不压缩封面及其他内容的显示空间；点击与下滑返回同路径
/// （置意图位 → Root 驱动悬浮层下降动画）。恒素显，无圆形底/阴影。
/// 静置隐藏时淡出并忽略命中。
class _BackToContentButton extends StatelessWidget {
  const _BackToContentButton();

  @override
  Widget build(BuildContext context) {
    final hidden = _PlayerControlsHidden.isHidden(context);
    return IgnorePointer(
      ignoring: hidden,
      child: AnimatedOpacity(
        opacity: hidden ? 0 : 1,
        duration: const Duration(milliseconds: 200),
        child: IconButton(
          tooltip: '回到内容页',
          iconSize: 26,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
          onPressed: () => context.read<NavigationProvider>().closePlayer(),
        ),
      ),
    );
  }
}

/// 歌词页：LRC 同步滚动歌词（右滑/按钮返回播放页）。
class _LyricsPage extends StatelessWidget {
  const _LyricsPage();

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();
    final cs = Theme.of(context).colorScheme;
    final s = player.current;
    final size = MediaQuery.sizeOf(context);
    final m = PlayerMetrics.portrait(size);
    final scale = m.uiScale;
    final maxWidth = math.min(size.width, math.max(480.0, 720.0 * scale));

    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Column(
          children: [
            if (s != null)
              Padding(
                padding:
                    EdgeInsets.fromLTRB(24 * scale, 28 * scale, 24 * scale, 0),
                child: _TitleBlock(
                    player: player,
                    direct: direct,
                    compact: true,
                    scale: scale),
              ),
            SizedBox(height: 6 * scale),
            Expanded(
              child: s == null
                  ? Center(
                      child: Text('暂无歌曲',
                          style: TextStyle(
                              fontSize: 14 * scale,
                              color: cs.onSurface.withValues(alpha: 0.5))),
                    )
                  : LyricsView(player: player, scale: scale),
            ),
            SizedBox(height: 8 * scale),
          ],
        ),
      ),
    );
  }
}

/// 未在播放时的首页空态。
class _EmptyState extends StatelessWidget {
  final double coverSize;
  final double scale;

  const _EmptyState({required this.coverSize, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: coverSize,
          height: coverSize,
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(24 * scale),
          ),
          child: Icon(Icons.music_note,
              size: coverSize * 0.5, color: cs.primary.withValues(alpha: 0.55)),
        ),
        SizedBox(height: 32 * scale),
        Text('未在播放',
            style: _scaleTextStyle(
                Theme.of(context).textTheme.headlineMedium, scale)),
        SizedBox(height: 8 * scale),
        Text(
          '从左侧导航选择歌曲开始播放',
          style: TextStyle(
            fontSize: 14 * scale,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }
}

/// v5 设计稿主体：封面 / 歌曲信息 / 工具行 / 进度 / 主控制行。
class _NowPlaying extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final double coverSize;
  final double scale;
  final VoidCallback? onOpenSongs;

  const _NowPlaying({
    required this.player,
    required this.direct,
    required this.cs,
    required this.coverSize,
    this.scale = 1.0,
    this.onOpenSongs,
  });

  @override
  Widget build(BuildContext context) {
    final s = player.current!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: _Cover(
              coverPath: s.coverPath,
              song: s,
              cs: cs,
              size: coverSize,
              scale: scale,
              showSongsEntry: onOpenSongs != null,
              onOpenSongs: onOpenSongs),
        ),
        SizedBox(height: 20 * scale),
        _TitleBlock(player: player, direct: direct, scale: scale),
        SizedBox(height: 8 * scale),
        _MetaLine(
            player: player, direct: direct, cs: cs, song: s, scale: scale),
        _ToolRow(player: player, direct: direct, cs: cs, song: s, scale: scale),
        _PlayerSeek(player: player, cs: cs, scale: scale),
        SizedBox(height: 6 * scale),
        _ControlRow(player: player, cs: cs, scale: scale),
      ],
    );
  }
}

/// 标题块（歌名跑马灯 + 歌手）：竖屏/横屏共用，[compact] 切紧凑字号；
/// [dense] 为横屏三列布局的更小字号（参照 ui-playpage-wide.html 15/11px）。
class _TitleBlock extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final bool compact;
  final bool dense;
  final double scale;
  const _TitleBlock(
      {required this.player,
      required this.direct,
      this.compact = false,
      this.dense = false,
      this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final s = player.current!;
    final tt = Theme.of(context).textTheme;
    final titleStyle = _scaleTextStyle(
        dense
            ? tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)
            : (compact ? tt.titleLarge : tt.headlineSmall)
                ?.copyWith(fontWeight: FontWeight.w700),
        scale);
    final artistStyle = _scaleTextStyle(
        dense ? tt.bodySmall : (compact ? tt.titleSmall : tt.titleMedium),
        scale);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MarqueeText(
          formatSongTitle(s, direct.settings.songTitleFormat),
          style: titleStyle,
        ),
        SizedBox(height: (dense ? 2 : (compact ? 4 : 6)) * scale),
        MarqueeText(
          // 未读取的元数据标注「待读取」，避免与「读取后发现没有」的留白混淆。
          s.metaDisplay(s.artist) ?? '',
          style: artistStyle,
        ),
      ],
    );
  }
}

/// 元信息行（来源 · 格式 · 时长 + 权重徽标）：竖屏/横屏共用。
class _MetaLine extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;
  final double scale;
  const _MetaLine(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final s = song;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10 * scale,
      runSpacing: 6 * scale,
      children: [
        Text(
          [
            s.source,
            if (s.format != null && s.format!.isNotEmpty) s.format!,
            if (formatDuration(s.duration).isNotEmpty)
              formatDuration(s.duration),
          ].join(' · '),
          style: _scaleTextStyle(
              Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
              scale),
        ),
        if (direct.settings.playerShowWeight)
          InkWell(
            borderRadius: BorderRadius.circular(8 * scale),
            onTap: () => AppToast.show('当前曲目的播放权重', isError: false),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: 8 * scale, vertical: 2 * scale),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8 * scale),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speed,
                      size: 12 * scale,
                      color: cs.onSurface.withValues(alpha: 0.6)),
                  SizedBox(width: 4 * scale),
                  Text(
                    '权重 ${player.currentWeightFactor?.toStringAsFixed(1) ?? '—'}',
                    style: _scaleTextStyle(
                        Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: cs.onSurface.withValues(alpha: 0.6),
                            ),
                        scale),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 工具行（喜欢/不喜欢/编辑歌单/缓存）：竖屏/横屏共用。
class _ToolRow extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;

  /// 横屏用：按钮紧凑成组居中（列宽较大时 spaceEvenly 会把按钮摊到列两缘，
  /// 与封面/标题的居中感不齐）；竖屏保持铺满一行均分。
  final bool center;
  final double scale;
  const _ToolRow(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      this.center = false,
      this.scale = 1.0});

  Future<void> _cache(BuildContext context, Song s) async {
    final src = direct.sourceByKey(s.sourceKey);
    if (src == null || !s.isDirect) {
      AppToast.show('仅直连歌曲可缓存', isError: false);
      return;
    }
    try {
      await direct.cacheSong(src, s);
      if (context.mounted) {
        AppToast.show('已缓存，可离线播放', isError: false);
      }
    } catch (e) {
      AppToast.error(e, '缓存失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = song;
    final favorite = direct.weight.isFavorite(s);
    final disliked = direct.weight.isDisliked(s);
    final row = Row(
      mainAxisSize: center ? MainAxisSize.min : MainAxisSize.max,
      mainAxisAlignment:
          center ? MainAxisAlignment.center : MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(
          iconSize: 22 * scale,
          tooltip: favorite ? '取消喜欢' : '喜欢',
          color: favorite ? Colors.pink : cs.onSurface.withValues(alpha: 0.55),
          icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
          onPressed: () {
            direct.setFavorite(s, !favorite);
            if (favorite) {
              context
                  .read<PlayerProvider>()
                  .onAnchorSongRemoved(PlayerProvider.anchorForLiked(), s);
            }
            AppToast.show(!favorite ? '已加入喜欢' : '已取消喜欢', isError: false);
          },
        ),
        IconButton(
          iconSize: 22 * scale,
          tooltip: disliked ? '取消不喜欢' : '不喜欢（权重降到 0.1）',
          color:
              disliked ? Colors.orange : cs.onSurface.withValues(alpha: 0.55),
          icon: Icon(disliked ? Icons.thumb_down : Icons.thumb_down_outlined),
          onPressed: () {
            direct.setDisliked(s, !disliked);
            AppToast.show(!disliked ? '已标记不喜欢，权重降到 0.1' : '已取消不喜欢',
                isError: false);
          },
        ),
        IconButton(
          iconSize: 22 * scale,
          tooltip: '编辑歌单',
          color: cs.onSurface.withValues(alpha: 0.55),
          icon: const Icon(Icons.playlist_add_check),
          onPressed: () => showEditPlaylistsSheet(context, s),
        ),
        IconButton(
          iconSize: 22 * scale,
          tooltip: '缓存歌曲',
          color: cs.onSurface.withValues(alpha: 0.55),
          icon: const Icon(Icons.download),
          onPressed: () => _cache(context, s),
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 12 * scale),
      child: center ? Center(child: row) : row,
    );
  }
}

/// 主控制区（定时 - 上一首 - 播放 - 下一首 - 播放模式）：竖屏/横屏共用。
class _ControlRow extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double scale;
  const _ControlRow({required this.player, required this.cs, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SleepButton(player: player, cs: cs, scale: scale),
        SizedBox(width: 8 * scale),
        Pressable(
          onPressed: player.prev,
          tooltip: '上一首',
          child: Icon(Icons.skip_previous, size: 34 * scale),
        ),
        ListenableBuilder(
          listenable: player,
          builder: (c, _) {
            // 目标态（provider.playing）：点击后一帧内翻转，不等音频淡出完成。
            final playing = player.playing;
            return Pressable(
              onPressed: player.toggle,
              tooltip: playing ? '暂停' : '播放',
              pressedScale: 0.85,
              child: Icon(
                  playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 74 * scale,
                  color: cs.primary),
            );
          },
        ),
        Pressable(
          onPressed: player.next,
          tooltip: '下一首',
          child: Icon(Icons.skip_next, size: 34 * scale),
        ),
        SizedBox(width: 8 * scale),
        _ModeButton(player: player, cs: cs, scale: scale),
      ],
    );
  }
}

/// 手机横屏三列（参照更新版 ui-playpage-wide.html，UI10）：
/// 左列 34% 封面/信息/进度，中列歌词（上下渐隐），右列 22% 竖向控制
/// （定时 / 上一首·播放·下一首 / 模式）。只在窄屏横屏（手机）使用；
/// 桌面/超宽屏走 [_DesktopLandscapePlayer]，避免被大窗口拉散。
///
/// 公开（去掉下划线）供布局回归测试直接渲染：桌面测试宿主上
/// `Platform.isLinux` 为真，经 [PlayerScreen] 永远走桌面双栏分支，
/// 手机三列的溢出问题只能直接挂载本组件覆盖（test/player_landscape_test.dart）。
/// 播放列竖向下拖跟手（横屏手机三列 page1 用）：中列歌词窗不包，避免与歌词
/// 纵滚同一竞技场打架；回调全空时原样返回，零行为变化。
Widget _withPlayerDrag({
  required Widget child,
  required GestureDragStartCallback? onVerticalDragStart,
  required GestureDragUpdateCallback? onVerticalDragUpdate,
  required GestureDragEndCallback? onVerticalDragEnd,
}) {
  if (onVerticalDragStart == null &&
      onVerticalDragUpdate == null &&
      onVerticalDragEnd == null) {
    return child;
  }
  return GestureDetector(
    behavior: HitTestBehavior.translucent,
    onVerticalDragStart: onVerticalDragStart,
    onVerticalDragUpdate: onVerticalDragUpdate,
    onVerticalDragEnd: onVerticalDragEnd,
    child: child,
  );
}

class LandscapePlayer extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;

  /// 播放列（左播放列 + 右竖向控制列，不含中列歌词）的竖向下拖跟手：
  /// page1 传入竖屏同套 `_onPlayerDrag*` 以下滑返回内容页；分栏歌单页等
  /// 非播放页保持 null（仅播放页，避免手势混乱）。
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  const LandscapePlayer(
      {super.key,
      required this.player,
      required this.direct,
      required this.cs,
      this.onVerticalDragStart,
      this.onVerticalDragUpdate,
      this.onVerticalDragEnd});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (!player.hasCurrent) {
      return Center(
          child:
              _EmptyState(coverSize: (size.height * 0.3).clamp(96.0, 150.0)));
    }
    final s = player.current!;
    final leftW = (size.width * 0.42).clamp(220.0, 420.0);
    final rightW = (size.width * 0.16).clamp(70.0, 96.0);
    // 桌面宽屏限宽居中（参照稿 max-width: 820），避免三列被拉得过散。
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: Row(
          children: [
            // 第一列：封面、信息、进度条（与分栏右窗共用 _LandscapePlayerMain，
            // 不定自身宽度，由外层 SizedBox 给宽）。
            SizedBox(
              width: leftW,
              child: _LandscapePlayerMain(
                  player: player,
                  direct: direct,
                  cs: cs,
                  song: s,
                  onVerticalDragStart: onVerticalDragStart,
                  onVerticalDragUpdate: onVerticalDragUpdate,
                  onVerticalDragEnd: onVerticalDragEnd),
            ),
            // 第二列：歌词区，上下边缘渐隐（参照稿 mask-image）。
            Expanded(
              child: ShaderMask(
                shaderCallback: (r) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent
                  ],
                  stops: [0.0, 0.12, 0.88, 1.0],
                ).createShader(r),
                blendMode: BlendMode.dstIn,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: LyricsView(player: player),
                ),
              ),
            ),
            // 第三列：竖向主控制区（顶部定时 / 中部切歌播放 / 底部模式，
            // 与分栏右窗共用 _LandscapePlayerSide）。
            SizedBox(
              width: rightW,
              child: _LandscapePlayerSide(
                  player: player,
                  cs: cs,
                  onVerticalDragStart: onVerticalDragStart,
                  onVerticalDragUpdate: onVerticalDragUpdate,
                  onVerticalDragEnd: onVerticalDragEnd),
            ),
          ],
        ),
      ),
    );
  }
}

/// 手机横屏左播放列（封面/信息/工具/进度）：三列整页与「左歌单右播放」分栏
/// 右窗共用。不定自身宽度，由父级 SizedBox 给宽（整页按全屏宽算，分栏按栏宽
/// 算——直接复用整页会导致 MediaQuery 全屏宽撑爆半栏）。
/// 不滚动：封面吃掉固定行之外的剩余高度，矮屏由 Flexible 自动收缩。
class _LandscapePlayerMain extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  const _LandscapePlayerMain(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      this.onVerticalDragStart,
      this.onVerticalDragUpdate,
      this.onVerticalDragEnd});

  @override
  Widget build(BuildContext context) {
    final s = song;
    return _withPlayerDrag(
      onVerticalDragStart: onVerticalDragStart,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: Center(
                heightFactor: 1,
                child: LayoutBuilder(
                  builder: (context, c) => _Cover(
                    coverPath: s.coverPath,
                    song: s,
                    cs: cs,
                    size: math.max(0, math.min(c.maxWidth - 24, c.maxHeight)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            _TitleBlock(
                player: player, direct: direct, compact: true, dense: true),
            const SizedBox(height: 4),
            _ToolRow(
                player: player, direct: direct, cs: cs, song: s, center: true),
            _PlayerSeek(player: player, cs: cs, showTime: false),
          ],
        ),
      ),
    );
  }
}

/// 手机横屏右竖向控制列（顶部定时 / 中部切歌播放 / 底部模式）：三列整页与
/// 分栏右窗共用，不定自身宽度。
class _LandscapePlayerSide extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final GestureDragStartCallback? onVerticalDragStart;
  final GestureDragUpdateCallback? onVerticalDragUpdate;
  final GestureDragEndCallback? onVerticalDragEnd;
  const _LandscapePlayerSide(
      {required this.player,
      required this.cs,
      this.onVerticalDragStart,
      this.onVerticalDragUpdate,
      this.onVerticalDragEnd});

  @override
  Widget build(BuildContext context) {
    return _withPlayerDrag(
      onVerticalDragStart: onVerticalDragStart,
      onVerticalDragUpdate: onVerticalDragUpdate,
      onVerticalDragEnd: onVerticalDragEnd,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _SleepButton(player: player, cs: cs),
            _VerticalControls(player: player, cs: cs),
            _ModeButton(player: player, cs: cs),
          ],
        ),
      ),
    );
  }
}

/// 手机横屏「左歌单右播放」分栏（PageView 首页的横屏形态）：
/// 左栏为歌单（绑定歌单 [SongList] / 兜底嵌入式 [QueuePage]，搜索/排序/多选等
/// 完整功能），右窗复用当前三列播放布局的左右列（播放列 + 竖向控制列，
/// 不含中列歌词——歌词仍在滑动后的整页播放页中列，避免双 LyricsView 跟焦与
/// 半栏拥挤）。
///
/// 公开（去掉下划线）供布局回归测试直接渲染，理由同 [LandscapePlayer]。
class LandscapePlaylistSplit extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;

  /// 重进歌单页的追焦信号（透传给左栏歌单/队列列表）。
  final ValueListenable<int>? focusTick;
  const LandscapePlaylistSplit(
      {super.key,
      required this.player,
      required this.direct,
      required this.cs,
      this.focusTick});

  @override
  Widget build(BuildContext context) {
    if (!player.hasCurrent) {
      return Row(
        children: [
          Expanded(child: _BandSongPage(embedded: true, focusTick: focusTick)),
          SizedBox(
            width: 300,
            child: Center(
                child: _EmptyState(
                    coverSize: (MediaQuery.sizeOf(context).height * 0.3)
                        .clamp(96.0, 150.0))),
          ),
        ],
      );
    }
    final s = player.current!;
    // 右窗按栏内约束定宽（不用 MediaQuery 全屏宽，否则撑爆半栏）；
    // 55:45 左右开，右窗钳在手机横屏可用区间。
    return LayoutBuilder(
      builder: (context, c) {
        final rightW = (c.maxWidth * 0.45).clamp(280.0, 400.0);
        final sideW = (c.maxWidth * 0.09).clamp(56.0, 72.0);
        return Row(
          children: [
            Expanded(
                child: _BandSongPage(embedded: true, focusTick: focusTick)),
            SizedBox(
              width: rightW,
              child: Row(
                children: [
                  Expanded(
                    child: _LandscapePlayerMain(
                        player: player, direct: direct, cs: cs, song: s),
                  ),
                  SizedBox(
                    width: sideW,
                    child: _LandscapePlayerSide(player: player, cs: cs),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 桌面横屏双栏（Linux/Windows/macOS 或超宽屏）：
/// 左栏封面/信息/控制整体垂直居中的一列（横排控制键，不被窗口高度拉散），
/// 右栏整幅歌词限宽居中。手机版三列在大窗口下会显得内容碎、留白多，
/// 故按平台/宽度分流（UI10 平台差异化）。
class _DesktopLandscapePlayer extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  const _DesktopLandscapePlayer(
      {required this.player, required this.direct, required this.cs});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final m = PlayerMetrics.desktop(size);
    if (!player.hasCurrent) {
      return Center(
          child: _EmptyState(coverSize: m.emptyCoverSize, scale: m.uiScale));
    }
    final s = player.current!;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: m.contentMaxWidth),
        child: Row(
          children: [
            // 左栏：与分栏右窗共用 _DesktopPlayerColumn（不定自身宽度，由调用方给宽）。
            _DesktopPlayerColumn(
                player: player,
                direct: direct,
                cs: cs,
                song: s,
                width: m.leftColumnWidth,
                metrics: m),
            // 右栏：歌词限宽居中 + 上下边缘渐隐（改进.txt：去掉两栏中间分割线）。
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxWidth: m.lyricsMaxWidth + m.lyricsPadding * 2),
                  child: ShaderMask(
                    shaderCallback: (r) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black,
                        Colors.black,
                        Colors.transparent
                      ],
                      stops: [0.0, 0.12, 0.88, 1.0],
                    ).createShader(r),
                    blendMode: BlendMode.dstIn,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: m.lyricsPadding,
                          vertical: 12 * m.uiScale),
                      child: LyricsView(player: player, scale: m.uiScale),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 桌面横屏左播放列（封面/信息/工具/进度/横排控制）：双栏整页左栏与「左歌单
/// 右播放」分栏右窗共用。宽度由调用方按上下文给定（整页按全屏算，分栏按栏内
/// 约束算）；矮窗口可滚动，内容不足一屏高时垂直居中。
class _DesktopPlayerColumn extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  final Song song;
  final double width;
  final PlayerMetrics metrics;
  const _DesktopPlayerColumn(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      required this.width,
      required this.metrics});

  @override
  Widget build(BuildContext context) {
    final s = song;
    final scale = metrics.uiScale;
    final horizontal = metrics.columnPadding;
    final vertical = 16 * scale;
    return SizedBox(
      width: width,
      child: LayoutBuilder(
        builder: (context, c) {
          final innerWidth = math.max(0.0, width - horizontal * 2);
          final byHeight =
              c.maxHeight - vertical * 2 - metrics.fixedContentHeight;
          final cover = math.min(
            metrics.targetCover,
            math.min(
              innerWidth,
              math.max(160 * scale, byHeight),
            ),
          );
          return SingleChildScrollView(
            padding: EdgeInsets.symmetric(
                horizontal: horizontal, vertical: vertical),
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(minHeight: c.maxHeight - vertical * 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: _Cover(
                        coverPath: s.coverPath,
                        song: s,
                        cs: cs,
                        size: cover,
                        scale: scale),
                  ),
                  SizedBox(height: 16 * scale),
                  _TitleBlock(
                      player: player,
                      direct: direct,
                      compact: true,
                      scale: scale),
                  SizedBox(height: 6 * scale),
                  _MetaLine(
                      player: player,
                      direct: direct,
                      cs: cs,
                      song: s,
                      scale: scale),
                  _ToolRow(
                      player: player,
                      direct: direct,
                      cs: cs,
                      song: s,
                      center: true,
                      scale: scale),
                  _PlayerSeek(player: player, cs: cs, scale: scale),
                  // 左栏宽会被钳到最小 320×uiScale（内容区随比例缩放），
                  // 控制行约 302×uiScale；窄桌面窗口会横向溢出，scaleDown
                  // 只在放不下时整体等比收缩，宽窗口零影响。
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: _ControlRow(player: player, cs: cs, scale: scale),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 桌面横屏「左歌单右播放」分栏（PageView 首页的横屏形态）：
/// 左栏为歌单（完整功能），右窗复用当前双栏播放布局的左播放列（不含歌词栏——
/// 歌词仍在滑动后的整页播放页右栏）。公开供布局回归测试直接渲染。
class DesktopPlaylistSplit extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;

  /// 重进歌单页的追焦信号（透传给左栏歌单/队列列表）。
  final ValueListenable<int>? focusTick;
  const DesktopPlaylistSplit(
      {super.key,
      required this.player,
      required this.direct,
      required this.cs,
      this.focusTick});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final m = PlayerMetrics.desktop(size);
    if (!player.hasCurrent) {
      return Row(
        children: [
          Expanded(child: _BandSongPage(embedded: true, focusTick: focusTick)),
          SizedBox(
            width: m.rightPaneWidth(size.width),
            child: Center(
                child:
                    _EmptyState(coverSize: m.emptyCoverSize, scale: m.uiScale)),
          ),
        ],
      );
    }
    final s = player.current!;
    // 右窗按栏内约束定宽（不用全屏宽直算）；封面仍按全屏高算（栏与页同高）。
    return LayoutBuilder(
      builder: (context, c) {
        final rightW = m.rightPaneWidth(c.maxWidth);
        return Row(
          children: [
            Expanded(
                child: _BandSongPage(embedded: true, focusTick: focusTick)),
            _DesktopPlayerColumn(
                player: player,
                direct: direct,
                cs: cs,
                song: s,
                width: rightW,
                metrics: m),
          ],
        );
      },
    );
  }
}

/// 横屏右列中部的竖向播放控制：上一首 / 播放暂停 / 下一首。
class _VerticalControls extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  const _VerticalControls({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Pressable(
          onPressed: player.prev,
          tooltip: '上一首',
          child: const Icon(Icons.skip_previous, size: 28),
        ),
        const SizedBox(height: 6),
        ListenableBuilder(
          listenable: player,
          builder: (c, _) {
            // 目标态（provider.playing）：点击后一帧内翻转，不等音频淡出完成。
            final playing = player.playing;
            return Pressable(
              onPressed: player.toggle,
              tooltip: playing ? '暂停' : '播放',
              pressedScale: 0.85,
              child: Icon(
                  playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 56,
                  color: cs.primary),
            );
          },
        ),
        const SizedBox(height: 6),
        Pressable(
          onPressed: player.next,
          tooltip: '下一首',
          child: const Icon(Icons.skip_next, size: 28),
        ),
      ],
    );
  }
}

/// 专辑封面：指定尺寸的方形圆角封面 + 右上角更多操作。
class _Cover extends StatelessWidget {
  final String? coverPath;
  final Song song;
  final ColorScheme cs;
  final double size;
  final double scale;
  final bool showSongsEntry;
  final VoidCallback? onOpenSongs;

  const _Cover({
    required this.coverPath,
    required this.song,
    required this.cs,
    required this.size,
    this.scale = 1.0,
    this.showSongsEntry = false,
    this.onOpenSongs,
  });

  @override
  Widget build(BuildContext context) {
    // 更多入口随封面缩放：圆框直径与图标按封面边长比例取，限制在可点范围。
    final moreSize = (size * 0.13).clamp(28.0, 44.0);
    return SizedBox(
      key: const Key('player-cover'),
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(24 * scale),
            child: Container(
              color: cs.primary.withValues(alpha: 0.10),
              child: coverPath != null
                  ? Image.file(
                      File(coverPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.music_note,
                        size: size * 0.3,
                        color: cs.primary.withValues(alpha: 0.5),
                      ),
                    )
                  : song.metaUnread
                      ? _UnreadCoverPlaceholder(cs: cs, size: size)
                      : Icon(
                          Icons.music_note,
                          size: size * 0.3,
                          color: cs.primary.withValues(alpha: 0.5),
                        ),
            ),
          ),
          Positioned(
            top: size * 0.04,
            right: size * 0.04,
            // 静置隐藏时淡出并停止命中（改进.txt UI3）。
            child: IgnorePointer(
              ignoring: _PlayerControlsHidden.isHidden(context),
              child: AnimatedOpacity(
                opacity: _PlayerControlsHidden.isHidden(context) ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: Material(
                  color: Colors.white.withValues(alpha: 0.6),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: PopupMenuButton<String>(
                    tooltip: '更多',
                    padding: EdgeInsets.zero,
                    onSelected: (v) => _onSelected(context, v),
                    itemBuilder: (c) {
                      // 线路切换（与源卡片同功能）：仅当该源配了备用时出现。
                      List<PopupMenuEntry<String>> lineItems = const [];
                      try {
                        final direct = c.read<DirectSourceManager>();
                        final fbCount = direct.fallbackCountOf(song.sourceKey);
                        if (fbCount > 0) {
                          final pref = parseSourceLine(
                              direct.settings.getSourceLine(song.sourceKey));
                          String label(SourceLine l) {
                            final cur = pref == l ? ' ✓' : '';
                            return switch (l) {
                              SourceLine.auto => '线路：自动$cur',
                              SourceLine.primary => '线路：主用$cur',
                              SourceLine.fb0 => '线路：备用1$cur',
                              SourceLine.fb1 => '线路：备用2$cur',
                            };
                          }

                          lineItems = [
                            const PopupMenuDivider(),
                            PopupMenuItem(
                                value: 'line_auto',
                                child: Text(label(SourceLine.auto))),
                            PopupMenuItem(
                                value: 'line_primary',
                                child: Text(label(SourceLine.primary))),
                            PopupMenuItem(
                                value: 'line_fb0',
                                child: Text(label(SourceLine.fb0))),
                            if (fbCount > 1)
                              PopupMenuItem(
                                  value: 'line_fb1',
                                  child: Text(label(SourceLine.fb1))),
                          ];
                        }
                      } catch (_) {}
                      return [
                        if (showSongsEntry)
                          const PopupMenuItem(
                              value: 'songs', child: Text('歌单')),
                        const PopupMenuItem(value: 'info', child: Text('歌曲信息')),
                        const PopupMenuItem(value: 'edit', child: Text('修改信息')),
                        const PopupMenuItem(
                            value: 'online', child: Text('在线获取元数据')),
                        ...lineItems,
                      ];
                    },
                    child: SizedBox(
                      width: moreSize,
                      height: moreSize,
                      child: Icon(
                        Icons.more_horiz,
                        color: Colors.black87,
                        size: moreSize * 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onSelected(BuildContext context, String v) {
    if (v == 'songs') {
      onOpenSongs?.call();
    } else if (v == 'info') {
      showDialog<void>(
        context: context,
        builder: (_) => SongInfoDialog(song: song),
      );
    } else if (v == 'edit') {
      showDialog<void>(
        context: context,
        builder: (_) => EditSongMetaDialog(song: song),
      );
    } else if (v == 'online') {
      showDialog<void>(
        context: context,
        builder: (_) => OnlineMetaDialog(song: song),
      );
    } else if (v.startsWith('line_')) {
      final direct = context.read<DirectSourceManager>();
      final line = switch (v) {
        'line_primary' => SourceLine.primary,
        'line_fb0' => SourceLine.fb0,
        'line_fb1' => SourceLine.fb1,
        _ => SourceLine.auto,
      };
      direct.setLinePref(song.sourceKey, line).then((_) {
        if (context.mounted) {
          AppToast.show(
              line == SourceLine.auto
                  ? '已切到自动线路（主→备 Failover）'
                  : line == SourceLine.primary
                      ? '已锁定主用线路'
                      : line == SourceLine.fb0
                          ? '已锁定备用1线路'
                          : '已锁定备用2线路',
              isError: false);
          try {
            final player = context.read<PlayerProvider>();
            if (player.current?.sourceKey == song.sourceKey) {
              player.reloadCurrentForPlaybackRoute();
            }
          } catch (_) {}
        }
      });
    }
  }
}

/// 未读取元数据时的封面占位：提示「尚未读取，可能有封面」，区别于真无封面的图标占位。
class _UnreadCoverPlaceholder extends StatelessWidget {
  final ColorScheme cs;
  final double size;
  const _UnreadCoverPlaceholder({required this.cs, required this.size});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.image_not_supported_outlined,
            size: size * 0.22, color: cs.primary.withValues(alpha: 0.5)),
        SizedBox(height: size * 0.04),
        Text(
          Song.unreadLabel,
          style: TextStyle(
            fontSize: size * 0.08,
            color: cs.primary.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

/// 睡眠定时按钮：激活时高亮，点击弹出四种模式对话框。
class _SleepButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double scale;

  const _SleepButton(
      {required this.player, required this.cs, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final active = player.sleepTimerActive;
    final summary = player.sleepSummaryText;
    return IconButton(
      iconSize: 22 * scale,
      color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
      tooltip: '睡眠定时${active && summary != null ? '：$summary' : ''}',
      icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
      onPressed: () => showSleepTimerDialog(context),
    );
  }
}

/// 播放模式：单击循环切换，非「顺序播放」时高亮。
class _ModeButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  final double scale;

  const _ModeButton({required this.player, required this.cs, this.scale = 1.0});

  @override
  Widget build(BuildContext context) {
    final m = player.mode;
    final active = m != PlayMode.sequence;
    return IconButton(
      iconSize: 22 * scale,
      color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
      tooltip: '播放模式：${_label(m)}（点击切换）',
      icon: Icon(_icon(m)),
      onPressed: () {
        final next = PlayMode.values[(m.index + 1) % PlayMode.values.length];
        player.setMode(next);
        AppToast.show('播放模式：${_label(next)}', isError: false);
      },
    );
  }

  static IconData _icon(PlayMode m) => switch (m) {
        PlayMode.sequence => Icons.playlist_play_rounded,
        PlayMode.loopList => Icons.repeat_rounded,
        PlayMode.loopOne => Icons.repeat_one_rounded,
        PlayMode.weighted => Icons.shuffle_rounded,
      };

  static String _label(PlayMode m) => switch (m) {
        PlayMode.sequence => '顺序播放',
        PlayMode.loopList => '列表循环',
        PlayMode.loopOne => '单曲循环',
        PlayMode.weighted => '随机播放',
      };
}

/// 进度条（v5 设计稿：细进度 + 下方时间标签）。
class _PlayerSeek extends StatefulWidget {
  final PlayerProvider player;
  final ColorScheme cs;

  /// 横屏三列页隐藏进度条下方时间，把空间留给封面。
  final bool showTime;

  /// 进度条/时间字号缩放。
  final double scale;
  const _PlayerSeek(
      {required this.player,
      required this.cs,
      this.showTime = true,
      this.scale = 1.0});

  @override
  State<_PlayerSeek> createState() => _PlayerSeekState();
}

class _PlayerSeekState extends State<_PlayerSeek> {
  /// 拖动中的 thumb 位置（毫秒）：拖动过程只更新本地，松手才 seek 一次——
  /// 直播转码态每次 seek 都重开一条服务端流，逐 tick 发 seek 等于连续重启。
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.player.positionStream,
      builder: (c, _) {
        // 位置/时长走 provider：断点恢复装载期返回乐观断点值（首帧进度即对），
        // 真实 seek 完成后自动切真实值；StreamBuilder 照常逐 tick 刷新播放进度。
        final pos = widget.player.position;
        final dur = widget.player.duration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final cur = pos.inMilliseconds
            .toDouble()
            .clamp(0, max == 0 ? 1 : max)
            .toDouble();
        final shown =
            _dragValue?.clamp(0, max == 0 ? 1 : max).toDouble() ?? cur;
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4 * widget.scale,
                thumbShape:
                    RoundSliderThumbShape(enabledThumbRadius: 6 * widget.scale),
                overlayShape:
                    RoundSliderOverlayShape(overlayRadius: 14 * widget.scale),
                activeTrackColor: widget.cs.primary,
                inactiveTrackColor: widget.cs.onSurface.withValues(alpha: 0.12),
                thumbColor: widget.cs.primary,
              ),
              child: Slider(
                min: 0,
                max: max == 0 ? 1 : max,
                value: shown,
                onChanged: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) {
                  setState(() => _dragValue = null);
                  widget.player.seek(Duration(milliseconds: v.toInt()));
                },
              ),
            ),
            if (widget.showTime)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 8 * widget.scale),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatClock(Duration(milliseconds: shown.toInt())),
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14 * widget.scale)),
                    Text(formatClock(dur),
                        style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14 * widget.scale)),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
