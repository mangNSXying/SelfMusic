import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../services/bluetooth_service.dart';
import '../utils/duration_format.dart';
import '../utils/song_title_format.dart';
import '../utils/url_display.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/app_toast.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/marquee_text.dart';
import '../widgets/pressable.dart';
import '../widgets/player_sheet_anim.dart';

/// 横屏播放页布局分流（UI10 平台差异化）：
/// 桌面平台（鼠标+大窗口）或超宽屏（≥1000，大平板）→ 双栏居中布局；
/// 手机等窄屏横屏 → 三列紧凑布局（ui-playpage-wide.html）。
@visibleForTesting
bool useDesktopLandscape(Size size, {required bool isDesktopPlatform}) =>
    isDesktopPlatform || size.width >= 1000;

/// 全屏播放页（ui-playpage.html v5）：作为「首页」整屏展示，替换整个壳层。
///
/// 手势交互（可在设置中关闭）：
/// - 播放页/歌词页横向跟手互切（PageView 原生：跟手 + 速度/位置裁决）；
/// - 播放页【下滑跟手】整页随手指下移返回列表（松手吸附/离场）；
/// - 歌词页纵向滚动，右滑或按钮返回播放页；
/// - 底部迷你栏【上滑跟手】播放页从底部升起。
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final PageController _pageCtrl;

  /// 播放页下拉跟手的起点（全局 Y + 起始进度）。
  double _dragStartY = 0;
  double _dragStartP = 0;

  /// 屏幕常亮目标值与已应用值；合并调度标记。
  bool _wantWake = false;
  bool _wakeApplied = false;
  bool _platformSyncScheduled = false;

  /// 常亮蓝牙门控：限定设备时轮询其连接状态，仅连接期间保持常亮。
  final BluetoothService _bt = BluetoothService();
  BtDevice? _wakeDevice;
  bool _btConnected = true;
  Timer? _btPoll;

  @override
  void initState() {
    super.initState();
    _pageCtrl = PageController(initialPage: 0);
    // 首帧后读取常亮设置目标值。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = context.read<DirectSourceManager>().settings;
      _scheduleWakeSync(s.playerKeepScreenOn, s.keepScreenOnDevice);
    });
  }

  @override
  void dispose() {
    _btPoll?.cancel();
    // 离开播放页恢复熄屏策略。
    // ohos 无 wakelock_plus 平台实现，调用会 MissingPluginException（PoC 放弃常亮）。
    if (Platform.operatingSystem != 'ohos') {
      unawaited(WakelockPlus.disable());
    }
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 设置变化时合并到下一帧；应用屏幕常亮。
  /// 常亮可限定蓝牙设备：[deviceSetting] 变化时重置连接门控并轮询。
  void _scheduleWakeSync(bool keepOn, String deviceSetting) {
    final device = btDeviceFromSetting(deviceSetting);
    final deviceChanged = device?.address != _wakeDevice?.address;
    final changed = keepOn != _wantWake || deviceChanged;
    _wantWake = keepOn;
    _wakeDevice = device;
    if (deviceChanged) {
      _btConnected = device == null;
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
    final wake =
        _wantWake && (_wakeDevice == null || _btConnected);
    if (wake != _wakeApplied) {
      // ohos 无 wakelock_plus 实现，跳过（见 dispose 处注释）。
      if (Platform.operatingSystem != 'ohos') {
        unawaited(wake ? WakelockPlus.enable() : WakelockPlus.disable());
      }
      _wakeApplied = wake;
    }
  }

  /// 限定设备时常亮轮询：每 5 秒核对一次连接状态（进入/离开设备即时切换）。
  void _restartBtPoll() {
    _btPoll?.cancel();
    _btPoll = null;
    if (!_wantWake || _wakeDevice == null) return;
    unawaited(_refreshBtConnection());
    _btPoll = Timer.periodic(
        const Duration(seconds: 5), (_) => unawaited(_refreshBtConnection()));
  }

  Future<void> _refreshBtConnection() async {
    final dev = _wakeDevice;
    if (dev == null) return;
    final connected = await _bt.connectedAddresses();
    final ok = connected.contains(dev.address);
    if (ok != _btConnected && mounted) {
      _btConnected = ok;
      _flushWakeLock();
    }
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
        isDesktopPlatform:
            Platform.isLinux || Platform.isWindows || Platform.isMacOS);

    return Scaffold(
      body: SafeArea(
        child: landscape
            // 横屏无歌词分页：左上角箭头悬浮于两套横屏布局之上。
            ? Stack(
                children: [
                  desktopLandscape
                      ? _DesktopLandscapePlayer(
                          player: player,
                          direct: context.watch<DirectSourceManager>(),
                          cs: Theme.of(context).colorScheme)
                      : _LandscapePlayer(
                          player: player,
                          direct: context.watch<DirectSourceManager>(),
                          cs: Theme.of(context).colorScheme),
                  const Positioned(
                      top: 6, left: 6, child: _BackToContentButton()),
                ],
              )
            : PageView(
                // 横向由内层 PageView 原生跟手（右滑回播放页）；
                // 竖向仅播放页（第 0 页）跟手下拉，歌词页纵向留给滚动。
                // 关闭手势后 PageView 禁滑、下拉停用。
                controller: _pageCtrl,
          physics: gestureOn
              ? const PageScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          children: [
            // 箭头悬浮在播放页内容之上（不占布局空间，不压缩封面）；
            // 歌词页（第 1 页）按先前要求不再放箭头。
            Stack(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onVerticalDragStart:
                      gestureOn ? _onPlayerDragStart : null,
                  onVerticalDragUpdate:
                      gestureOn ? _onPlayerDragUpdate : null,
                  onVerticalDragEnd: gestureOn ? _onPlayerDragEnd : null,
                  child: _buildPlayerBody(context),
                ),
                const Positioned(
                    top: 6, left: 6, child: _BackToContentButton()),
              ],
            ),
            const _LyricsPage(),
          ],
        ),
      ),
    );
  }

  /// 自适应播放页：整页不滚动，封面尺寸按可用空间计算以恰好放满一屏。
  Widget _buildPlayerBody(BuildContext context) {
    final player = context.watch<PlayerProvider>();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final coverSize = _fitCover(
              constraints.maxWidth - 48,
              constraints.maxHeight - 48,
            );
            return Padding(
              padding: const EdgeInsets.all(24),
              child: player.hasCurrent
                  ? _NowPlaying(
                      player: player,
                      direct: context.watch<DirectSourceManager>(),
                      cs: Theme.of(context).colorScheme,
                      coverSize: coverSize,
                    )
                  : _EmptyState(coverSize: coverSize),
            );
          },
        ),
      ),
    );
  }

  /// 计算封面边长：横向受宽度限制，纵向受「高度 - 其余控件固定高度」限制。
  double _fitCover(double availW, double availH) {
    // 封面以外部分的近似固定高度（标题/歌手/元信息 + 工具行 + 进度 + 控制行 + 间距）。
    const fixed = 342.0;
    final byH = (availH - fixed).clamp(0.0, 360.0);
    return math.min(availW, byH);
  }
}

