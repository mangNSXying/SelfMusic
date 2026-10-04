import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'platform/app_background.dart';
import 'platform/harmonyos/ohos_bootstrap.dart';
import 'platform/harmonyos/ohos_media_session.dart';
import 'services/api_client.dart';
import 'services/server_settings.dart';
import 'services/selfmusic_audio_handler.dart';
import 'services/sync_engine.dart';
import 'services/artist_resolver.dart';
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
  // 鸿蒙引导（sqlite3 系统库 / secure storage 文件实现 / just_audio→fvp 适配）：
  // 必须先于任何存储访问与播放器创建；其它平台内部直接返回。
  await setupOhos();
  // 桌面端（Windows/Linux）音频后端统一 media_kit（底层 libmpv）：默认参数即
  // Windows/Linux 启用、Android 关闭（Android 继续走 ExoPlayer），无需平台判断。
  // ohos 上其内部 UniversalPlatform 判断为 no-op，由上面的 FvpJustAudio 接管。
  JustAudioMediaKit.ensureInitialized();
  // 系统音量混合器 / 进程列表里显示的名字（默认 'JustAudioMediaKit'）。
  JustAudioMediaKit.title = 'SelfMusic';
  // 先加载「服务端」设置（后端地址）与本地索引（含直连源配置恢复），
  // 避免 UI 首次访问时的初始化竞态。
  final serverSettings = ServerSettings();
  await serverSettings.load();
  debugPrint('[boot] 服务端设置加载完成');

  final api = ApiClient();
  if (serverSettings.baseUrl.isNotEmpty) {
    api.setBaseUrl(serverSettings.baseUrl);
  }

  final direct = DirectSourceManager();
  await direct.init();
  debugPrint('[boot] 直连源管理器就绪');
  direct.attachApi(api);
  // 信任自签名证书开关（settings.md §3.3）：按 AppSettings 配置 dio 一次。
  api.setSelfSignedPolicy(direct.settings.allowSelfSigned);

  // 歌手身份解析（歌手处理.txt）：后台循环向 MusicBrainz 解析歌手身份；
  // 与 direct 互绑（扫描/补读后校准映射并唤醒），随应用生命周期运行。
  final artistResolver = ArtistResolver(direct.index)
    ..attachSettings(direct.settings);
  direct.attachArtistResolver(artistResolver);
  artistResolver.start();

  // 通知栏播放控制 / 后台播放（settings.md §3.6）：Android 恒注册。
  //
  // Android 走 audio_service 自研处理器 [SelfMusicAudioHandler]（改进.txt UI5：
  // 通知栏重写为 5 键——上一首/播放·暂停/下一首/播放模式/退出软件，收起视图取
  // 前三个，图标全部为品牌色矢量 ic_np_*）。它不劫持 just_audio 平台实例，播放
  // 命令经 PlayerProvider 转发，状态变化由 sync() 回推通知栏与系统媒体控件。
  //
  // 「通知栏播放控制」开关只控制通知里渲不渲染那 5 个按钮，**不再决定要不要注册**
  // （先前一并 gate 掉，用户一关开关就同时失去前台服务与播放期 wake lock——而
  // just_audio 的 ExoPlayer 不设 setWakeMode，息屏/Doze 下必然被系统回收，
  // 表现为「后台放一会儿就没声了」）。开关语义是「按钮」，不是「后台播放」。
  //
  // 其余平台（桌面 / 鸿蒙 / Web）保持原样：此前也没有通知栏，迁移不引入未验证的
  // 行为。鸿蒙走 OhosMediaSessionBridge。自研 handler 与 media_kit / 鸿蒙 FVP 的
  // 自定义平台互不干扰，哪天要给这些平台开通知栏直接接上。
  //
  // 失败时降级为无通知栏（audioHandler=null），不允许任何通知服务异常拖垮启动（曾致白屏）。
  SelfMusicAudioHandler? audioHandler;
  if (!kIsWeb && Platform.isAndroid) {
    try {
      audioHandler =
          SelfMusicAudioHandler(showControls: direct.settings.notificationControls);
      await AudioService.init(
        builder: () => audioHandler!,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.shamiko.selfmusic.channel.audio',
          androidNotificationChannelName: 'SelfMusic 播放',
          androidNotificationChannelDescription: '播放控制与后台播放',
          // 暂停不退出前台服务：回到桌面/锁屏后系统不会回收服务，
          // 再次恢复播放也不会受 Android 12+ 后台启动前台服务限制。
          androidStopForegroundOnPause: true,
          // 将通知标记为 ongoing，降低被系统清理/杀死时的优先级风险
          androidNotificationOngoing: true,
          // 状态栏小图标：白色剪影矢量（通知图标仅取 alpha 通道染色），
          // 默认 mipmap 应用图标在浅色状态栏上会糊成灰色方块。
          androidNotificationIcon: 'drawable/ic_stat_selfmusic',
          // 通知强调色：品牌 teal（与 App 主题 defaultAccent 一致）。
          notificationColor: Color(0xFF00A098),
        ),
      );
      // 开关按设置页既定语义「重启生效」（见 settings_screen 的提示文案），
      // 不做运行时热切——按钮的增删还要走 MediaSession 通知重建，重启更稳。
    } catch (e) {
      audioHandler = null;
      debugPrint('audio_service 初始化失败，通知栏控制降级关闭：$e');
    }
    // Android 13+（API 33）不授予 POST_NOTIFICATIONS 就不显示任何通知，
    // 前台服务照跑但通知栏里空空如也——播放控制、锁屏播控全部消失，只剩任务管理
    // 里一行灰字。随播放能力一起申请最自然（用户此刻正要听歌），而不是冷启动
    // 就弹权限框。33 以下 Permission.notification 直接 granted，不会打扰。
    unawaited(_ensureNotificationPermission());
  }

  // 鸿蒙 AVSession 媒体播控（通知栏/锁屏/播控中心 + 后台长时任务）：
  // 桥与自研 handler 同模式不劫持播放器；ArkTS 侧 AvSessionBridge 挂系统
  // 会话。构造仅注册通道回调，通道调用异常由桥内部兜底，不影响播放主流程。
  OhosMediaSessionBridge? ohosMediaSession;
  if (!kIsWeb && isOhos && direct.settings.notificationControls) {
    ohosMediaSession = OhosMediaSessionBridge(direct);
  }

  // 阶段5 多设备同步引擎：启动即开始（未配对/关开关时内部跳过），回前台追一次。
  final sync = SyncEngine(api: api, index: direct.index, settings: direct.settings);
  sync.onSourcesApplied = () {
    unawaited(direct.reloadSourcesFromIndex());
  };
  sync.start();
  WidgetsBinding.instance.addObserver(_SyncLifecycleObserver(sync));

  debugPrint('[boot] 进入 runApp');
  runApp(SelfMusicApp(
      direct: direct,
      settings: serverSettings,
      api: api,
      audioHandler: audioHandler,
      ohosMediaSession: ohosMediaSession,
      artistResolver: artistResolver,
      sync: sync));
  // main() 全链（含所有 await）走完的最终信号：ArkTS 启动看门狗据此解除
  // （超时未收到则向 Dart 发消息唤醒可能停滞的事件循环，见 ohos_bootstrap）。
  markBootReady();
}

