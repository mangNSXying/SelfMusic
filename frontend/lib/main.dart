import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'services/api_client.dart';
import 'services/server_settings.dart';
import 'services/selfmusic_audio_handler.dart';
import 'services/sync_engine.dart';
import 'providers/auth_provider.dart';
import 'providers/library_provider.dart';
import 'providers/direct_source_manager.dart';
import 'providers/playlists_provider.dart';
import 'providers/player_provider.dart';
import 'providers/navigation_provider.dart';
import 'theme/theme_provider.dart';
import 'theme/app_theme.dart';
import 'screens/library_screen.dart';
import 'screens/player_screen.dart';
import 'layout/app_shell.dart';
import 'widgets/app_toast.dart';
import 'widgets/player_sheet_anim.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 先加载「服务端」设置（后端地址）与本地索引（含直连源配置恢复），
  // 避免 UI 首次访问时的初始化竞态。
  final serverSettings = ServerSettings();
  await serverSettings.load();

  final api = ApiClient();
  if (serverSettings.baseUrl.isNotEmpty) {
    api.setBaseUrl(serverSettings.baseUrl);
  }

  final direct = DirectSourceManager();
  await direct.init();
  direct.attachApi(api);
  // 信任自签名证书开关（settings.md §3.3）：按 AppSettings 配置 dio 一次。
  api.setSelfSignedPolicy(direct.settings.allowSelfSigned);

  // 通知栏播放控制 / 后台播放（settings.md §3.6）：Android + 开关注册 audio_service。
  // 处理器本身在 PlayerProvider 创建时再绑定。
  // 失败时降级为无通知栏（audioHandler=null），不允许任何通知服务异常拖垮启动（曾致白屏）。
  SelfMusicAudioHandler? audioHandler;
  if (!kIsWeb && Platform.isAndroid && direct.settings.notificationControls) {
    try {
      audioHandler = await AudioService.init(
        builder: () => SelfMusicAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.shamiko.selfmusic.channel.audio',
          androidNotificationChannelName: 'SelfMusic 播放',
          androidNotificationChannelDescription: '播放控制与后台播放',
          // 暂停不退出前台服务：回到桌面/锁屏后系统不会回收服务，
          // 再次恢复播放也不会受 Android 12+ 后台启动前台服务限制。
          // （前台服务期间通知本就常驻，无需再设 androidNotificationOngoing）
          androidStopForegroundOnPause: false,
        ),
      );
    } catch (e) {
      debugPrint('AudioService.init 失败，通知栏控制降级关闭：$e');
    }
  }

  // 阶段5 多设备同步引擎：启动即开始（未配对/关开关时内部跳过），回前台追一次。
  final sync = SyncEngine(api: api, index: direct.index, settings: direct.settings)
    ..start();
  WidgetsBinding.instance.addObserver(_SyncLifecycleObserver(sync));

  runApp(SelfMusicApp(
      direct: direct,
      settings: serverSettings,
      api: api,
      audioHandler: audioHandler,
      sync: sync));
}

/// 回前台触发同步（阶段5）：无 connectivity 依赖，切后台期间的变更在恢复后追上。
class _SyncLifecycleObserver extends WidgetsBindingObserver {
  final SyncEngine sync;
  _SyncLifecycleObserver(this.sync);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(sync.syncNow());
  }
}

class SelfMusicApp extends StatelessWidget {
  final DirectSourceManager direct;
  final ServerSettings settings;
  final ApiClient api;
  final SelfMusicAudioHandler? audioHandler;
  final SyncEngine sync;
  const SelfMusicApp({
    super.key,
    required this.direct,
    required this.settings,
    required this.api,
    this.audioHandler,
    required this.sync,
  });

  @override
  Widget build(BuildContext context) {
    final auth = AuthProvider(api);
    // 播放流式取 token 依赖 Auth（懒读）。
    final lib = LibraryProvider()..attachDirectManager(direct);
    final nav = NavigationProvider();
    final player = PlayerProvider()
      ..attachSourceResolver((key) => direct.sourceByKey(key))
      ..attachAppSettings(direct.settings)
      ..attachServerAvailable(() => direct.isServerAvailable);
    player
      ..attachPersistence(
        index: direct.index,
        weight: direct.weight,
        onTrackStarted: (src, s) {
          direct.onTrackPlaying(src, s);
          // 预载下一首（开关在设置→服务端；与当前同首/随机模式跳过）。
          final next = player.peekNext();
          if (next != null &&
              (next.sourceKey != s.sourceKey ||
                  next.sourceRef != s.sourceRef)) {
            unawaited(direct.preloadSong(next));
          }
        },
        onSongMetaRefreshed: (s) => direct.notifySongMetaChanged(),
      )
      ..attachAudioHandlerIfAny(audioHandler);

    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<SyncEngine>.value(value: sync),
        ChangeNotifierProvider<ServerSettings>.value(value: settings),
        ChangeNotifierProvider<ThemeProvider>.value(value: ThemeProvider()),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<LibraryProvider>.value(value: lib),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<PlaylistsProvider>(
          create: (_) => PlaylistsProvider(direct.playlists),
        ),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
      ],
      child: const _ThemedApp(),
    );
  }
}

