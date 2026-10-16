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
import 'package:selfmusic/theme/theme_provider.dart';
import 'package:selfmusic/widgets/app_toast.dart';
import 'package:selfmusic/widgets/draggable_sheet.dart';
import 'package:selfmusic/widgets/player_sheet_anim.dart';
import 'package:sqlite3/open.dart';

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

class _FakeSource extends MusicSource {
  @override
  String get key => 'webdav:q';
  @override
  String get name => 'q';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;
  @override
  DirectStream? directStream(Song song) =>
      const DirectStream('https://example.com/a.mp3');
}

Song _song(int i) => Song(
      id: 0,
      sourceKey: 'webdav:q',
      title: '队列歌曲 $i',
      source: 'webdav',
      sourceRef: 's$i.mp3',
      fileSize: 0,
    );

/// 窄屏队列窗口内的行三点菜单必须浮在窗口之上：窗口是根悬浮层
/// （AppSheetLauncher，非路由），弹出菜单是导航器路由——框架在每次导航历史
/// 变更时把非路由悬浮层排到路由条目之上（OverlayState.rearrange），
/// 旧实现（直接 OverlayEntry）会把菜单压到窗口下面，点不到也看不见。
void main() {
  testWidgets('队列窗口内三点菜单：弹层在窗口之上，可正常点选', (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_qmenu_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      player = PlayerProvider();
      player.loadOverride = (s, src) async {};
      await player.playQueue([for (var i = 1; i <= 8; i++) _song(i)],
          source: _FakeSource());
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: 60);
    addTearDown(tester.view.reset);

    final nav = NavigationProvider();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
          ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ChangeNotifierProvider<ThemeProvider>.value(
              value: ThemeProvider(autoLoad: false)),
        ],
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          home: _Host(nav: nav),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 打开队列窗口。
    await tester.tap(find.byTooltip('播放队列'));
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('app_sheet_surface'));
    expect(surface, findsOneWidget);

    // 行三点菜单：弹出后菜单项必须可点（未被窗口遮挡）。
    final more = find.descendant(of: surface, matching: find.byIcon(Icons.more_vert)).first;
    await tester.tap(more);
    await tester.pumpAndSettle();
    // 菜单项范围限定弹层（侧边栏导航里也有「喜欢」字样）。
    Finder menuItem(String label) => find.descendant(
        of: find.byType(PopupMenuItem<String>), matching: find.text(label));
    expect(menuItem('喜欢'), findsOneWidget);

    await tester.tap(menuItem('喜欢'));
    await tester.pumpAndSettle();
    // 点中菜单项：菜单收起、动作生效（已加入喜欢 toast）。
    expect(menuItem('不喜欢'), findsNothing);
    expect(find.text('已加入喜欢'), findsOneWidget);
    // 收藏落库经后台写隔离（真实跨 isolate 异步）：runAsync 跨出 FakeAsync
    // 等写回执，随后 pump 让续体（清 meta 读取缓存）在测试时钟内跑完。
    await tester.runAsync(() => direct.index.flushWrites());
    await tester.pump();
    expect(direct.weight.isFavorite(_song(1)), isTrue);
    // 走完 toast 停留计时（避免测试结束仍挂起 timer）。
    await tester.pump(const Duration(seconds: 3));
  });
}

class _Host extends StatefulWidget {
  const _Host({required this.nav});
  final NavigationProvider nav;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final PlayerSheetAnimator _playerAnim;
  late final AppSheetLauncher _launcher;

  @override
  void initState() {
    super.initState();
    _playerAnim = PlayerSheetAnimator(
        vsync: this, progress: widget.nav.playerProgress);
    _launcher = AppSheetLauncher(vsync: this);
  }

  @override
  void dispose() {
    _playerAnim.dispose();
    _launcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<PlayerSheetAnimator>.value(value: _playerAnim),
        Provider<AppSheetLauncher>.value(value: _launcher),
      ],
      child: const AppShell(content: SizedBox()),
    );
  }
}
