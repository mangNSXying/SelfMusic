import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/widgets/song_info_dialog.dart';
import 'package:sqlite3/open.dart';

/// 歌曲信息弹窗布局回归：
/// - 四栏齐全（基本信息 / 音频信息 / 播放统计 / 来源），封面置顶居中；
/// - 基本信息字段块按内容宽度 Wrap 排列，长值完整显示、不省略号截断；
/// - 点击字段块浮现底部强调色下划线（tab 选中态），再次点击取消。

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

const _longTitle =
    'Symphony No. 9 in D minor, Op. 125 Choral — IV. Presto: Allegro assai';

Song _song({String title = '千里之外'}) => Song.direct(
      id: 1,
      sourceKey: 'local:info',
      title: title,
      artist: '周杰伦、费玉清',
      albumName: '依然范特西',
      albumArtist: '周杰伦',
      genre: '流行',
      year: 2006,
      duration: 254,
      source: 'local',
      sourceRef: '/music/a.flac',
      fileSize: 29779558,
      format: 'flac',
    );

Future<DirectSourceManager> _openDirect() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_info_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final direct = DirectSourceManager();
  await direct.init();
  return direct;
}

/// 某个字段块的「值」文本组件（按可见文字定位其祖先 Text）。
Text _valueTextOf(WidgetTester tester, String value) {
  final finder = find.text(value);
  expect(finder, findsWidgets, reason: '应完整显示：$value');
  return tester.widget<Text>(finder.first);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('歌曲信息：四栏齐全，封面置顶居中', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    addTearDown(direct.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<DirectSourceManager>.value(
        value: direct,
        child: MaterialApp(
          home: Scaffold(body: SongInfoDialog(song: _song())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('音频信息'), findsOneWidget);
    expect(find.text('播放统计'), findsOneWidget);
    expect(find.text('来源'), findsOneWidget);

    // 标题/歌手/专辑进基本信息，不再出现在头部。
    expect(find.text('千里之外'), findsOneWidget);
    expect(find.text('周杰伦、费玉清'), findsOneWidget);
    expect(find.text('依然范特西'), findsOneWidget);

    // 音频信息独立成栏。
    expect(find.text('时长'), findsOneWidget);
    expect(find.text('格式'), findsOneWidget);
    expect(find.text('FLAC'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('基本信息长值完整显示：不截断、不省略号', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    addTearDown(direct.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<DirectSourceManager>.value(
        value: direct,
        child: MaterialApp(
          home: Scaffold(body: SongInfoDialog(song: _song(title: _longTitle))),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = _valueTextOf(tester, _longTitle);
    expect(title.maxLines, isNull, reason: '长标题不应限制行数');
    expect(title.overflow, isNot(TextOverflow.ellipsis));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点击字段块出现下划线，再次点击取消', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    addTearDown(direct.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<DirectSourceManager>.value(
        value: direct,
        child: MaterialApp(
          home: Scaffold(body: SongInfoDialog(song: _song())),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double barOpacity() {
      final opacities = tester
          .widgetList<AnimatedOpacity>(find.byType(AnimatedOpacity))
          .map((w) => w.opacity)
          .toList();
      return opacities.isEmpty
          ? 0
          : opacities.reduce((a, b) => a > b ? a : b);
    }

    expect(barOpacity(), 0, reason: '初始无选中下划线');

    await tester.tap(find.text('千里之外'));
    await tester.pumpAndSettle();
    expect(barOpacity(), 1, reason: '点击后下划线浮现');

    await tester.tap(find.text('千里之外'));
    await tester.pumpAndSettle();
    expect(barOpacity(), 0, reason: '再次点击取消选中');

    await tester.pumpWidget(const SizedBox());
  });
}
