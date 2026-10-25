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

/// 整秒 → `[mm:ss.00]` 时间戳（与 [_lrc] 同格式，供自定义行长的用例拼 LRC）。
String _stamp(int seconds) {
  final m = (seconds ~/ 60).toString().padLeft(2, '0');
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '[$m:$s.00]';
}

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

  Future<void> pumpLyrics(WidgetTester tester, PlayerProvider player,
      {double scale = 1.0}) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ],
      child: MaterialApp(
          home: Scaffold(body: LyricsView(player: player, scale: scale))),
    ));
    await tester.pump();
  }

  testWidgets('歌词 scale 同步放大字号', (tester) async {
    final pos = StreamController<Duration>();
    final player = playerWithLyrics(pos.stream);
    await pumpLyrics(tester, player, scale: 2);

    final text = tester.widget<Text>(find.text(_line(1)));
    expect(text.style?.fontSize, 32);

    await pos.close();
    player.dispose();
  });

  testWidgets('列表未挂载时位置事件不得访问 ScrollPosition', (tester) async {
    // 切到无歌词/纯文本/加载态时 ListView 会被移除，ScrollController 随之
    // detach。若此前位置事件已安排帧末跟焦，回调里先读 `_scroll.position`
    // 会抛 "ScrollController not attached to any scroll views"。
    final pos = StreamController<Duration>();
    final player = playerWithLyrics(pos.stream);
    await pumpLyrics(tester, player);

    pos.add(_posOf(5)); // 先安排一次帧末跟焦
    await tester.idle(); // 只投递流事件，不进入帧
    player.debugApplyLyrics(''); // 帧前切到空态，移除 ListView
    await tester.pump();

    expect(tester.takeException(), isNull);

    await pos.close();
    player.dispose();
  });

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

  testWidgets('位置事件比帧频还快时不得反复打断跟焦动画（真机 60+Hz 定时器回归）', (tester) async {
    final pos = StreamController<Duration>();
    final player = playerWithLyrics(pos.stream);
    await pumpLyrics(tester, player);

    // 先停在首屏内可达的行上并归位。
    pos.add(_posOf(8));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    _expectCentered(tester, 8);

    // 换行触发跟焦动画，并在动画期间每 16ms 继续发位置事件。
    //
    // 真机取证（2026-10-15 手机 Mate 90 Pro Max）：just_audio 的 positionStream
    // 是 `Timer.periodic(duration/800)`（clamp 到 [16ms, 200ms]）——时长未知 /
    // 短音频时按 16ms 跳，即 60+ 次/秒。旧实现每次事件都 animateTo，把进行中的
    // 动画打断成逐帧重开（每段动画的第一次 tick 位移为 0），滚动退化为「逐帧
    // 微移的爬行」，观感就是追焦卡顿（手指一碰即停——拖动会抑制跟焦）。
    // 本用例钉住：动画期间的高频位置事件不得把动画打断成爬行，必须在
    // 一段动画的合理时长内到位。
    pos.add(_posOf(9));
    await tester.pump();
    var converged = false;
    var frames = 0;
    for (; frames < 60; frames++) {
      await tester.pump(const Duration(milliseconds: 16)); // 一帧 + 一个 tick
      pos.add(_posOf(9) + Duration(milliseconds: 16 * (frames + 1)));
      if (_alignDelta(tester, 9).abs() < 8) {
        converged = true;
        break;
      }
    }
    expect(converged, isTrue, reason: '跟焦动画被高频位置事件反复打断：${frames * 16}ms 仍未到位');

    await pos.close();
    player.dispose();
  });

  testWidgets('换行后行高同帧定稿：跟焦一次落位，不出现收尾补移', (tester) async {
    final pos = StreamController<Duration>();
    final player = playerWithLyrics(pos.stream);
    await pumpLyrics(tester, player);

    pos.add(_posOf(10));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    _expectCentered(tester, 10);

    final scroll = scrollOf(tester);
    Rect rowOf(int line) => tester.getRect(find.ancestor(
          of: find.text(_line(line)),
          matching: find.byType(InkWell),
        ));

    // 换行：新当前行放大、上一行回缩。字号/字重若走 200ms 补间，行高会在这段时间
    // 里持续变化 → 跟焦目标漂移 → 落不到位、收尾再补一次（真机反馈的「补 4px」）。
    pos.add(_posOf(11));
    await tester.pump(); // 事件投递 + 重建
    await tester.pump(); // 换行后的第一帧
    final rowAtChange = rowOf(11).height;
    await tester.pump(const Duration(milliseconds: 200));
    expect(rowOf(11).height, rowAtChange,
        reason: '当前行行高在换行后 200ms 内仍在变（字号/字重参与了补间）——目标会漂');

    // 主动画结束后必须已经到位：再等一段（含二次校正窗口）不得出现补移。
    await tester.pump(const Duration(milliseconds: 360));
    final settled = scroll.offset;
    for (var i = 1; i <= 4; i++) {
      pos.add(_posOf(11) + Duration(milliseconds: 200 * i));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(scroll.offset, settled, reason: '主动画结束后又发生了收尾补移');
    }
    _expectCentered(tester, 11);

    await pos.close();
    player.dispose();
  });

  testWidgets('长行折行（行数随状态变化）时同样一次落位，不做二次校正', (tester) async {
    // 44 个汉字：16px 排 1 行（44×16=704 ≤ 752），19px 排 2 行（44×19=836 > 752）——
    // 即"激活即折行"，行高在换行帧从 42 跳到 75；译文再来一条 50 字（14px 1 行、
    // 16px 2 行）覆盖"翻译过长"分支。字号若走补间，折行会在 200ms 里跨越阈值突然
    // 发生，目标中途跳变 → 必然二次校正（真机反馈的那种"一直要补"）。
    // 夹具取 20 行、长行放中间：保证对齐位不落进 maxScrollExtent 夹取区。
    final long = '长' * 44;
    final longTrans = '译' * 50;
    final lrc = [
      for (var i = 1; i <= 20; i++)
        '${_stamp((i - 1) * 4)}'
            '${i == 10 ? '$long / $longTrans' : '第$i行'}',
    ].join('\n');
    final pos = StreamController<Duration>();
    final player = PlayerProvider()
      ..lyricsPositionOverride = pos.stream
      ..debugApplyLyrics(lrc);
    await pumpLyrics(tester, player);

    Rect rowOf(String text) => tester.getRect(find.ancestor(
          of: find.text(text),
          matching: find.byType(InkWell),
        ));

    pos.add(const Duration(seconds: 16)); // 第 5 行
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    // 换行到长行：主文本折行数 1 → 2、译文 1 → 2，行高必须在换行帧就定稿。
    pos.add(const Duration(seconds: 36));
    await tester.pump();
    await tester.pump();
    final atChange = rowOf(long).height;
    expect(atChange, greaterThan(110), reason: '长行（含长译文）激活后应按折行后的行高定稿');
    await tester.pump(const Duration(milliseconds: 200));
    expect(rowOf(long).height, atChange,
        reason: '折行后的行高在 200ms 内仍在变（折行随字号补间中途发生）');

    // 主动画结束后不得再出现二次校正，且当前行确实回到对齐位。
    await tester.pump(const Duration(milliseconds: 400));
    final scroll = scrollOf(tester);
    final settled = scroll.offset;
    for (var i = 1; i <= 3; i++) {
      pos.add(const Duration(seconds: 36) + Duration(milliseconds: 200 * i));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(scroll.offset, settled, reason: '折行场景出现了二次校正');
    }
    final view = tester.getRect(find.byType(LyricsView));
    final r = rowOf(long);
    expect(
        (r.top - view.top - (view.height - r.height) * 0.42).abs(), lessThan(8),
        reason: '折行后的长行未回到对齐位');

    await pos.close();
    player.dispose();
  });
}
