import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/widgets/lyrics_view.dart';
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

/// 每 4 秒一行、共 [n] 行的歌词文本（第 i+1 行时间 = i*4s）。
String _lrc(int n) => List.generate(n, (i) {
      final ms = i * 4000;
      final m = (ms ~/ 60000).toString().padLeft(2, '0');
      final sec = ((ms % 60000) ~/ 1000).toString().padLeft(2, '0');
      final cs = ((ms % 1000) ~/ 10).toString().padLeft(2, '0');
      return '[$m:$sec.$cs]第${i + 1}行';
    }).join('\n');

/// 第 [n] 行文本（n 从 1 起）。
String _line(int n) => '第$n行';

/// 行号 → 播放位置：第 n 行在 (n-1)*4s 处。
Duration _posOf(int line) => Duration(seconds: (line - 1) * 4);

/// 目标行行顶相对对齐位的偏差（px）。
///
/// [LyricsView] 用 `alignment: 0.42` 回中，对齐的是**行顶**（不是行中），
/// 其基准为 `0.42 ×（视口高 − 行高）`，与列表上下留白 `0.42 × 视口高` 差一个行高比例。
double _alignDelta(WidgetTester tester, int line) {
  final row = find.ancestor(
    of: find.text(_line(line)),
    matching: find.byType(InkWell),
  );
  expect(row, findsOneWidget, reason: '第 $line 行未构建');
  final view = tester.getRect(find.byType(LyricsView));
  final r = tester.getRect(row);
  return r.top - view.top - (view.height - r.height) * 0.42;
}

void _expectCentered(WidgetTester tester, int line, {double tol = 8}) {
  expect(_alignDelta(tester, line).abs(), lessThan(tol),
      reason: '第 $line 行未回到对齐位');
}

void main() {
  late Directory dir;
  late DirectSourceManager direct;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_lyrics_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    direct = DirectSourceManager();
    await direct.init();
  });

  tearDown(() {
    direct.dispose();
    dir.deleteSync(recursive: true);
  });

  /// 注入 n 行歌词 + 可控位置流，返回播放器。
  PlayerProvider playerWithLyrics(Stream<Duration> pos, {int lines = 60}) =>
      PlayerProvider()
        ..lyricsPositionOverride = pos
        ..debugApplyLyrics(_lrc(lines));

  ScrollController scrollOf(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!;

  Future<void> pumpLyrics(WidgetTester tester, PlayerProvider player) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ],
      child: MaterialApp(home: Scaffold(body: LyricsView(player: player))),
    ));
    await tester.pump();
  }

  testWidgets('目标行在首屏外：首次跟焦即回中（改进.txt 卡死回归）', (tester) async {
    final pos = StreamController<Duration>();
    final player = playerWithLyrics(pos.stream);
    await pumpLyrics(tester, player);

    // 播放位置落在第 46 行：远在首屏之外，ListView 懒构建时尚未构建出来。
    pos.add(_posOf(46));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    _expectCentered(tester, 46);
    // 列表确实滚离歌词开头（第 1 行早已滑出构建范围）。
    expect(scrollOf(tester).offset, greaterThan(0));

    await pos.close();
    player.dispose();
  });

  testWidgets('行号不变时重复事件也复核位置，但已在位就不重滚', (tester) async {
    final pos = StreamController<Duration>();
    final player = playerWithLyrics(pos.stream);
    await pumpLyrics(tester, player);

    pos.add(_posOf(30));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    _expectCentered(tester, 30);

    // 同一行再发两次：已在位就不应再动（否则会变成逐帧微移的「爬行」）
    final settled = tester.getRect(find.text(_line(30)));
    for (var i = 1; i <= 2; i++) {
      pos.add(_posOf(30) + Duration(milliseconds: 20 * i));
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(find.text(_line(30))), settled,
          reason: '已在位却被重新滚动');
    }
    _expectCentered(tester, 30);

    await pos.close();
    player.dispose();
  });

  testWidgets('拖动期间不回中，空闲超时后自动回中', (tester) async {
    final pos = StreamController<Duration>();
    final player = playerWithLyrics(pos.stream);
    await pumpLyrics(tester, player);

    pos.add(_posOf(30));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    _expectCentered(tester, 30);

    // 手指按住往下拖（露出后面的歌词），此时不能跟焦抢滚动。
    final g =
        await tester.startGesture(tester.getCenter(find.byType(LyricsView)));
    await g.moveBy(const Offset(0, -30)); // 越过 touch slop
    await tester.pump();
    await g.moveBy(const Offset(0, -90));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(_alignDelta(tester, 30).abs(), greaterThan(10),
        reason: '手指未抬起就把歌词拉回中位了');

    // 松手后按「歌词追焦等待」（默认 5s）超时恢复跟焦。
    await g.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    _expectCentered(tester, 30);

    await pos.close();
    player.dispose();
  });
}
