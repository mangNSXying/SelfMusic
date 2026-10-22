import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/screens/sources_screen.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/single_choice_group.dart';
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

void main() {
  setUpAll(() {
    if (!Platform.isLinux) return;
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  });

  testWidgets('窄屏添加播放源：类型选项换行且无横向滚动', (tester) async {
    late final Directory dir;
    late final DirectSourceManager direct;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_src_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      direct = DirectSourceManager();
      await direct.init();
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        direct.dispose();
        dir.deleteSync(recursive: true);
      });
    });

    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<DirectSourceManager>.value(
        value: direct,
        child: MaterialApp(
          theme: AppTheme.build().themeData,
          home: const Scaffold(body: SourcesScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加播放源'));
    await tester.pumpAndSettle();

    expect(find.text('添加播放源'), findsOneWidget);
    expect(find.byType(SingleChoiceGroup<SourceKind>), findsOneWidget);
    expect(find.byType(SegmentedButton<SourceKind>), findsNothing);
    // 默认 WebDAV：必须有「测试连接」按钮。
    expect(find.text('测试连接'), findsOneWidget);

    final horizontalScrolls = tester
        .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
        .where((s) => s.scrollDirection == Axis.horizontal);
    expect(horizontalScrolls, isEmpty);

    expect(
      tester.getTopLeft(find.text('本地')).dy,
      moreOrLessEquals(tester.getTopLeft(find.text('SMB')).dy, epsilon: 0.5),
    );
    expect(
      tester.getTopLeft(find.text('WebDAV')).dy,
      greaterThan(tester.getTopLeft(find.text('SMB')).dy),
    );
    expect(
      tester.getTopLeft(find.text('SFTP')).dy,
      greaterThan(tester.getTopLeft(find.text('WebDAV')).dy),
    );
    final groupRect =
        tester.getRect(find.byType(SingleChoiceGroup<SourceKind>));
    for (final label in ['本地', 'SMB', 'WebDAV', 'SFTP']) {
      expect(
        tester.getRect(find.text(label)).right,
        lessThanOrEqualTo(groupRect.right),
      );
    }
  });
}
