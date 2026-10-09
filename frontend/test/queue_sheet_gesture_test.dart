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

/// 置入非空播放队列：不触真实装载（loadOverride），只为让迷你播放条渲染
/// 右侧队列入口（旧实现在 `showModalBottomSheet` 固定动画，本次回归改悬浮跟手层）。
Future<PlayerProvider> _playerWithQueue() async {
  final p = PlayerProvider();
  p.loadOverride = (s, src) async {};
  await p.playQueue([_song(1), _song(2), _song(3)], source: _FakeSource());
  return p;
}

/// 窄屏队列弹层回归：
/// 迷你播放条右端队列入口上滑必须**跟手**——未松手面板已随指升起（不再是
/// 松手后才开始固定时长动画）；松手越过阈值定稿打开；把手向下快甩 / 点遮罩
/// 关闭；入口点按开合。
///
/// 复刻 main.dart Root 的装配：两个悬浮层动画器由宿主 State 提供，
/// 队列弹层为 Root Stack 中位于 AppShell 之上的 [QueueSheetLayer]。
void main() {
  testWidgets('队列弹层：上滑跟手升起、松手吸附打开、把手下甩/遮罩关闭',
      (tester) async {
    late final DirectSourceManager direct;
    late final PlayerProvider player;
    await tester.runAsync(() async {
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_queue_sheet_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
      player = await _playerWithQueue();
    });
    addTearDown(() {
      player.dispose();
      direct.dispose();
    });
    // 竖屏窄屏（手机）：宽度 < 900 且宽 <= 高。
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final nav = NavigationProvider();
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(nav: nav, direct: direct, player: player),
      ),
    );
    await tester.pumpAndSettle();

    // 初始：弹层隐藏，入口在迷你条右侧。
    expect(find.text('播放队列'), findsNothing);
    final entry = find.byTooltip('播放队列');
    expect(entry, findsOneWidget);

    // ── 上滑跟手：拖到中途（未松手）面板即已升起 ──
    // 分步 move（单次大跨度 move 会被 drag 手势的 touch slop 吞掉，只触发 start
    // 不触发 update，见 DragGestureRecognizer 行为）。
    final g = await tester.startGesture(tester.getCenter(entry));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, -95));
      await tester.pump();
    }
    expect(nav.queueProgress.value, lessThan(1.0),
        reason: '跟手：拖动途中进度已离开 1（面板随指升起）');
    expect(find.byType(QueuePanel), findsOneWidget,
        reason: '跟手：未松手面板已随指升起');
    expect(nav.queueOpen, isFalse, reason: '跟手拖动期间仍是过渡态，未定稿');
    await g.up();
    await tester.pumpAndSettle();
    expect(nav.queueOpen, isTrue, reason: '上滑过半松手 → 定稿打开');
    expect(find.text('播放队列'), findsOneWidget);

    // ── 把手向下快甩 → 关闭 ──
    final handle = find.byKey(const ValueKey('queue_sheet_handle'));
    expect(handle, findsOneWidget);
    await tester.fling(handle, const Offset(0, 260), 1100);
    await tester.pumpAndSettle();
    expect(nav.queueOpen, isFalse);
    expect(find.text('播放队列'), findsNothing);

    // ── 入口点按 → 打开 ──
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(nav.queueOpen, isTrue);
    expect(find.text('播放队列'), findsOneWidget);

    // ── 点按遮罩（面板上方）→ 关闭 ──
    await tester.tapAt(const Offset(200, 100));
    await tester.pumpAndSettle();
    expect(nav.queueOpen, isFalse);
    expect(find.text('播放队列'), findsNothing);
  });
}

/// 照 main.dart Root 的装配：两个 SheetAnimator 需要 TickerProvider，
/// 由宿主 State 提供；窄屏 AppShell 不建侧边栏。
class _Host extends StatefulWidget {
  const _Host({
    required this.nav,
    required this.direct,
    required this.player,
  });
  final NavigationProvider nav;
  final DirectSourceManager direct;
  final PlayerProvider player;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final PlayerSheetAnimator _playerAnim;
  late final QueueSheetAnimator _queueAnim;

  @override
  void initState() {
    super.initState();
    _playerAnim =
        PlayerSheetAnimator(vsync: this, progress: widget.nav.playerProgress);
    _queueAnim =
        QueueSheetAnimator(vsync: this, progress: widget.nav.queueProgress);
    // 镜像 main.dart Root._syncQueueSheet：意图位变化 → 吸附动画（定稿态语义）。
    widget.nav.addListener(_syncQueueSheet);
  }

  void _syncQueueSheet() {
    if (widget.nav.queueOpen && _queueAnim.value > 0.001) {
      _queueAnim.settle(0);
    } else if (!widget.nav.queueOpen && _queueAnim.value < 0.999) {
      _queueAnim.settle(1);
    }
  }

  @override
  void dispose() {
    widget.nav.removeListener(_syncQueueSheet);
    _playerAnim.dispose();
    _queueAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<PlayerSheetAnimator>.value(value: _playerAnim),
        Provider<QueueSheetAnimator>.value(value: _queueAnim),
        ChangeNotifierProvider<DirectSourceManager>.value(value: widget.direct),
        ChangeNotifierProvider<NavigationProvider>.value(value: widget.nav),
        ChangeNotifierProvider<PlayerProvider>.value(value: widget.player),
        // 窄屏首帧迷你条 / 队列面板需要主题色。
        ChangeNotifierProvider<ThemeProvider>.value(
            value: ThemeProvider(autoLoad: false)),
      ],
      child: const Stack(
          children: [
            AppShell(content: SizedBox()),
            QueueSheetLayer(),
          ],
        ),
    );
  }
}