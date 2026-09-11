import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/api_client.dart';
import 'services/server_settings.dart';
import 'data/sources/server_proxy_source.dart';
import 'providers/auth_provider.dart';
import 'providers/library_provider.dart';
import 'providers/direct_source_manager.dart';
import 'providers/playlists_provider.dart';
import 'providers/player_provider.dart';
import 'providers/navigation_provider.dart';
import 'theme/theme_provider.dart';
import 'screens/pairing_screen.dart';
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
  runApp(SelfMusicApp(direct: direct, settings: serverSettings, api: api));
}

class SelfMusicApp extends StatelessWidget {
  final DirectSourceManager direct;
  final ServerSettings settings;
  final ApiClient api;
  const SelfMusicApp({
    super.key,
    required this.direct,
    required this.settings,
    required this.api,
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
    )..attachDirectManager(direct);
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
            ..attachPersistence(
              index: direct.index,
              weight: direct.weight,
              onTrackStarted: (src, s) => direct.onTrackPlaying(src, s),
            ),
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
    // 启动时恢复上次播放队列与位置（暂停态，stage2.md §7）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<PlayerProvider>().restoreIfAny();
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
    if (!auth.isPaired || auth.sessionExpired) {
      return const PairingScreen();
    }

    // 播放页作为内容区的一种视图：导航到“歌曲”后从列表进入播放页时，
    // 通过 PlayerProvider 会话状态在内容区切换展示。
    return const AppShell(
      content: AppContent(),
    );
  }

  void _showExpiryDialog(BuildContext context, AuthProvider auth) {
    _expiryDialogShown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('会话已过期'),
        content: const Text('登录已过期，请重新配对后继续使用。'),
        actions: [
          TextButton(
            onPressed: () {
              auth.acceptSessionExpired();
              setState(() => _expiryDialogShown = false);
              Navigator.of(ctx).pop();
            },
            child: const Text('重新配对'),
          ),
        ],
      ),
    );
  }
}
