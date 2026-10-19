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
import 'services/audio_focus_monitor.dart';
import 'services/log_buffer.dart';
import 'services/server_settings.dart';
import 'services/selfmusic_audio_handler.dart';
import 'services/playback_guard.dart';
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
import 'widgets/draggable_sheet.dart';
import 'utils/perf_log.dart';
import 'utils/main_thread_probe.dart';
import 'widgets/player_sheet_anim.dart';
import 'utils/frame_scheduler.dart';
import 'utils/interaction_gate.dart';

/// 图片解码缓存上限（R-6 / T016）。
///
/// 口径复核结论：**列表缩略图**（落盘 768 长边、行内按 DPR 降解码，工作集约
/// 百 MB）与**播放页全尺寸封面**（单张可达十余 MB）共用同一 ImageCache。上限
/// 过大 → 内存压力 → GC 暂停 UI 线程（官方指南）；过小 → 大图挤出列表缓存，
/// 长会话反复重解码「越用越卡」（既有注释）。二者需真机实测平衡。
///
/// 现状保持既有经验值（不引入回退）；抽为常量便于 Phase 5 真机实测后统一调整。
/// **待 Phase 5 真机验证**：在目标机型上对比峰值内存 / GC 停顿 / 重解码次数。
const int kImageCacheMaxBytes = 512 << 20;
const int kImageCacheMaxCount = 4096;