/// 播放页左上角「回到内容页」向下箭头：悬浮覆盖（Positioned 入 Stack），
/// 不参与布局，因此不压缩封面及其他内容的显示空间；点击与下滑返回同路径
/// （置意图位 → Root 驱动悬浮层下降动画）。恒素显，无圆形底/阴影。
class _BackToContentButton extends StatelessWidget {
  const _BackToContentButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: '回到内容页',
      iconSize: 26,
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.keyboard_arrow_down_rounded),
      onPressed: () => context.read<NavigationProvider>().closePlayer(),
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

    return Column(
      children: [
        if (s != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 0),
            child: _TitleBlock(
                player: player, direct: direct, compact: true),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: s == null
              ? Center(
                  child: Text('暂无歌曲',
                      style: TextStyle(
                          color: cs.onSurface.withValues(alpha: 0.5))),
                )
              : LyricsView(player: player),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// 未在播放时的首页空态。
class _EmptyState extends StatelessWidget {
  final double coverSize;

  const _EmptyState({required this.coverSize});

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
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(Icons.music_note, size: coverSize * 0.5, color: cs.primary.withValues(alpha: 0.55)),
        ),
        const SizedBox(height: 32),
        Text('未在播放', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          '从左侧导航选择歌曲开始播放',
          style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
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

  const _NowPlaying({
    required this.player,
    required this.direct,
    required this.cs,
    required this.coverSize,
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
              coverPath: s.coverPath, song: s, cs: cs, size: coverSize),
        ),
        const SizedBox(height: 20),
        _TitleBlock(player: player, direct: direct),
        const SizedBox(height: 8),
        _MetaLine(player: player, direct: direct, cs: cs, song: s),
        _ToolRow(player: player, direct: direct, cs: cs, song: s),
        _PlayerSeek(player: player, cs: cs),
        const SizedBox(height: 6),
        _ControlRow(player: player, cs: cs),
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
  const _TitleBlock(
      {required this.player,
      required this.direct,
      this.compact = false,
      this.dense = false});

  @override
  Widget build(BuildContext context) {
    final s = player.current!;
    final tt = Theme.of(context).textTheme;
    final titleStyle = dense
        ? tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)
        : (compact ? tt.titleLarge : tt.headlineSmall)
            ?.copyWith(fontWeight: FontWeight.w700);
    final artistStyle =
        dense ? tt.bodySmall : (compact ? tt.titleSmall : tt.titleMedium);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MarqueeText(
          formatSongTitle(s, direct.settings.songTitleFormat),
          style: titleStyle,
        ),
        SizedBox(height: dense ? 2 : (compact ? 4 : 6)),
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
  const _MetaLine(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song});

  @override
  Widget build(BuildContext context) {
    final s = song;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 10,
      runSpacing: 6,
      children: [
        Text(
          [
            s.source,
            if (s.format != null && s.format!.isNotEmpty) s.format!,
            if (formatDuration(s.duration).isNotEmpty)
              formatDuration(s.duration),
          ].join(' · '),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
        ),
        if (direct.settings.playerShowWeight)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => AppToast.show('当前曲目的播放权重', isError: false),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.speed,
                      size: 12, color: cs.onSurface.withValues(alpha: 0.6)),
                  const SizedBox(width: 4),
                  Text(
                    '权重 ${player.currentWeightFactor?.toStringAsFixed(1) ?? '—'}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
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
  const _ToolRow(
      {required this.player,
      required this.direct,
      required this.cs,
      required this.song,
      this.center = false});

  Future<void> _cache(BuildContext context, Song s) async {
    final src = direct.sourceByKey(s.sourceKey);
    if (src == null || !s.isDirect) {
      AppToast.show('仅直连歌曲可缓存', isError: false);
      return;
    }
    await direct.cacheSong(src, s);
    if (context.mounted) {
      AppToast.show('已开始缓存', isError: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = song;
    final favorite = direct.weight.isFavorite(s);
    final disliked = direct.weight.isDisliked(s);
    final row = Row(
        mainAxisSize: center ? MainAxisSize.min : MainAxisSize.max,
        mainAxisAlignment: center
            ? MainAxisAlignment.center
            : MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            iconSize: 22,
            tooltip: favorite ? '取消喜欢' : '喜欢',
            color: favorite ? Colors.pink : cs.onSurface.withValues(alpha: 0.55),
            icon: Icon(favorite ? Icons.favorite : Icons.favorite_border),
            onPressed: () {
              direct.setFavorite(s, !favorite);
              if (favorite) {
                context.read<PlayerProvider>().onAnchorSongRemoved(
                    PlayerProvider.anchorForLiked(), s);
              }
              AppToast.show(!favorite ? '已加入喜欢' : '已取消喜欢',
                  isError: false);
            },
          ),
          IconButton(
            iconSize: 22,
            tooltip: disliked ? '取消不喜欢' : '不喜欢（权重降到最低）',
            color: disliked
                ? Colors.orange
                : cs.onSurface.withValues(alpha: 0.55),
            icon: Icon(
                disliked ? Icons.thumb_down : Icons.thumb_down_outlined),
            onPressed: () {
              direct.setDisliked(s, !disliked);
              AppToast.show(
                  !disliked ? '已标记不喜欢，权重降到最低' : '已取消不喜欢',
                  isError: false);
            },
          ),
          IconButton(
            iconSize: 22,
            tooltip: '编辑歌单',
            color: cs.onSurface.withValues(alpha: 0.55),
            icon: const Icon(Icons.playlist_add_check),
            onPressed: () => showEditPlaylistsSheet(context, s),
          ),
          IconButton(
            iconSize: 22,
            tooltip: '缓存歌曲',
            color: cs.onSurface.withValues(alpha: 0.55),
            icon: const Icon(Icons.download),
            onPressed: () => _cache(context, s),
          ),
        ],
      );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: center ? Center(child: row) : row,
    );
  }
}

/// 主控制区（定时 - 上一首 - 播放 - 下一首 - 播放模式）：竖屏/横屏共用。
class _ControlRow extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;
  const _ControlRow({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _SleepButton(player: player, cs: cs),
        const SizedBox(width: 8),
        Pressable(
          onPressed: player.prev,
          tooltip: '上一首',
          child: const Icon(Icons.skip_previous, size: 34),
        ),
        StreamBuilder<PlayerState>(
          stream: player.player.playerStateStream,
          builder: (c, snap) {
            final playing = snap.data?.playing ?? false;
            return Pressable(
              onPressed: player.toggle,
              tooltip: playing ? '暂停' : '播放',
              pressedScale: 0.85,
              child: Icon(
                  playing
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_filled,
                  size: 74,
                  color: cs.primary),
            );
          },
        ),
        Pressable(
          onPressed: player.next,
          tooltip: '下一首',
          child: const Icon(Icons.skip_next, size: 34),
        ),
        const SizedBox(width: 8),
        _ModeButton(player: player, cs: cs),
      ],
    );
  }
}