/// 回前台触发同步（阶段5）：无 connectivity 依赖，切后台期间的变更在恢复后追上。
class _SyncLifecycleObserver extends WidgetsBindingObserver {
  final SyncEngine sync;
  _SyncLifecycleObserver(this.sync);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // 后台期间定时器是停的（见 [SyncEngine.pause]），恢复时补一轮：
        // 积压的 outbox 与已过期的拉取间隔都在 [_onTick] 里判，够不到就不发请求。
        sync.resume();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        sync.pause();
      case AppLifecycleState.inactive:
        // 短暂失去焦点（通知栏下拉、来电、多任务切换）不暂停：继续播的关键是
        // 后台音频，此时停表反而会漏掉 outbox 上传。
        break;
    }
  }
}

/// 申请 Android 13+ 通知权限。
///
/// 已授予 / 不需要 / 系统弹过「不再询问」三种情况都在这里静默返回——权限框只弹
/// 一次，用户拒了不该每次启动再纠缠。拒绝也不影响播放：前台服务照常注册，只是
/// 通知栏里不显示。
Future<void> _ensureNotificationPermission() async {
  try {
    if (await Permission.notification.isGranted) return;
    final st = await Permission.notification.request();
    debugPrint('[boot] POST_NOTIFICATIONS：$st');
  } catch (e) {
    // 权限通道异常不许影响启动与播放。
    debugPrint('通知权限申请失败（忽略）：$e');
  }
}

