import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/playlist_store.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
import 'package:selfmusic/screens/playlists_view.dart';
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

  testWidgets('新建播放列表后立即显示（无需重启）', (tester) async {
    late final LocalIndex index;
    late final Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('selfmusic_plw_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      index = LocalIndex();
      await index.open();
      final store = PlaylistStore(index);
      store.create('已有歌单');
    });

    final store = PlaylistStore(index);
    final provider = PlaylistsProvider(store);
    final nav = NavigationProvider();

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<PlaylistsProvider>.value(value: provider),
          ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ],
        child: const MaterialApp(
          home: Scaffold(body: PlaylistsView()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('已有歌单'), findsOneWidget);
    expect(find.text('新建歌单'), findsNothing);

    await tester.tap(find.text('新建'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField), '新建歌单');
    await tester.tap(find.text('创建'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // 无需重启，新歌单立即可见
    expect(find.text('新建歌单'), findsOneWidget);
    expect(provider.playlists.length, 2);

    await tester.runAsync(() async {
      index.close();
      dir.deleteSync(recursive: true);
    });
  });
}