Future<void> main() async {
  // 初始化应用内日志缓冲（先于其他初始化，确保能捕获全部启动日志）。
  LogBuffer.instance.init();
  runZonedGuarded(() async {
    // 临时诊断：主线程停滞探针（必须最先起，见 main_thread_probe）。
    startMainThreadStallProbe();
    // 冷启动定位：首个 perf 点同时是相对时间零点（见 perf_log），必须在最前。
    perfLog('boot.entry');
    WidgetsFlutterBinding.ensureInitialized();
    perfLog('boot.ensureInitialized');
  // 图片解码缓存扩容：默认 100MB/1000 张。播放页用的是全尺寸封面（单张解码
  // 内存可达十余 MB），连播几十首就会把列表缩略图全部挤出缓存，此后每次切页
  // 都要重新解码 → 长会话「越用越卡」。512MB 是上限而非预分配，LRU 照常淘汰；
  // 六个分区的缩略图工作集约百 MB，余量足够。上限取值与复核见 [kImageCacheMaxBytes]。
  PaintingBinding.instance.imageCache.maximumSizeBytes = kImageCacheMaxBytes;
  PaintingBinding.instance.imageCache.maximumSize = kImageCacheMaxCount;
  // 鸿蒙引导（sqlite3 系统库 / secure storage 文件实现 / just_audio→AVPlayer 适配）：
  // 必须先于任何存储访问与播放器创建；其它平台内部直接返回。
  await setupOhos();
  perfLog('boot.setupOhos done');
  // 桌面端（Windows/Linux）音频后端统一 media_kit（底层 libmpv）：默认参数即
  // Windows/Linux 启用、Android 关闭（Android 继续走 ExoPlayer），无需平台判断。
  // ohos 上其内部 UniversalPlatform 判断为 no-op，由上面的 AvPlayerJustAudio 接管。
  JustAudioMediaKit.ensureInitialized();
  perfLog('boot.mediaKit done');
  // 系统音量混合器 / 进程列表里显示的名字（默认 'JustAudioMediaKit'）。
  JustAudioMediaKit.title = 'SelfMusic';
  // 先加载「服务端」设置（后端地址）与本地索引（含直连源配置恢复），
  // 避免 UI 首次访问时的初始化竞态。
  //
  // 安全存储顶格预热（B）：首个 EncryptedSharedPreferences 读含通道预热
  // （实测首读 1~1.7s）。`loadFast` 已不碰安全存储，此处预热与后续
  // `direct.init()`（源密码读）/ 首帧后 `loadSlowSecrets` 重叠；
  // `_readToken` 自带单飞去重，AuthProvider / SyncEngine 后续读命中缓存。
  final api = ApiClient();
  unawaited(api.getClientId());
  unawaited(api.getAccessToken());
  final serverSettings = ServerSettings();
  await serverSettings.loadFast();
  perfLog('boot.serverSettings fast done');
  if (serverSettings.baseUrl.isNotEmpty) {
    api.setBaseUrl(serverSettings.baseUrl);
  }
  debugPrint('[boot] 服务端设置加载完成');

  final direct = DirectSourceManager();
  await direct.init();
  perfLog('boot.directInit done');
  debugPrint('[boot] 直连源管理器就绪');
  // 源补推（attachApi 内部 _bootstrapSourceSync）不参与首帧：见文末首帧后启动块。
  // 信任自签名证书开关（settings.md §3.3）：按 AppSettings 配置 dio 一次。
  api.setSelfSignedPolicy(direct.settings.allowSelfSigned);

  // 歌手身份解析（歌手处理.txt）：后台循环向 MusicBrainz 解析歌手身份；
  // 与 direct 互绑（扫描/补读后校准映射并唤醒），随应用生命周期运行。
  // 启动时机同同步引擎：首帧后（启动即解析会挤占启动帧且与首帧无关）。
  final artistResolver = ArtistResolver(direct.index)
    ..attachSettings(direct.settings);
  direct.attachArtistResolver(artistResolver);

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
  // 其余平台：桌面 / Web 保持原样（此前也没有通知栏）；鸿蒙走
  // OhosMediaSessionBridge，同款恒注册语义（开关只控制播控卡，长时任务保活
  // 恒在，见下方鸿蒙段）。自研 handler 与 media_kit / 鸿蒙 FVP 的
  // 自定义平台互不干扰，哪天要给这些平台开通知栏直接接上。
  //
  // 失败时降级为无通知栏（audioHandler=null），不允许任何通知服务异常拖垮启动（曾致白屏）。
  SelfMusicAudioHandler? audioHandler;
  if (!kIsWeb && Platform.isAndroid) {
    try {
      audioHandler =
          SelfMusicAudioHandler(showControls: direct.settings.notificationControls);
      perfLog('boot.audioService before');
      await AudioService.init(
        builder: () => audioHandler!,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.shamiko.selfmusic.channel.audio',
          androidNotificationChannelName: 'SelfMusic 播放',
          androidNotificationChannelDescription: '播放控制与后台播放',
          // 暂停不退出前台服务：回到桌面/锁屏后系统不会回收服务，再次恢复
          // 播放也不会受 Android 12+ 后台启动前台服务限制。（audio_service 中
          // 与 androidNotificationOngoing 互斥——ongoing 通知并不阻止进程
          // 回收，前台服务才是保活根基，故不用 ongoing。）
          androidStopForegroundOnPause: false,
          // 状态栏小图标：白色剪影矢量（通知图标仅取 alpha 通道染色），
          // 默认 mipmap 应用图标在浅色状态栏上会糊成灰色方块。
          androidNotificationIcon: 'drawable/ic_stat_selfmusic',
          // 通知强调色：品牌 teal（与 App 主题 defaultAccent 一致）。
          notificationColor: Color(0xFF00A098),
        ),
      );
      // 开关按设置页既定语义「重启生效」（见 settings_screen 的提示文案），
      // 不做运行时热切——按钮的增删还要走 MediaSession 通知重建，重启更稳。
      perfLog('boot.audioService done');
    } catch (e) {
      audioHandler = null;
      perfLog('boot.audioService failed');
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
  //
  // 与 Android 同语义（恒注册）：**不再按 notificationControls gate 整个桥**——
  // 桥还承担 AUDIO_PLAYBACK 长时任务（息屏保活的根基），一并 gate 掉后关开关
  // = 无长时任务，息屏即被系统挂起、播放自动终止（与安卓修复前的旧 bug 同型，
  // 设置文案「关闭只隐藏按钮」在鸿蒙侧曾不成立）。开关现在只经 [showControls]
  // 控制建不建 AVSession（播控卡渲不渲染），长时任务恒随播放申请；重启生效。
  OhosMediaSessionBridge? ohosMediaSession;
  if (!kIsWeb && isOhos) {
    ohosMediaSession = OhosMediaSessionBridge(direct,
        showControls: direct.settings.notificationControls);
  }

  // 阶段5 多设备同步引擎：首帧后启动（见下方首帧后启动块），回前台追一次。
  // 落库回调一律经 [scheduleAfterFrame] 推迟到帧末：拉取完成当帧不做整库
  // 重建/源重载，避免同步与渲染抢同一轮事件循环（同步后台化）。
  final sync = SyncEngine(api: api, index: direct.index, settings: direct.settings);
  sync.onSourcesApplied = () {
    scheduleAfterFrame(() {
      unawaited(direct.reloadSourcesFromIndex());
    });
  };
  // 远端拉回的收藏/权重落库后刷新行缓存与版本，否则喜欢页与列表行仍显示旧态。
  sync.onSongStatesApplied = () {
    scheduleAfterFrame(direct.notifyPlayMetaChanged);
  };
  WidgetsBinding.instance.addObserver(_SyncLifecycleObserver(sync));

  debugPrint('[boot] 进入 runApp');
  perfLog('boot.preRunApp');
  // 交互门控（R-2）：聚合滚动/过渡/浮层/队列状态，交互期合帧投递数据通知；
  // 在 runApp 前创建并注入 DirectSourceManager，保证后续所有通知都经门控。
  final interactionGate = InteractionGate();
  direct.attachInteractionGate(interactionGate);
  runApp(SelfMusicApp(
      direct: direct,
      settings: serverSettings,
      api: api,
      audioHandler: audioHandler,
      ohosMediaSession: ohosMediaSession,
      artistResolver: artistResolver,
      sync: sync,
      interactionGate: interactionGate));
  perfLog('boot.runApp dispatched');
  // 首帧轻量化：源补推 / 歌手解析 / 同步引擎都不参与首帧渲染，统一推迟到
  // 首帧渲染完成后启动——此前它们在 runApp 前就发起网络请求与同步 DB 读，
  // 与首帧渲染抢事件循环（启动期掉帧的根因之一）。Root 只 `awaitFirstPull`
  // 等在飞行的首轮收尾，不会重复发起新一轮。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    perfLog('boot.postFrame start');
    direct.attachApi(api); // 内部补发存量 source.create（有服务器才发）
    artistResolver.start();
    sync.start();
    // 服务端设置慢阶段（A）：配对密钥安全存储读 + 明文迁移。此时插件已预热，
    // 且首帧已出，不再阻塞启动链；配对页/设置页是深层页，读不到密钥不受影响。
    unawaited(serverSettings
        .loadSlowSecrets()
        .then((_) => perfLog('boot.serverSettings slow done')));
    perfLog('boot.postFrame done');
  });
  // main() 全链（含所有 await）走完的最终信号：ArkTS 启动看门狗据此解除
  // （超时未收到则向 Dart 发消息唤醒可能停滞的事件循环，见 ohos_bootstrap）。
  markBootReady();
  }, (Object error, StackTrace stack) {
    LogBuffer.instance.recordError(error, stack);
    debugPrint('Uncaught zone error: $error\n$stack');
  });
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
  final InteractionGate interactionGate;
  const SelfMusicApp({
    super.key,
    required this.direct,
    required this.settings,
    required this.api,
    this.audioHandler,
    this.ohosMediaSession,
    required this.sync,
    required this.artistResolver,
    required this.interactionGate,
  });

  @override
  Widget build(BuildContext context) {
    perfLog('boot.firstBuild SelfMusicApp');
    final auth = AuthProvider(api);
  // 播放流式取 token 依赖 Auth（懒读）。
  final lib = LibraryProvider()
    ..attachDirectManager(direct)
    // 歌手解析/成员展开落库后就地重算歌手列表（停在旧计数的问题，见 library_provider）。
    ..attachArtistResolver(artistResolver);
  final nav = NavigationProvider();
    final player = PlayerProvider()
      ..attachSourceResolver((key) => direct.sourceByKey(key))
      ..attachLineCandidates((key) => direct.lineCandidates(key))
      ..attachAppSettings(direct.settings)
      ..attachApi(api)
      ..attachServerAvailable(() => direct.isServerAvailable)
      ..attachAudioGuard(AudioGuardPlatform.forCurrentPlatform())
      // 鸿蒙 AVPlayer 音频焦点（Android 由 just_audio 内部处理，空流）。
      ..attachAudioFocus(AudioFocusPlatform.forCurrentPlatform())
      // 同步引擎钩子：实际播放态驱动后台同步门控（播放中后台仍同步），
      // 播放/暂停/切歌后即时推一轮（单飞合并；未注入不影响播放）。
      ..attachSyncHooks(
        onPlayingChanged: sync.setPlaying,
        onSyncPoke: sync.poke,
      );
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
        resolveTranscodeCache: direct.cachedTranscodePath,
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
        ChangeNotifierProvider<InteractionGate>.value(value: interactionGate),
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
  bool _bootBuildLogged = false;

  /// 首帧避让（P0-3）：播放页为首页（`playerView=true/p=0` 全覆盖不透明），
  /// 底层壳首帧不挂载，首帧后补挂。播放页收起（`playerView=false` 或跟手
  /// 移位）时按门条件即时放行，不等首帧。
  bool _contentReady = false;

  /// 播放页悬浮层动画唯一控制器（壳常驻 + 播放页悬浮层跟手共用）。
  late final PlayerSheetAnimator _sheetAnim;
  /// 统一拖拽式窗口宿主启动器（队列滑动启动的跟手过渡 + 各窗口点击启动共用）。
  late final AppSheetLauncher _sheetLauncher;
  late final NavigationProvider _nav;
  late final SyncEngine _syncEngine;

  /// 交互门控：播放页浮层跟手/吸附进行中标记为「交互中」。
  InteractionGate? _gate;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gate = InteractionGate.maybeOf(context);
  }

  @override
  void initState() {
    super.initState();
    perfLog('boot.firstBuild Root.initState');
    _nav = context.read<NavigationProvider>();
    _syncEngine = context.read<SyncEngine>();
    // 同步拉到歌单后刷新 Provider 缓存：落库直写 SQLite，
    // 不刷则新歌单只进库不进列表（重启前不可见）。回调携带本轮变更的
    // 歌单 uuid，Provider 只对这些歌单重查计数（增量刷新）；并推迟到帧末，
    // 避免同步落库当帧整列表重建抢渲染。
    _syncEngine.onPlaylistsApplied = (uuids) {
      if (!mounted) return;
      scheduleAfterFrame(() {
        if (!mounted) return;
        context.read<PlaylistsProvider>().refresh(changedUuids: uuids);
      });
    };
    // 同步拉到更新的远端断点（当前曲/进度/深层列表）后，空闲时套用到播放器：
    // 启动补切 / 回前台 / 手动「立即同步」统一走此回调（刻意播放中不打断由
    // PlayerProvider.applyNewerMirrorIfAny 内部守卫）。
    _syncEngine.onBreakpointsApplied = () {
      if (!mounted) return;
      unawaited(context
          .read<PlayerProvider>()
          .applyNewerMirrorIfAny(viaSync: true));
    };
    _sheetAnim = PlayerSheetAnimator(
      vsync: this,
      progress: _nav.playerProgress,
    );
    _sheetLauncher = AppSheetLauncher(vsync: this);
    // 首帧避让（P0-3）：首帧只画播放页（首页），底层壳推迟一帧补挂，
    // 把 SectionPager 六分组的首帧构建移出 Davey 窗口。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _contentReady) return;
      setState(() => _contentReady = true);
    });
    _nav.addListener(_syncPlayerSheet);
    // 播放页悬浮层位移从 0/1 到中间（跟手或吸附）即视为「过渡中」。
    _nav.playerProgress.addListener(_onPlayerProgress);
    // 启动恢复上次播放队列与位置（暂停态，stage2.md §7）。
    // 受「断点续播」开关控制（settings.md §3.2 `resume_on_startup`）。
    //
    // 恢复在 initState 内同步发起：其同步前缀（取本机/镜像断点、重建队列、
    // 置当前曲与乐观位置）在首帧 build 前即完成，播放页首帧直接渲染上次
    // 断点而非「未在播放」占位；音频装载/seek 在后台异步继续。
    final direct = context.read<DirectSourceManager>();
    final player = context.read<PlayerProvider>();
    final Future<void> restoreFuture;
    if (direct.settings.resumeOnStartup) {
      restoreFuture = player.restorePreferRemote();
    } else {
      restoreFuture = Future<void>.value();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!direct.settings.resumeOnStartup) return;
      // 先等恢复完成再首拉：保持既有「先恢复、后拉取、再补切」顺序，避免首拉
      // 回调与恢复进行中的装载竞争。
      final swRestore = Stopwatch()..start();
      await restoreFuture;
      perfLog('root.boot localRestoreDone', '${swRestore.elapsedMilliseconds}ms');
      if (!mounted) return;
      // 等启动首轮 pull 收尾（在飞行则只等待，不额外发起新一轮）：拉到更新的
      // 远端断点且用户尚未接管播放时，applyNewerMirrorIfAny 再切过去（不打断
      // 用户主动操作；播放中由 PlayerProvider 内部守卫）。
      final syncedAtBefore = direct.settings.lastSyncAt;
      final engine = context.read<SyncEngine>();
      final swFirstPull = Stopwatch()..start();
      await engine.awaitFirstPull();
      perfLog('root.boot awaitFirstPullDone',
          '${swFirstPull.elapsedMilliseconds}ms lastError=${engine.lastError}');
      if (!mounted) return;
      // 启动首次同步成功 toast（周期同步与自动补推保持静默，
      // 手动同步的 toast 在设置页 _syncNow 内）。
      if (engine.lastError.isEmpty &&
          context.read<DirectSourceManager>().settings.lastSyncAt !=
              syncedAtBefore) {
        perfLog('root.boot toast');
        AppToast.show('同步完成', isError: false);
      }
      final swApply = Stopwatch()..start();
      await player.applyNewerMirrorIfAny();
      perfLog('root.boot applyDone', '${swApply.elapsedMilliseconds}ms');
    });
  }

  @override
  void dispose() {
    _nav.removeListener(_syncPlayerSheet);
    _nav.playerProgress.removeListener(_onPlayerProgress);
    _syncEngine.onPlaylistsApplied = null;
    _syncEngine.onBreakpointsApplied = null;
    _sheetAnim.dispose();
    _sheetLauncher.dispose();
    _gate?.setPlayerSheetDragging(false);
    super.dispose();
  }

  /// 播放页悬浮层进度 → 门控：位于 (0,1) 之间表示正在跟手/吸附（过渡中）。
  void _onPlayerProgress() {
    final gate = _gate;
    if (gate == null) return;
    final p = _nav.playerProgress.value;
    gate.setPlayerSheetDragging(p > 0.001 && p < 0.999);
  }

  /// 意图位（playerView）变化 → 播放页悬浮层吸附动画：
  /// 打开从底部升起（进度 1→0），离开降下（0→1）。手势跟手期间不触发。
  void _syncPlayerSheet() {
    if (_nav.playerView && _sheetAnim.value > 0.001) {
      // 临时埋点（播放页打开卡顿定位）：吸附耗时（期望 ~300ms，明显更长
      // 说明 UI 线程在动画窗口内被挂载构建等工作阻塞）+ 帧间隔汇总。
      final sw = Stopwatch()..start();
      perfLog('player.open settleStart',
          'from=${_sheetAnim.value.toStringAsFixed(3)}');
      _startPlayerOpenProbe();
      _sheetAnim.settle(0, onDone: () {
        final ms = sw.elapsedMilliseconds;
        perfLog('player.open settleDone', '${ms}ms (expected ~300ms)');
        _finishPlayerOpenProbe(ms);
      });
    } else if (!_nav.playerView && _sheetAnim.value < 0.999) {
      _sheetAnim.settle(1);
    }
  }

  /// 临时埋点（播放页打开卡顿定位，用完即删）：收集打开动画窗口内的帧时间戳。
  ///
  /// 每帧的 post-frame 回调里记一个点；链式注册直到 30 帧（≈500ms@60Hz，
  /// 覆盖 300ms 打开动画 + 定稿）。中途被新手势打断时靠代次号丢弃旧链。
  List<int>? _openProbe;
  int _openProbeGen = 0;

  void _startPlayerOpenProbe() {
    final gen = ++_openProbeGen;
    final frames = <int>[DateTime.now().millisecondsSinceEpoch];
    _openProbe = frames;
    void tick() {
      if (!mounted || gen != _openProbeGen) return;
      frames.add(DateTime.now().millisecondsSinceEpoch);
      if (frames.length < 30) {
        WidgetsBinding.instance.addPostFrameCallback((_) => tick());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => tick());
  }

  void _finishPlayerOpenProbe(int settleMs) {
    final frames = _openProbe;
    _openProbe = null;
    if (frames == null || frames.length < 2) return;
    var maxGap = 0;
    var over25 = 0;
    var over50 = 0;
    for (var i = 1; i < frames.length; i++) {
      final gap = frames[i] - frames[i - 1];
      if (gap > maxGap) maxGap = gap;
      if (gap > 25) over25++;
      if (gap > 50) over50++;
    }
    // 60Hz 下正常帧间隔约 17ms；出现远大于此的 gap 即掉帧点。
    perfLog('player.open summary',
        'settle=${settleMs}ms frames=${frames.length} maxGap=${maxGap}ms over25=$over25 over50=$over50');
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
    if (!_bootBuildLogged) {
      _bootBuildLogged = true;
      perfLog('boot.firstBuild Root.build');
    }
    final auth = context.watch<AuthProvider>();

    // bootstrapped 只门控过期弹窗，不门控首帧内容：直连模式无需配对即可用
    // （P0-4）。原先转圈会吞掉首帧，把 AppContent/PlayerScreen 全推迟到
    // token 读完（实测 +1264ms），还强制第二次大布局。
    if (auth.bootstrapped && auth.sessionExpired && !_expiryDialogShown) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showExpiryDialog(context, auth);
      });
    }
    // 首次启动不再强制配对：未配对也可正常使用直连模式；
    // 配对 / 会话过期后重新配对在「设置 → 服务端」进行。
    // 订阅收窄（T006）：Root 仅关注播放页可见性；悬浮层进度由 playerProgress
    // （ValueNotifier）独立逐帧驱动，区段/搜索等变更不重建 Root。
    final playerView =
        context.select<NavigationProvider, bool>((n) => n.playerView);
    // 底层壳首帧避让（P0-3）+ 播放页悬浮层（高层）按进度跟手位移。
    return MultiProvider(
      providers: [
        Provider<PlayerSheetAnimator>.value(value: _sheetAnim),
        Provider<AppSheetLauncher>.value(value: _sheetLauncher),
      ],
      child: PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: _onPopInvoked,
        child: Stack(
          children: [
            ValueListenableBuilder<double>(
              valueListenable: _nav.playerProgress,
              builder: (c, p, _) {
                // 播放页全覆盖（首页初态）且首帧未过：底层不可见，跳过挂载。
                // 首帧后（_contentReady）或播放页收起/跟手中一律正常挂载。
                if (!_contentReady && playerView && p <= 0.001) {
                  return const SizedBox.shrink();
                }
                return const AppShell(content: AppContent());
              },
            ),
            // 窄屏队列窗口由 [AppSheetLauncher] 的悬浮层承载（宿主 AppSheetHost
            // 挂在 AppShell 内，不 push 路由，见 openQueueSheet /
            // beginQueueSheetSwipe），不在本 Stack 内。
            ValueListenableBuilder<double>(
              valueListenable: _nav.playerProgress,
              builder: (c, p, _) {
                if (!playerView && p >= 1) {
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