class _ThemedApp extends StatelessWidget {
  const _ThemedApp();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeProvider>();
    return MaterialApp(
      title: 'SelfMusic',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: toastMessengerKey,
      theme: theme.themeData,
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with TickerProviderStateMixin {
  bool _expiryDialogShown = false;
  DateTime? _lastBackPressed;

  /// 播放页悬浮层动画唯一控制器（壳常驻 + 播放页悬浮层跟手共用）。
  late final PlayerSheetAnimator _sheetAnim;
  late final NavigationProvider _nav;

  @override
  void initState() {
    super.initState();
    _nav = context.read<NavigationProvider>();
    _sheetAnim = PlayerSheetAnimator(
      vsync: this,
      progress: _nav.playerProgress,
    );
    _nav.addListener(_syncPlayerSheet);
    // 启动恢复上次播放队列与位置（暂停态，stage2.md §7）。
    // 受「断点续播」开关控制（settings.md §3.2 `resume_on_startup`）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final direct = context.read<DirectSourceManager>();
      if (!direct.settings.resumeOnStartup) return;
      context.read<PlayerProvider>().restoreIfAny();
    });
  }

  @override
  void dispose() {
    _nav.removeListener(_syncPlayerSheet);
    _sheetAnim.dispose();
    super.dispose();
  }

  /// 意图位（playerView）变化 → 播放页悬浮层吸附动画：
  /// 打开从底部升起（进度 1→0），离开降下（0→1）。手势跟手期间不触发。
  void _syncPlayerSheet() {
    if (_nav.playerView && _sheetAnim.value > 0.001) {
      _sheetAnim.settle(0);
    } else if (!_nav.playerView && _sheetAnim.value < 0.999) {
      _sheetAnim.settle(1);
    }
  }

  /// 统一返回：先按层级逐级回退（设置 → 队列 → 源内/歌单详情 → 内容页 → 播放页），
  /// 已在最底层（播放页）时「再按一次退出」（2 秒内再次按下才真正退出）。
  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    if (context.read<NavigationProvider>().backToPrevious()) return;
    final now = DateTime.now();
    if (_lastBackPressed != null &&
        now.difference(_lastBackPressed!) < const Duration(seconds: 2)) {
      if (Platform.isAndroid) {
        // 只结束 Activity：audio_service 前台服务继续，后台播放不中断。
        SystemNavigator.pop();
      } else {
        // 桌面端退出前先释放播放器（mpv 子进程），再终止进程。
        final player = context.read<PlayerProvider>();
        player.shutdown().whenComplete(() => exit(0));
      }
      return;
    }
    _lastBackPressed = now;
    AppToast.show('再按一次退出软件', isError: false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (!auth.bootstrapped) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (auth.sessionExpired && !_expiryDialogShown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showExpiryDialog(context, auth);
      });
    }
    // 首次启动不再强制配对：未配对也可正常使用直连模式；
    // 配对 / 会话过期后重新配对在「设置 → 服务端」进行。
    final nav = context.watch<NavigationProvider>();
    // 壳常驻（底层）；播放页为悬浮层（高层），按进度跟手位移。
    return Provider<PlayerSheetAnimator>.value(
      value: _sheetAnim,
      child: PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: _onPopInvoked,
        child: Stack(
          children: [
            const AppShell(content: AppContent()),
            ValueListenableBuilder<double>(
              valueListenable: nav.playerProgress,
              builder: (c, p, _) {
                if (!nav.playerView && p >= 1) {
                  return const SizedBox.shrink();
                }
                final h = MediaQuery.of(c).size.height;
                return Transform.translate(
                  offset: Offset(0, p * h),
                  child: const PlayerScreen(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showExpiryDialog(BuildContext context, AuthProvider auth) {
    _expiryDialogShown = true;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('会话已过期'),
        content: const Text('服务端登录已过期，多设备同步将暂停；本地播放不受影响。可在「设置 → 服务端」重新配对。'),
        actions: [
          TextButton(
            onPressed: () {
              auth.acceptSessionExpired();
              setState(() => _expiryDialogShown = false);
              Navigator.of(ctx).pop();
            },
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              auth.acceptSessionExpired();
              setState(() => _expiryDialogShown = false);
              Navigator.of(ctx).pop();
              context.read<NavigationProvider>().openSettings(SettingsItem.server);
            },
            child: const Text('去配对'),
          ),
        ],
      ),
    );
  }
}
