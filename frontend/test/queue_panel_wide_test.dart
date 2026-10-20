import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/layout/app_shell.dart';
import 'package:selfmusic/layout/queue_panel.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/theme/theme_provider.dart';
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

/// 宽屏右侧队列面板回归（2026-09-30 平板真机：打开即空白/渲染错乱）。
///
/// 根因：AppShell 宽屏分支把 QueuePanel 以 width=null 塞进 Row——Row 的
/// 非 flex 子项拿到**无界宽度**，面板头部 Row 里的 Spacer(flex) 抛
/// "non-zero flex but incoming width constraints are unbounded"，
/// 整棵子树布局失败 → 面板空白。窄屏走 ModalBottomSheet（有界约束）不受
/// 影响，所以手机/窄窗口一直正常，恒宽屏的平板必炸。
///
/// 回归口径：宽屏打开面板后布局零异常，面板可见且宽度为 kQueuePanelWidth。
void main() {
  testWidgets('宽屏队列面板：打开后正常渲染（无 unbounded 布局异常）',
      (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_queue_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      // 非空队列：验证计数栏显示真实长度（不触真实装载）。
      player = PlayerProvider();
      player.loadOverride = (s, src) async {};
      await player.playQueue(
          [for (var i = 1; i <= 3; i++) _song(i)],
          source: _FakeSource());
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    // 宽屏形态：width > 900 门槛之上（与平板横竖屏一致走右侧面板分支）。
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    // 模拟状态栏：面板顶部内容必须让开（顶栏由内容列的 SafeArea 消费，
    // 面板与内容列并排整高，需自行 SafeArea）。
    tester.view.padding = const FakeViewPadding(top: 60, bottom: 0);
    addTearDown(tester.view.reset);

    final nav = NavigationProvider();
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(nav: nav, direct: direct, player: player),
      ),
    );

    nav.toggleQueue(); // 宽屏：右侧面板分支（与迷你栏队列按钮同路径）
    await tester.pump();
    await tester.pump();

    // 修复前：unbounded flex 布局异常 → 面板整棵子树布局失败（空白）。
    expect(tester.takeException(), isNull);
    expect(find.byType(QueuePanel), findsOneWidget);
    expect(find.text('播放队列'), findsOneWidget);
    // 计数栏：与窄屏窗口一致，显示队列真实长度。
    expect(find.text('共 3 首歌曲'), findsOneWidget);
    expect(tester.getSize(find.byType(QueuePanel)).width, kQueuePanelWidth);
    // 面板顶部内容必须让开状态栏（2026-09-30 真机：顶部留白不足）。
    expect(tester.getTopLeft(find.text('播放队列')).dy, greaterThanOrEqualTo(60));
  });
}

/// 照 main.dart Root 的装配：PlayerSheetAnimator 需要 TickerProvider，
/// 由宿主 State 提供；宽屏下 Sidebar/迷你栏都会在首帧构建。
class _Host extends StatefulWidget {
  const _Host({required this.nav, required this.direct, required this.player});
  final NavigationProvider nav;
  final DirectSourceManager direct;
  final PlayerProvider player;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
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
        // 宽屏首帧即构建 Sidebar（_sidebarVisible 初始 true），需要主题。
        // autoLoad=false 绕开 secure storage。
        ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(autoLoad: false)),
      ],
      child: AppShell(content: const SizedBox()),
    );
  }
}
