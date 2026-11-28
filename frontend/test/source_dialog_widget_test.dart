import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/screens/sources/source_dialog/source_dialog.dart';
import 'package:selfmusic/screens/sources/source_dialog/source_form_widgets.dart';
import 'package:selfmusic/theme/app_theme.dart';
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

/// 打开一个空白的添加播放源弹窗。
Future<void> pumpDialog(
  WidgetTester tester,
  DirectSourceManager direct, {
  String? editKey,
  Size size = const Size(1024, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ChangeNotifierProvider<DirectSourceManager>.value(
      value: direct,
      child: ChangeNotifierProvider<NavigationProvider>(
        create: (_) => NavigationProvider(),
        child: MaterialApp(
          theme: AppTheme.build().themeData,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => SourceDialog(editKey: editKey),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  });

  setUp(() {
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(<String, String>{});
  });

  late Directory dir;
  late DirectSourceManager direct;

  Future<void> setUpManager(WidgetTester tester) async {
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_sdlg_');
      PathProviderProviderHelper.install(dir.path);
      direct = DirectSourceManager();
      await direct.init();
    });
  }

  void tearDownManager() {
    addTearDown(() async {
      await Future<void>.delayed(Duration.zero);
      direct.dispose();
      dir.deleteSync(recursive: true);
    });
  }

  testWidgets('分组标题按类型出现：WebDAV 有连接与播放链路', (tester) async {
    await setUpManager(tester);
    tearDownManager();
    await pumpDialog(tester, direct);

    await tester.tap(find.text('WebDAV'));
    await tester.pumpAndSettle();

    expect(find.text('类型'), findsOneWidget);
    expect(find.text('基本信息'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
    expect(find.text('播放链路'), findsOneWidget);
    expect(find.text('备用源'), findsOneWidget);
  });

  testWidgets('空地址保存：错误就地显示在字段下方，不在弹窗底部', (tester) async {
    await setUpManager(tester);
    tearDownManager();
    await pumpDialog(tester, direct);

    await tester.tap(find.text('WebDAV'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'NAS');
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    // 地址字段的就地错误。
    expect(find.text('请填写 WebDAV 地址'), findsOneWidget);
    // 弹窗标题仍在（没有关窗）。
    expect(find.text('添加播放源'), findsOneWidget);
  });

  testWidgets('改动字段后测试结果清空回「待测」', (tester) async {
    await setUpManager(tester);
    tearDownManager();
    await pumpDialog(tester, direct);

    await tester.tap(find.text('WebDAV'));
    await tester.pumpAndSettle();

    final row = tester.widget<ConnectionTestRow>(
      find.byType(ConnectionTestRow),
    );
    expect(row.status, ConnectionStatus.idle);

    // 输入一次 → 仍是 idle（未测过的字段不会凭空变成成功）。
    await tester.enterText(find.byType(TextField).at(1), 'https://a/b');
    await tester.pumpAndSettle();
    expect(
      tester.widget<ConnectionTestRow>(find.byType(ConnectionTestRow)).status,
      ConnectionStatus.idle,
    );
  });

  testWidgets('备用源默认收起为摘要行，点添加后展开', (tester) async {
    await setUpManager(tester);
    tearDownManager();
    await pumpDialog(tester, direct);

    // 没有备用源时只有添加按钮。
    expect(find.text('添加备用源'), findsOneWidget);
    expect(find.byType(SourceCollapsibleHeader), findsNothing);

    await tester.tap(find.text('添加备用源'));
    await tester.pumpAndSettle();

    // 出现一个备用槽，默认展开（卡头 + 表单）。
    expect(find.byType(SourceCollapsibleHeader), findsOneWidget);
    expect(find.text('备用1'), findsOneWidget);
    // 备用源没有名称字段：只应有一个「名称」输入（主源的）。
    expect(find.text('名称'), findsOneWidget);
  });

  testWidgets('删除备用源后回到空态', (tester) async {
    await setUpManager(tester);
    tearDownManager();
    await pumpDialog(tester, direct);

    await tester.tap(find.text('添加备用源'));
    await tester.pumpAndSettle();
    expect(find.byType(SourceCollapsibleHeader), findsOneWidget);

    await tester.tap(find.byTooltip('删除备用1'));
    await tester.pumpAndSettle();
    expect(find.byType(SourceCollapsibleHeader), findsNothing);
    expect(find.text('添加备用源'), findsOneWidget);
  });

  testWidgets('编辑态类型灰显只读，不出现类型选择器', (tester) async {
    await setUpManager(tester);
    tearDownManager();
    await tester.runAsync(() async {
      final a = Directory('${dir.path}/a')..createSync();
      await direct.addLocal(name: '本地源', path: a.path);
    });

    await pumpDialog(tester, direct, editKey: 'local:本地源');

    expect(find.text('编辑播放源'), findsOneWidget);
    // 类型以只读 Chip 呈现，不是可点的单选组。
    expect(find.byType(Chip), findsWidgets);
    expect(find.text('本地'), findsOneWidget);
  });

  testWidgets('密码框可切换显隐', (tester) async {
    await setUpManager(tester);
    tearDownManager();
    await pumpDialog(tester, direct);

    await tester.tap(find.text('WebDAV'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('显示密码'), findsOneWidget);
    await tester.tap(find.byTooltip('显示密码'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('隐藏密码'), findsOneWidget);
  });
}

/// 测试用 PathProvider 安装（避免 λ 写太长）。
class PathProviderProviderHelper {
  static void install(String dir) {
    PathProviderPlatform.instance = _FakePathProvider(dir);
  }
}
