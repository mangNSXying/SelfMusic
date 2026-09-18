import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/api_client.dart';
import 'services/server_settings.dart';
import 'services/selfmusic_audio_handler.dart';
import 'data/sources/server_proxy_source.dart';
import 'providers/auth_provider.dart';
import 'providers/library_provider.dart';
import 'providers/direct_source_manager.dart';
import 'providers/playlists_provider.dart';
import 'providers/player_provider.dart';
import 'providers/navigation_provider.dart';
import 'theme/theme_provider.dart';
import 'theme/app_theme.dart';
import 'screens/library_screen.dart';
import 'layout/app_shell.dart';

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
  // 已配对的设备在启动时拉取服务端缓存建议值（settings.md §3.3 follow_server）。
  if (serverSettings.baseUrl.isNotEmpty) {
    unawaited(direct.refreshServerConfig());
  }

  // 通知栏播放控制 / 后台播放（settings.md §3.6）：Android + 开关注册 audio_service。
  // 处理器本身在 PlayerProvider 创建时再绑定。
  // 失败时降级为无通知栏（audioHandler=null），不允许任何通知服务异常拖垮启动（曾致白屏）。
  SelfMusicAudioHandler? audioHandler;
  if (!kIsWeb &&
      Platform.isAndroid &&
      direct.settings.notificationControls) {
    try {
      audioHandler = await AudioService.init(
        builder: () => SelfMusicAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId:
              'com.selfmusic.selfmusic.channel.audio',
          androidNotificationChannelName: 'SelfMusic 播放',
          androidNotificationChannelDescription: '播放控制与后台播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
        ),
      );
    } catch (e) {
      debugPrint('AudioService.init 失败，通知栏控制降级关闭：$e');
    }
  }

  runApp(SelfMusicApp(
      direct: direct, settings: serverSettings, api: api, audioHandler: audioHandler));
}

class SelfMusicApp extends StatelessWidget {
  final DirectSourceManager direct;
  final ServerSettings settings;
  final ApiClient api;
  final SelfMusicAudioHandler? audioHandler;
  const SelfMusicApp({
    super.key,
    required this.direct,
    required this.settings,
    required this.api,
    this.audioHandler,
  });

  @override
  Widget build(BuildContext context) {
    final auth = AuthProvider(api);
    // 播放流式取 token 依赖 Auth（懒读）。
    final lib = LibraryProvider(
      ServerProxySource(
        dio: api.dio,
        baseUrl: api.baseUrl,
        tokenProvider: () => auth.token ?? '',
      ),
    )
      ..serverConfigured = settings.baseUrl.isNotEmpty
      ..attachDirectManager(direct);
    final nav = NavigationProvider();

    return MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<ServerSettings>.value(value: settings),
        ChangeNotifierProvider<ThemeProvider>.value(value: ThemeProvider()),
        ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ChangeNotifierProvider<LibraryProvider>.value(value: lib),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<PlaylistsProvider>(
          create: (_) => PlaylistsProvider(direct.playlists),
        ),
        ChangeNotifierProvider<PlayerProvider>(
          create: (_) => PlayerProvider()
            ..attachSourceResolver((key) {
              if (key == 'server') return lib.source;
              return direct.sourceByKey(key);
            })
            ..attachAppSettings(direct.settings)
            ..attachPersistence(
              index: direct.index,
              weight: direct.weight,
              onTrackStarted: (src, s) => direct.onTrackPlaying(src, s),
            )
            ..attachAudioHandlerIfAny(audioHandler),
        ),
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

class _RootState extends State<Root> {
  bool _expiryDialogShown = false;

  @override
  void initState() {
    super.initState();
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
    return const AppShell(
      content: AppContent(),
    );
  }

  void _showExpiryDialog(BuildContext context, AuthProvider auth) {
    _expiryDialogShown = true;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('会话已过期'),
        content: const Text('服务端登录已过期，服务端功能将不可用；可直接使用直连模式，或在「设置 → 服务端」重新配对。'),
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
