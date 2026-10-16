import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

/// 置入非空播放队列：不触真实装载（loadOverride），只为让迷你播放条渲染
/// 右侧队列入口（统一拖拽式窗口的点按/滑动两种启动都从这里进入）。
/// [playIndex] > 0 时把当前曲定位到该下标（复现「打开即定位、列表滚离顶部」）。
Future<PlayerProvider> _playerWithQueue({int count = 3, int playIndex = 0}) async {
  final p = PlayerProvider();
  p.loadOverride = (s, src) async {};
  await p.playQueue([for (var i = 1; i <= count; i++) _song(i)],
      source: _FakeSource());
  if (playIndex > 0) await p.playAt(playIndex);
  return p;
}

/// 装配窄屏队列窗口宿主（照生产 main.dart 的 Provider 层级）。
Future<
    ({
      NavigationProvider nav,
      PlayerProvider player,
      AppSheetLauncher Function() launcher,
      Finder entry,
      Finder Function() surface,
    })> _pumpHost(WidgetTester tester, {int count = 3, int playIndex = 0}) async {
  late final DirectSourceManager direct;
  late final PlayerProvider player;
  await tester.runAsync(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_queue_sheet_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.init();
    player = await _playerWithQueue(count: count, playIndex: playIndex);
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
  final hostKey = GlobalKey<_HostState>();
  await tester.pumpWidget(
    _Providers(
      nav: nav,
      direct: direct,
      player: player,
      child: MaterialApp(home: _Host(key: hostKey)),
    ),
  );
  await tester.pumpAndSettle();
  return (
    nav: nav,
    player: player,
    launcher: () => hostKey.currentState!.launcher,
    entry: find.byTooltip('播放队列'),
    surface: () => find.byKey(const ValueKey('app_sheet_surface')),
  );
}

/// 窄屏队列统一拖拽式窗口回归：
/// - 点按入口 → 标准滑入打开；标题紧贴窗口顶部（无状态栏空白，历史 bug）；
/// - 入口上滑 → 跟手逐帧拉起（未松手窗口已随指升起），松手吸附打开；
/// - 小幅上滑松手 → 取消关闭；头部下拖 → 窗口缩小（多档拖拽）；
/// - 关闭按钮 / 遮罩点按 → 关闭，开合镜像回写 nav.queueOpen。
void main() {
  testWidgets('队列窗口：点按开/无顶部空白/上滑跟手/取消/拖拽/关闭', (tester) async {
    final h = await _pumpHost(tester);
    final nav = h.nav;

    // 初始：窗口关闭，入口在迷你条右侧。
    expect(find.text('播放队列'), findsNothing);
    final entry = h.entry;
    expect(entry, findsOneWidget);
    AppSheetLauncher launcher() => h.launcher();
    Finder sheet() => find.byType(DraggableScrollableSheet);
    // 可见窗口面（悬浮层 Material）：位置断言以它为准（DraggableScrollableSheet
    // 本体铺满可用区，顶边恒在状态栏下方，量它测不出窗口实际高度）。
    Finder surface() => find.byKey(const ValueKey('app_sheet_surface'));

    // ── 点按入口 → 标准滑入打开 ──
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(nav.queueOpen, isTrue);
    expect(find.text('播放队列'), findsOneWidget);
    expect(sheet(), findsOneWidget);

    // ── 无顶部空白：标题紧贴窗口顶部 ──
    final sheetTop = tester.getTopLeft(surface()).dy;
    final titleTop = tester.getTopLeft(find.text('播放队列')).dy;
    expect(titleTop, greaterThanOrEqualTo(60.0), reason: '窗口内容不得盖住状态栏');
    expect(titleTop - sheetTop, lessThan(60.0),
        reason: '标题紧贴窗口顶部：窗口已让开顶部安全区，内容不得再垫一块状态栏空白');

    // ── 头部下拖 → 窗口缩小（多档拖拽） ──
    final handle = find.byKey(const ValueKey('app_sheet_handle'));
    expect(handle, findsOneWidget);
    final before = tester.getTopLeft(surface()).dy;
    await tester.drag(handle, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(surface()).dy, greaterThan(before + 100),
        reason: '头部下拖应缩小窗口（多档拖拽）');

    // ── 关闭按钮 → 关闭 ──
    await tester.tap(
        find.descendant(of: surface(), matching: find.byIcon(Icons.close)));
    await tester.pumpAndSettle();
    expect(nav.queueOpen, isFalse);
    expect(find.text('播放队列'), findsNothing);

    // ── 上滑跟手：拖到中途（未松手）窗口已随指升起 ──
    // 分步 move（单次大跨度 move 会被 drag 手势的 touch slop 吞掉，只触发 start
    // 不触发 update，见 DragGestureRecognizer 行为）。
    final g = await tester.startGesture(tester.getCenter(entry));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, -95));
      await tester.pump();
    }
    expect(launcher().swipeValue, greaterThan(0.0),
        reason: '跟手：拖动途中展示进度已离开 0（窗口随指升起）');
    expect(sheet(), findsOneWidget, reason: '跟手：未松手窗口已推入');
    expect(nav.queueOpen, isTrue, reason: '滑动启动即镜像开合态');
    await g.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(nav.queueOpen, isTrue, reason: '上滑过量松手 → 定稿打开');
    expect(find.text('播放队列'), findsOneWidget);

    // ── 点按遮罩（窗口上方）→ 关闭 ──
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(nav.queueOpen, isFalse);
    expect(find.text('播放队列'), findsNothing);

    // ── 小幅上滑松手 → 取消关闭 ──
    final g2 = await tester.startGesture(tester.getCenter(entry));
    await g2.moveBy(const Offset(0, -20));
    await tester.pump();
    await g2.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(sheet(), findsOneWidget, reason: '小幅拖动同样推入窗口（进度接近 0）');
    await g2.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(nav.queueOpen, isFalse, reason: '未过阈值松手 → 倒播关闭');
    expect(find.text('播放队列'), findsNothing);
  });

  testWidgets('队列窗口：滚动列表后标题栏仍置顶（sticky header）', (tester) async {
    // 队列足够长以撑出可滚动区（3 首不足）。
    final h = await _pumpHost(tester, count: 30);
    final surface = h.surface();

    await tester.tap(h.entry);
    await tester.pumpAndSettle();
    expect(find.text('播放队列'), findsOneWidget);

    // 在列表上上滑，滚过标题栏原本所在的位置。
    // 当前歌曲标题在迷你条也会出现，故用窗口内限定查找。
    Finder inSheet(String t) =>
        find.descendant(of: surface, matching: find.text(t));
    final pos = tester
        .state<ScrollableState>(
            find.descendant(of: surface, matching: find.byType(Scrollable)))
        .position;
    expect(pos.pixels, 0);
    // 第一次上滑先把窗口撑到最大，第二次才真正滚动列表。
    await tester.drag(inSheet('队列歌曲 3'), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.drag(inSheet('队列歌曲 5'), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(pos.pixels, greaterThan(0), reason: '列表确已滚动');

    // 标题仍在窗口顶部（滚动后未被推走）。
    expect(find.text('播放队列'), findsOneWidget);
    final sheetTop = tester.getTopLeft(surface).dy;
    final titleTop = tester.getTopLeft(find.text('播放队列')).dy;
    expect(titleTop - sheetTop, lessThan(60.0), reason: '滚动后标题栏仍紧贴窗口顶部（置顶）');
    // 首行已被滚走（确认真发生了滚动，而非没动）。
    expect(inSheet('队列歌曲 1'), findsNothing);
  });

  testWidgets('队列窗口：列表滚离顶部后，拖标题栏/把手仍能升降窗口（回归）', (tester) async {
    // 打开即定位当前曲（当前曲不在首行）→ 列表滚离顶部。旧行为：框架只在
    // 列表处于顶部时才把拖拽用于改窗口高度，否则一律滚列表——拖标题栏/把手
    // 纹丝不动，且高速上抛只会把窗口顶到全高、降不下来（用户反馈）。
    final h = await _pumpHost(tester, count: 30, playIndex: 8);
    final surface = h.surface();

    await tester.tap(h.entry);
    await tester.pumpAndSettle();

    final pos = tester
        .state<ScrollableState>(
            find.descendant(of: surface, matching: find.byType(Scrollable)))
        .position;
    final initialPixels = pos.pixels;
    expect(initialPixels, greaterThan(0), reason: '打开定位当前曲：列表应滚离顶部');

    // ── 头部下拖 → 窗口收起（列表不动） ──
    final before = tester.getTopLeft(surface).dy;
    await tester.drag(
        find.byKey(const ValueKey('app_sheet_handle')), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(surface).dy, greaterThan(before + 100),
        reason: '列表不在顶部时，拖标题栏/把手仍应降下窗口');
    expect(pos.pixels, closeTo(initialPixels, 0.01), reason: '拖头部不应滚动列表');

    // ── 头部上拖 → 窗口升起（列表仍不动） ──
    final mid = tester.getTopLeft(surface).dy;
    await tester.drag(
        find.byKey(const ValueKey('app_sheet_handle')), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(surface).dy, lessThan(mid - 100),
        reason: '拖标题栏/把手应升起窗口');
    expect(pos.pixels, closeTo(initialPixels, 0.01), reason: '拖头部不应滚动列表');

    // ── 鼠标拖动同样生效（桌面端：框架默认不让鼠标拖滚动区，头部手势不受限） ──
    final beforeMouse = tester.getTopLeft(surface).dy;
    await tester.drag(find.byKey(const ValueKey('app_sheet_handle')),
        const Offset(0, 200),
        kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(surface).dy, greaterThan(beforeMouse + 100),
        reason: '鼠标拖标题栏/把手也应升降窗口');

    // ── 拖到极限：钳在 min/max，不越界（jumpTo 断言尺寸 ∈ [0,1]） ──
    await tester.drag(
        find.byKey(const ValueKey('app_sheet_handle')), const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final atMin = tester.getTopLeft(surface).dy;
    await tester.drag(
        find.byKey(const ValueKey('app_sheet_handle')), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(surface).dy, lessThan(atMin - 100),
        reason: '拉到上限后仍可反向拖动（钳制不卡死）');
  });
}

/// 照 main.dart Root 的装配：AppSheetLauncher 需要 TickerProvider，
/// 由宿主 State 提供；窄屏 AppShell 自带迷你条入口。
class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final PlayerSheetAnimator _playerAnim;
  late final AppSheetLauncher _launcher;

  AppSheetLauncher get launcher => _launcher;

  @override
  void initState() {
    super.initState();
    _playerAnim = PlayerSheetAnimator(
        vsync: this,
        progress: context.read<NavigationProvider>().playerProgress);
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

/// 测试装配：全部 Provider 放在 MaterialApp 之上（照生产 main.dart）。
class _Providers extends StatelessWidget {
  const _Providers({
    required this.nav,
    required this.direct,
    required this.player,
    required this.child,
  });

  final NavigationProvider nav;
  final DirectSourceManager direct;
  final PlayerProvider player;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        // 窄屏首帧迷你条 / 队列窗口需要主题色。
        ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(autoLoad: false)),
      ],
      child: child,
    );
  }
}