/// 手机横屏三列（参照更新版 ui-playpage-wide.html，UI10）：
/// 左列 34% 封面/信息/进度，中列歌词（上下渐隐），右列 22% 竖向控制
/// （定时 / 上一首·播放·下一首 / 模式）。只在窄屏横屏（手机）使用；
/// 桌面/超宽屏走 [_DesktopLandscapePlayer]，避免被大窗口拉散。
class _LandscapePlayer extends StatelessWidget {
  final PlayerProvider player;
  final DirectSourceManager direct;
  final ColorScheme cs;
  const _LandscapePlayer(
      {required this.player, required this.direct, required this.cs});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (!player.hasCurrent) {
      return Center(
          child: _EmptyState(coverSize: (size.height * 0.3).clamp(96.0, 150.0)));
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
            // 第一列：封面、信息、进度条。不滚动：封面吃掉省下的空间放大显示。
            SizedBox(
              width: leftW,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: LayoutBuilder(
                  builder: (context, c) {
                    // 封面以外的固定高度（标题/工具行/进度条 + 间距）。
                    final cover = math
                        .min(c.maxWidth - 24, math.max(64.0, c.maxHeight - 150));
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: _Cover(
                              coverPath: s.coverPath,
                              song: s,
                              cs: cs,
                              size: cover),
                        ),
                        const SizedBox(height: 8),
                        _TitleBlock(
                            player: player,
                            direct: direct,
                            compact: true,
                            dense: true),
                        const SizedBox(height: 4),
                        _ToolRow(
                            player: player,
                            direct: direct,
                            cs: cs,
                            song: s,
                            center: true),
                        _PlayerSeek(player: player, cs: cs, showTime: false),
                      ],
                    );
                  },
                ),
              ),
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
            // 第三列：竖向主控制区（顶部定时 / 中部切歌播放 / 底部模式）。
            SizedBox(
              width: rightW,
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
            ),
          ],
        ),
      ),
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
    if (!player.hasCurrent) {
      return Center(
          child:
              _EmptyState(coverSize: (size.height * 0.32).clamp(120.0, 200.0)));
    }
    final s = player.current!;
    final leftW = (size.width * 0.30).clamp(320.0, 440.0);
    final cover = (size.height * 0.40).clamp(160.0, 280.0);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1240),
        child: Row(
          children: [
            // 左栏：矮窗口可滚动；内容不足一屏高时垂直居中，不留大片死白。
            SizedBox(
              width: leftW,
              child: LayoutBuilder(
                builder: (context, c) => SingleChildScrollView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: c.maxHeight - 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Center(
                          child: _Cover(
                              coverPath: s.coverPath,
                              song: s,
                              cs: cs,
                              size: cover),
                        ),
                        const SizedBox(height: 16),
                        _TitleBlock(
                            player: player, direct: direct, compact: true),
                        const SizedBox(height: 6),
                        _MetaLine(
                            player: player, direct: direct, cs: cs, song: s),
                        _ToolRow(
                            player: player,
                            direct: direct,
                            cs: cs,
                            song: s,
                            center: true),
                        _PlayerSeek(player: player, cs: cs),
                        _ControlRow(player: player, cs: cs),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 右栏：歌词限宽居中 + 上下边缘渐隐（改进.txt：去掉两栏中间分割线）。
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      child: LyricsView(player: player),
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
        StreamBuilder<PlayerState>(
          stream: player.player.playerStateStream,
          builder: (c, snap) {
            final playing = snap.data?.playing ?? false;
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

  const _Cover({
    required this.coverPath,
    required this.song,
    required this.cs,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    // 更多入口随封面缩放：圆框直径与图标按封面边长比例取，限制在可点范围。
    final moreSize = (size * 0.13).clamp(28.0, 44.0);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
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
            child: Material(
              color: Colors.white.withValues(alpha: 0.6),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: PopupMenuButton<String>(
                tooltip: '更多',
                padding: EdgeInsets.zero,
                onSelected: (v) => _onSelected(context, v),
                itemBuilder: (c) => const [
                  PopupMenuItem(value: 'info', child: Text('歌曲信息')),
                  PopupMenuItem(value: 'edit', child: Text('修改歌曲元数据')),
                ],
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
        ],
      ),
    );
  }

  void _onSelected(BuildContext context, String v) {
    if (v == 'info') {
      showDialog<void>(
        context: context,
        builder: (_) => _SongInfoDialog(song: song),
      );
    } else if (v == 'edit') {
      showDialog<void>(
        context: context,
        builder: (_) => _EditSongMetaDialog(song: song),
      );
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

/// 歌曲信息弹窗：标题/歌手/专辑/流派/年份/时长/格式/来源/权重/收藏态。
class _SongInfoDialog extends StatelessWidget {
  final Song song;
  const _SongInfoDialog({required this.song});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final states = <String>[];
    if (song.isDirect) {
      if (direct.weight.isFavorite(song)) states.add('喜欢');
      if (direct.weight.isDisliked(song)) states.add('不喜欢');
    }
    // 元数据字段：未读取 → 标注「待读取」；已读取且无值 → 留白（—）。
    String? optField(String? v) => song.metaDisplay(v);
    // 路径：优先由对应直连源解析真实可读路径（本地绝对路径/WebDAV URL/UNC），
    // 源不在本机时回落到持久化完整 URL 或源内引用；URL 百分号编码展示时解码。
    final displayPath = direct.sourceByKey(song.sourceKey)?.displayPath(song) ??
        decodeUrlForDisplay(song.sourceUrl ?? song.sourceRef);
    final rows = <List<String>>[
      ['标题', song.title],
      ['歌手', optField(song.artist) ?? '—'],
      ['专辑歌手', optField(song.albumArtist) ?? '—'],
      ['专辑', optField(song.albumName) ?? '—'],
      if (song.metaUnread || (song.genre != null && song.genre!.isNotEmpty))
        ['流派', song.metaUnread ? Song.unreadLabel : song.genre!],
      if (song.metaUnread || song.year != null)
        ['年份', song.metaUnread ? Song.unreadLabel : '${song.year}'],
      if (song.metaUnread ||
          (song.duration != null && song.duration! > 0))
        ['时长',
            song.metaUnread ? Song.unreadLabel : formatDuration(song.duration)],
      if (song.format != null) ['格式', song.format!.toUpperCase()],
      ['来源', '${song.source}（${song.sourceKey}）'],
      ['路径', displayPath],
      if (song.isDirect)
        ['权重', direct.weight.factorOf(song).toStringAsFixed(1)],
      if (song.isDirect) ['状态', states.isEmpty ? '—' : states.join(' · ')],
    ];
    return AlertDialog(
      title: const Text('歌曲信息'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(r[0],
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.6))),
                      ),
                      Expanded(child: Text(r[1])),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 修改歌曲元数据弹窗（全源）：标题/歌手/专辑可编辑。
///
/// 直连歌落库并标记扫描保护；服务端歌（后端只读）写入本地覆盖层，刷新即生效。
class _EditSongMetaDialog extends StatefulWidget {
  final Song song;
  const _EditSongMetaDialog({required this.song});

  @override
  State<_EditSongMetaDialog> createState() => _EditSongMetaDialogState();
}

class _EditSongMetaDialogState extends State<_EditSongMetaDialog> {
  late final TextEditingController _title;
  late final TextEditingController _artist;
  late final TextEditingController _albumArtist;
  late final TextEditingController _album;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.song.title);
    _artist = TextEditingController(text: widget.song.artist ?? '');
    _albumArtist = TextEditingController(text: widget.song.albumArtist ?? '');
    _album = TextEditingController(text: widget.song.albumName ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _artist.dispose();
    _albumArtist.dispose();
    _album.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      AppToast.error(StateError('标题不能为空'));
      return;
    }
    // 字段语义：null=未改动不写；''=清空为未知；其余=新值。
    String? delta(String input, String? current) {
      final v = input.trim();
      if (v == (current ?? '')) return null;
      return v.isEmpty ? '' : v;
    }

    final direct = context.read<DirectSourceManager>();
    final updated = await direct.updateSongMeta(
      widget.song,
      title: delta(title, widget.song.title),
      artist: delta(_artist.text, widget.song.artist),
      albumArtist: delta(_albumArtist.text, widget.song.albumArtist),
      album: delta(_album.text, widget.song.albumName),
    );
    if (!mounted) return;
    if (updated != null) {
      context.read<PlayerProvider>().refreshSongMeta(updated);
    }
    Navigator.of(context).pop();
    AppToast.show(
        widget.song.isDirect ? '已保存歌曲信息（扫描不再覆盖）' : '已保存歌曲信息（本地覆盖）',
        isError: false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改歌曲元数据'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            TextField(
              controller: _artist,
              decoration:
                  const InputDecoration(labelText: '歌手（留空为未知）'),
            ),
            TextField(
              controller: _albumArtist,
              decoration:
                  const InputDecoration(labelText: '专辑歌手（留空为未知）'),
            ),
            TextField(
              controller: _album,
              decoration:
                  const InputDecoration(labelText: '专辑（留空为未知）'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}

/// 睡眠定时按钮：激活时高亮，点击弹出四种模式对话框。
class _SleepButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;

  const _SleepButton({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    final active = player.sleepTimerActive;
    final summary = player.sleepSummaryText;
    return IconButton(
      iconSize: 22,
      color: active ? cs.primary : cs.onSurface.withValues(alpha: 0.7),
      tooltip: '睡眠定时${active && summary != null ? '：$summary' : ''}',
      icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (_) => _SleepTimerDialog(
          playThroughDefault:
              context.read<DirectSourceManager>().settings.sleepPlayThroughDefault,
        ),
      ),
    );
  }
}

/// 睡眠定时弹窗：指定时间 / 指定时长 / 指定曲数 / 列表结尾 + 「播放完最后的曲目」。
class _SleepTimerDialog extends StatefulWidget {
  final bool playThroughDefault;

  const _SleepTimerDialog({required this.playThroughDefault});

  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  late SleepTimerKind? _mode;
  TimeOfDay? _time;
  late int _minutes;
  late int _count;
  late bool _playThrough;

  @override
  void initState() {
    super.initState();
    final p = context.read<PlayerProvider>();
    _mode = p.sleepMode;
    if (_mode == SleepTimerKind.time && p.sleepUntilTime != null) {
      final t = p.sleepUntilTime!;
      _time = TimeOfDay(hour: t.hour, minute: t.minute);
    }
    _minutes = p.sleepMinutes > 0 ? p.sleepMinutes : 30;
    _count = p.sleepCountLeft > 0 ? p.sleepCountLeft : 3;
    _playThrough = p.sleepTimerActive
        ? p.sleepPlayThrough
        : widget.playThroughDefault;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('睡眠定时', style: TextStyle(fontSize: 21)),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RadioGroup<SleepTimerKind>(
                groupValue: _mode,
                onChanged: (v) {
                  if (v != null) setState(() => _mode = v);
                },
                child: Column(
                  children: [
                    RadioListTile<SleepTimerKind>(
                      value: SleepTimerKind.time,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('指定时间',
                          style: TextStyle(fontSize: 17)),
                      subtitle: _timeSubtitle(),
                      secondary: _mode == SleepTimerKind.time
                          ? IconButton(
                              icon: const Icon(Icons.schedule, size: 30),
                              tooltip: '选择时间',
                              onPressed: _pickTime,
                            )
                          : null,
                    ),
                    RadioListTile<SleepTimerKind>(
                      value: SleepTimerKind.duration,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('指定时长',
                          style: TextStyle(fontSize: 17)),
                      subtitle: Text('倒计时 ${_fmtMinutes(_minutes)}后自动停止',
                          style: const TextStyle(fontSize: 15)),
                    ),
                    RadioListTile<SleepTimerKind>(
                      value: SleepTimerKind.count,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: const Text('指定曲数',
                          style: TextStyle(fontSize: 17)),
                      subtitle: Text('再播放 $_count 首后停止',
                          style: const TextStyle(fontSize: 15)),
                    ),
                    const RadioListTile<SleepTimerKind>(
                      value: SleepTimerKind.endOfList,
                      controlAffinity: ListTileControlAffinity.leading,
                      dense: true,
                      title: Text('列表结尾', style: TextStyle(fontSize: 17)),
                      subtitle:
                          Text('播完队列最后一首即停止', style: TextStyle(fontSize: 15)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (_mode == SleepTimerKind.duration)
                _WheelOpener(
                  label: _fmtMinutes(_minutes),
                  onTap: () => _pickDurationWheel(),
                ),
              if (_mode == SleepTimerKind.count)
                _WheelOpener(
                  label: '$_count 首',
                  onTap: () => _pickCountWheel(),
                ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('播放完最后的曲目',
                    style: TextStyle(fontSize: 17)),
                subtitle: const Text('到点不中断当前歌曲，放完这曲再暂停',
                    style: TextStyle(fontSize: 15)),
                value: _playThrough || _mode == SleepTimerKind.endOfList,
                onChanged: _mode == SleepTimerKind.endOfList
                    ? null
                    : (v) => setState(() => _playThrough = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _close(),
          child: const Text('关闭', style: TextStyle(fontSize: 16)),
        ),
        FilledButton(
          onPressed: _invalid ? null : _apply,
          child: const Text('确定', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }

  /// 指定时间副标题（时刻 + 选择按钮）。
  Widget _timeSubtitle() {
    if (_time == null) {
      return const Text('选择停止时刻', style: TextStyle(fontSize: 15));
    }
    return Row(children: [
      Text(_fmtTime(_time!), style: const TextStyle(fontSize: 15)),
      const SizedBox(width: 4),
      TextButton(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 6),
        ),
        onPressed: _pickTime,
        child: const Text('选择', style: TextStyle(fontSize: 15)),
      ),
    ]);
  }

  /// 当前选择不完整（未选模式 / 指定时间未选时刻）时不可确定。
  bool get _invalid =>
      _mode == null ||
      (_mode == SleepTimerKind.time && _time == null) ||
      (_mode == SleepTimerKind.duration && _minutes <= 0) ||
      (_mode == SleepTimerKind.count && _count <= 0);
  Future<void> _pickTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: _time ?? const TimeOfDay(hour: 22, minute: 0),
    );
    if (t == null || !mounted) return;
    setState(() {
      _time = t;
      _mode = SleepTimerKind.time;
    });
  }

  /// 时长滚轮：时（0~12）+ 分（0~59）双轮，结果至少 1 分钟。
  Future<void> _pickDurationWheel() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => _WheelDialog(
        title: '选择时长',
        columns: [
          [for (var h = 0; h <= 12; h++) '$h 小时'],
          [for (var m = 0; m <= 59; m++) '$m 分'],
        ],
        initial: [_minutes ~/ 60, _minutes % 60],
        resultOf: (idx) => idx[0] * 60 + idx[1],
        valid: (v) => v > 0,
      ),
    );
    if (picked != null && picked > 0 && mounted) {
      setState(() => _minutes = picked);
    }
  }

  /// 曲数滚轮：1~200 首单轮。
  Future<void> _pickCountWheel() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => _WheelDialog(
        title: '选择曲数',
        columns: [
          [for (var n = 1; n <= 200; n++) '$n 首'],
        ],
        initial: [(_count - 1).clamp(0, 199)],
        resultOf: (idx) => idx[0] + 1,
        valid: (v) => v > 0,
      ),
    );
    if (picked != null && picked > 0 && mounted) {
      setState(() => _count = picked);
    }
  }

  static String _fmtMinutes(int total) {
    if (total < 60) return '$total 分钟';
    final h = total ~/ 60;
    final m = total % 60;
    return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
  }

  void _apply() {
    final p = context.read<PlayerProvider>();
    final now = DateTime.now();
    switch (_mode) {
      case SleepTimerKind.time:
        final t = _time;
        if (t == null) return;
        p.setSleepTime(
          DateTime(now.year, now.month, now.day, t.hour, t.minute),
          playThrough: _playThrough,
        );
      case SleepTimerKind.duration:
        p.setSleepDuration(Duration(minutes: _minutes), playThrough: _playThrough);
      case SleepTimerKind.count:
        p.setSleepCount(_count, playThrough: _playThrough);
      case SleepTimerKind.endOfList:
        p.setSleepEndOfList();
      case null:
        return;
    }
    final summary = '睡眠定时：${p.sleepSummaryText ?? '已设置'}';
    Navigator.of(context).pop();
    AppToast.show(summary, isError: false);
  }

  void _close() {
    context.read<PlayerProvider>().cancelSleepTimer();
    Navigator.of(context).pop();
  }

  static String _fmtTime(TimeOfDay t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// 当前值展示 + 打开滚轮选择器的行（时长 / 曲数模式下）。
class _WheelOpener extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _WheelOpener({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          const Spacer(),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.unfold_more, size: 20),
            label: const Text('滚轮选择', style: TextStyle(fontSize: 15)),
            onPressed: onTap,
          ),
        ],
      ),
    );
  }
}

/// 通用滚轮选择弹窗（CupertinoPicker，无键盘输入）。
///
/// [columns] 为每轮的文本列，[initial] 为每轮初始选中下标；
/// [resultOf] 把各轮下标换算为结果值，[valid] 决定「确定」是否可用。
class _WheelDialog extends StatefulWidget {
  final String title;
  final List<List<String>> columns;
  final List<int> initial;
  final int Function(List<int>) resultOf;
  final bool Function(int) valid;
  const _WheelDialog({
    required this.title,
    required this.columns,
    required this.initial,
    required this.resultOf,
    required this.valid,
  });

  @override
  State<_WheelDialog> createState() => _WheelDialogState();
}

class _WheelDialogState extends State<_WheelDialog> {
  late List<int> _idx;
  late List<FixedExtentScrollController> _ctrls;

  @override
  void initState() {
    super.initState();
    _idx = List.of(widget.initial);
    _ctrls = [
      for (var c = 0; c < widget.columns.length; c++)
        FixedExtentScrollController(initialItem: widget.initial[c]),
    ];
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.resultOf(_idx);
    final ok = widget.valid(value);
    return AlertDialog(
      title: Text(widget.title, style: const TextStyle(fontSize: 20)),
      content: SizedBox(
        width: 320,
        height: 200,
        child: Row(
          children: [
            for (var c = 0; c < widget.columns.length; c++)
              Expanded(
                child: CupertinoPicker(
                  scrollController: _ctrls[c],
                  itemExtent: 40,
                  magnification: 1.15,
                  onSelectedItemChanged: (i) => setState(() => _idx[c] = i),
                  children: [
                    for (final label in widget.columns[c])
                      Center(
                        child: Text(label,
                            style: const TextStyle(fontSize: 17)),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消', style: TextStyle(fontSize: 16)),
        ),
        FilledButton(
          onPressed: ok ? () => Navigator.of(context).pop(value) : null,
          child: const Text('确定', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }
}

/// 播放模式：单击循环切换，非「顺序播放」时高亮。
class _ModeButton extends StatelessWidget {
  final PlayerProvider player;
  final ColorScheme cs;

  const _ModeButton({required this.player, required this.cs});

  @override
  Widget build(BuildContext context) {
    final m = player.mode;
    final active = m != PlayMode.sequence;
    return IconButton(
      iconSize: 22,
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
        PlayMode.weighted => '加权随机',
      };
}

/// 进度条（v5 设计稿：细进度 + 下方时间标签）。
class _PlayerSeek extends StatefulWidget {
  final PlayerProvider player;
  final ColorScheme cs;

  /// 横屏三列页隐藏进度条下方时间，把空间留给封面。
  final bool showTime;
  const _PlayerSeek(
      {required this.player, required this.cs, this.showTime = true});

  @override
  State<_PlayerSeek> createState() => _PlayerSeekState();
}

class _PlayerSeekState extends State<_PlayerSeek> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: widget.player.player.positionStream,
      builder: (c, snap) {
        final pos = snap.data ?? Duration.zero;
        final dur = widget.player.player.duration ?? Duration.zero;
        final max = dur.inMilliseconds.toDouble();
        final cur = pos.inMilliseconds.toDouble().clamp(0, max == 0 ? 1 : max).toDouble();
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: widget.cs.primary,
                inactiveTrackColor: widget.cs.onSurface.withValues(alpha: 0.12),
                thumbColor: widget.cs.primary,
              ),
              child: Slider(
                min: 0,
                max: max == 0 ? 1 : max,
                value: cur,
                onChanged: (v) => widget.player.seek(Duration(milliseconds: v.toInt())),
              ),
            ),
            if (widget.showTime)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatClock(pos),
                        style: const TextStyle(fontFamily: 'monospace')),
                    Text(formatClock(dur),
                        style: const TextStyle(fontFamily: 'monospace')),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
