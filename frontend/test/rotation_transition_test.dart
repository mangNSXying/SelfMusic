import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/layout/app_shell.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/player_screen.dart';
import 'package:selfmusic/theme/theme_provider.dart';
import 'package:selfmusic/widgets/player_sheet_anim.dart';
import 'package:sqlite3/open.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

class _FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}
  @override
  Future<bool> get enabled async => false;
}

class _FakeSource extends MusicSource {
  @override
  String get key => 'webdav:rotate';
  @override
  String get name => 'rotate';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;
  @override
  DirectStream? directStream(Song song) =>
      const DirectStream('https://example.com/a.mp3');
}

Song _song() => Song(
      id: 0,
      sourceKey: 'webdav:rotate',
      title: '旋转测试曲目',
      source: 'webdav',
      sourceRef: 'a.mp3',
      fileSize: 0,
    );

Future<DirectSourceManager> _openDirect() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_rotate_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  return direct;
}

Future<PlayerProvider> _playerWithCurrent() async {
  final p = PlayerProvider();
  p.loadOverride = (s, src) async {};
  await p.playQueue([_song()], source: _FakeSource());
  return p;
}

int _probeInitCount = 0;

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _probeInitCount++;
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.transparent);
}

class _ShellHost extends StatefulWidget {
  final NavigationProvider nav;
  final DirectSourceManager direct;
  final PlayerProvider player;
  final Widget content;

  const _ShellHost({
    required this.nav,
    required this.direct,
    required this.player,
    required this.content,
  });

  @override
  State<_ShellHost> createState() => _ShellHostState();
}

class _ShellHostState extends State<_ShellHost> with TickerProviderStateMixin {
  late final PlayerSheetAnimator _sheetAnim;

  @override
  void initState() {
    super.initState();
    _sheetAnim = PlayerSheetAnimator(
      vsync: this,
      progress: widget.nav.playerProgress,
    );
  }

  @override
  void dispose() {
    _sheetAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<PlayerSheetAnimator>.value(value: _sheetAnim),
        ChangeNotifierProvider<DirectSourceManager>.value(value: widget.direct),
        ChangeNotifierProvider<NavigationProvider>.value(value: widget.nav),
        ChangeNotifierProvider<PlayerProvider>.value(value: widget.player),
        ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(autoLoad: false)),
      ],
      child: AppShell(content: widget.content),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final savedWakelock = WakelockPlusPlatformInterface.instance;
  setUp(() => WakelockPlusPlatformInterface.instance = _FakeWakelock());
  tearDown(() => WakelockPlusPlatformInterface.instance = savedWakelock);

  testWidgets('手机播放页横竖屏切换：过渡不抛异常并落到对应布局', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: MultiProvider(
          providers: [
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<NavigationProvider>(
                create: (_) => NavigationProvider()),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
            ChangeNotifierProvider<PlaylistsProvider>(
                create: (_) => PlaylistsProvider(direct.playlists)),
          ],
          child: const PlayerScreen(desktopPlatformOverride: false),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(LandscapePlayer), findsNothing);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    expect(find.byType(LandscapePlayer), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
    expect(find.byType(LandscapePlayer), findsOneWidget);

    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
    expect(find.byType(LandscapePlayer), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('AppShell 横竖屏切换不重挂载内容区', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      direct = await _openDirect();
      player = await _playerWithCurrent();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    _probeInitCount = 0;
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final nav = NavigationProvider();
    addTearDown(nav.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: _ShellHost(
          nav: nav,
          direct: direct,
          player: player,
          content: const _Probe(),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'initial portrait');
    expect(_probeInitCount, 1);

    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'rotate to landscape first frame');
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull,
        reason: 'rotate to landscape settled');
    expect(_probeInitCount, 1, reason: '旋转到横屏不应重挂载内容区');

    tester.view.physicalSize = const Size(400, 800);
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'rotate back portrait first frame');
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull,
        reason: 'rotate back portrait settled');
    expect(_probeInitCount, 1, reason: '旋转回竖屏不应重挂载内容区');

    await tester.pumpWidget(const SizedBox());
  });
}