class SelfMusicApp extends StatelessWidget {
  final DirectSourceManager direct;
  final ServerSettings settings;
  final ApiClient api;
  final SelfMusicAudioHandler? audioHandler;
  final OhosMediaSessionBridge? ohosMediaSession;
  final SyncEngine sync;
  final ArtistResolver artistResolver;
  const SelfMusicApp({
    super.key,
    required this.direct,
    required this.settings,
    required this.api,
    this.audioHandler,
    this.ohosMediaSession,
    required this.sync,
    required this.artistResolver,
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
          // 切歌后由直连任务队列重排：当前曲元数据（最高）→ 下一首完整音频预载
          // → 下一首元数据/封面 → 全库后台补读。
          direct.onTrackPlaying(src, s, next: player.nextUpSong);
        },
        onSongMetaRefreshed: (s) => direct.notifySongMetaChanged(),
        onNextChanged: (next) => direct.onNextChanged(next),
        submitCurrentMeta: direct.submitCurrentMeta,
      )
      ..attachAudioHandlerIfAny(audioHandler);
    // 鸿蒙 AVSession 桥接线：attach 注册回推钩子与 direct 监听，
    // 此后播放/暂停/切歌/seek/模式/收藏变化自动同步系统播控卡。
    ohosMediaSession?.attach(player);

    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<SyncEngine>.value(value: sync),
        ChangeNotifierProvider<ServerSettings>.value(value: settings),
        ChangeNotifierProvider<ThemeProvider>.value(value: ThemeProvider()),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<LibraryProvider>.value(value: lib),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<ArtistResolver>.value(value: artistResolver),
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
      navigatorKey: appNavigatorKey,
      theme: theme.themeData,
      darkTheme: theme.darkThemeData,
      themeMode: theme.themeMode,
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

  /// 播放页悬浮层动画唯一控制器（壳常驻 + 播放页悬浮层跟手共用）。
  late final PlayerSheetAnimator _sheetAnim;
  late final NavigationProvider _nav;
  late final SyncEngine _syncEngine;

  @override
  void initState() {
    super.initState();
    _nav = context.read<NavigationProvider>();
    _syncEngine = context.read<SyncEngine>();
    // 同步拉到歌单后刷新 Provider 缓存：落库直写 SQLite，
    // 不刷则新歌单只进库不进列表（重启前不可见）。
    _syncEngine.onPlaylistsApplied = () {
      if (!mounted) return;
      context.read<PlaylistsProvider>().refresh();
    };
    _sheetAnim = PlayerSheetAnimator(
      vsync: this,
      progress: _nav.playerProgress,
    );
    _nav.addListener(_syncPlayerSheet);
    // 启动恢复上次播放队列与位置（暂停态，stage2.md §7）。
    // 受「断点续播」开关控制（settings.md §3.2 `resume_on_startup`）。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final direct = context.read<DirectSourceManager>();
      if (!direct.settings.resumeOnStartup) return;
      // 先等一轮拉取（带超时），以便跨设备断点参与启动恢复比较。
      final syncedAtBefore = direct.settings.lastSyncAt;
      await context.read<SyncEngine>().firstPull();
      if (!mounted) return;
      // 启动首次同步成功 toast（周期同步与自动补推保持静默，
      // 手动同步的 toast 在设置页 _syncNow 内）。
      final engine = context.read<SyncEngine>();
      if (engine.lastError.isEmpty &&
          context.read<DirectSourceManager>().settings.lastSyncAt !=
              syncedAtBefore) {
        AppToast.show('同步完成', isError: false);
      }
      await context.read<PlayerProvider>().restorePreferRemote();
    });
  }

  @override
  void dispose() {
    _nav.removeListener(_syncPlayerSheet);
    _syncEngine.onPlaylistsApplied = null;
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
  /// 已在最底层时不再二次确认：Android 直接 `SystemNavigator.pop()` 回桌面
  /// （audio_service 前台服务继续、播放不中断）；桌面端直接退出进程。
  void _onPopInvoked(bool didPop, Object? result) {
    if (didPop) return;
    if (context.read<NavigationProvider>().backToPrevious()) return;
    if (Platform.isAndroid || isOhos) {
      // 移动端返回手势 = 移到后台（与 home 键等效）：音乐后台续播，不销毁
      // 应用。曾直接退出（Android SystemNavigator.pop 销毁 Activity；ohos
      // 误入桌面退出分支 exit(0) 杀进程），侧滑返回无法后台播放
      // （2026-09-29 用户反馈，安卓平台同样存在，一并修复）。
      final player = context.read<PlayerProvider>();
      unawaited(moveAppToBackground().then((ok) {
        if (ok) return;
        // 兜底（通道异常的极端环境）：保持旧行为。
        if (Platform.isAndroid) {
          // 只结束 Activity：audio_service 前台服务继续，后台播放不中断。
          SystemNavigator.pop();
        } else {
          player.shutdown().whenComplete(() => exit(0));
        }
      }));
      return;
    }
    // 桌面端退出前先释放播放器（mpv 子进程），再终止进程。
    final player = context.read<PlayerProvider>();
    player.shutdown().whenComplete(() => exit(0));
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
