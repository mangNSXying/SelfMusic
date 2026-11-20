import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/theme/app_metrics.dart';
import 'package:selfmusic/widgets/song_info_dialog.dart';
import 'package:sqlite3/open.dart';

/// 歌曲信息弹窗布局回归：
/// - 四栏齐全（基本信息 / 音频信息 / 播放统计 / 来源），封面置顶居中；
/// - 基本信息字段块按内容宽度 Wrap 排列，长值完整显示、不省略号截断；
/// - 点击字段块就地变输入框，回车/点别处收起；未改动只有「关闭」，
///   改动后出现「保存」。

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

Widget _host(DirectSourceManager direct, Song song) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(body: SongInfoDialog(song: song)),
      ),
    );

/// 以路由方式打开弹窗：关闭保护用例需要 `Navigator.pop` 只关弹窗不关首页。
Widget _dialogHost(DirectSourceManager direct, Song song) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<PlayerProvider>(create: (_) => PlayerProvider()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (c) => Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: c,
                  builder: (_) => SongInfoDialog(song: song),
                ),
                child: const Text('打开歌曲信息'),
              ),
            ),
          ),
        ),
      ),
    );

Future<void> _openDialog(WidgetTester tester, DirectSourceManager direct,
    Song song) async {
  await tester.pumpWidget(_dialogHost(direct, song));
  await tester.tap(find.text('打开歌曲信息'));
  await tester.pumpAndSettle();
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

    await tester.pumpWidget(_host(direct, _song()));
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

    // 未改动：只有「关闭」，没有「保存」。
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('保存'), findsNothing);

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

    await tester.pumpWidget(_host(direct, _song(title: _longTitle)));
    await tester.pumpAndSettle();

    final title = _valueTextOf(tester, _longTitle);
    expect(title.maxLines, isNull, reason: '长标题不应限制行数');
    expect(title.overflow, isNot(TextOverflow.ellipsis));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('点击字段就地编辑：出现输入框，回车收起', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    addTearDown(direct.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(direct, _song()));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing, reason: '查看态无输入框');

    await tester.tap(find.text('千里之外'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget, reason: '点击后就地变输入框');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '千里之外');

    // 回车收起回到查看态。
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('编辑框为圆角矩形描边，失焦后复原为查看态', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    addTearDown(direct.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(direct, _song()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('千里之外'));
    await tester.pumpAndSettle();

    final decoration =
        tester.widget<TextField>(find.byType(TextField)).decoration!;
    for (final border in [decoration.border, decoration.enabledBorder]) {
      expect(border, isA<OutlineInputBorder>(), reason: '圆角矩形描边，不是下划线');
      expect(
        (border! as OutlineInputBorder).borderRadius,
        BorderRadius.circular(kButtonRadius),
        reason: '与全 App 输入框同一圆角',
      );
    }
    expect(decoration.filled, isFalse, reason: '字段区保持平面，不铺底色');

    // 键盘 Tab 等路径失焦 → 不做额外处理也要复原成查看态。
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: '失焦后收起输入框');
    expect(find.text('千里之外'), findsOneWidget, reason: '值原样回到查看态');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('改动后出现可点保存；清空标题则保存禁用', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    addTearDown(direct.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_host(direct, _song()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('千里之外'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新标题');
    await tester.pumpAndSettle();

    expect(find.text('歌曲信息 •未保存'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    var save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));
    expect(save.onPressed, isNotNull, reason: '有改动且标题非空 → 可保存');

    // 清空标题 → 保存禁用。
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
      reason: '标题已清空',
    );
    save = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));
    expect(save.onPressed, isNull, reason: '标题必填');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('有未保存修改时点取消 → 二次确认放弃', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    addTearDown(direct.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _openDialog(tester, direct, _song());

    await tester.tap(find.text('千里之外'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新标题');
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);

    // 继续编辑：确认框消失，主窗仍在，改动保留。
    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsNothing);
    expect(find.text('歌曲信息 •未保存'), findsOneWidget);
    expect(find.text('新标题'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('未改动时点关闭：直接关，不弹二次确认', (tester) async {
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      direct = await _openDirect();
    });
    addTearDown(direct.dispose);
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _openDialog(tester, direct, _song());

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(SongInfoDialog), findsNothing);
    expect(find.text('放弃未保存的修改？'), findsNothing);
    expect(find.text('打开歌曲信息'), findsOneWidget, reason: '只关弹窗，首页仍在');
  });
}
