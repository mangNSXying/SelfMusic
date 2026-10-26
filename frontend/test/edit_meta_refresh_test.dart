import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/widgets/edit_song_meta_dialog.dart';
import 'package:sqlite3/open.dart';

/// 「修改信息」窗的数据自动刷新回归：
/// 在线回填（标签/封面/歌词）落库后，无论在线窗是否关闭、从主窗还是
/// 封面/歌词子窗进入，主窗输入框与媒体摘要都应自动取索引最新行，
/// 不能要求关窗重开；用户已手改的字段不被覆盖。

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

const List<int> _k1x1Png = [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, //
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, //
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, //
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, //
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
];

/// 落库走后台写隔离（真实 isolate 往返）：交替 runAsync 与 pump 推进。
Future<void> settleWriter(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
}

Future<void> pumpFrame(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _Harness {
  final Directory dir;
  final DirectSourceManager direct;
  _Harness(this.dir, this.direct);

  static Future<_Harness> create(String prefix) async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp(prefix);
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final direct = DirectSourceManager();
    await direct.init();
    await direct.index.upsertSource('local:test', 'local', '本地', '{}');
    await direct.index.upsertSongs([
      DirectSongRow(
          sourceKey: 'local:test',
          ref: 'a',
          title: '旧标题',
          artist: '旧歌手',
          album: '旧专辑',
          duration: 100,
          format: 'mp3',
          size: 1024,
          mtime: 1),
    ]);
    return _Harness(dir, direct);
  }

  Future<void> dispose() async {
    direct.dispose();
    dir.deleteSync(recursive: true);
  }
}

List<String> _editFieldTexts(WidgetTester tester) => [
      for (final f in tester.widgetList<TextField>(find.descendant(
        of: find.byType(EditSongMetaDialog),
        matching: find.byType(TextField),
      )))
        f.controller!.text
    ];

Future<void> _openEditDialog(
    WidgetTester tester, DirectSourceManager direct) async {
  await tester.pumpWidget(
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
                  builder: (_) => EditSongMetaDialog(
                      song: direct.index.songByRef('local:test', 'a')!),
                ),
                child: const Text('打开修改信息'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开修改信息'));
  await tester.pumpAndSettle();
}

Future<void> _openMainOnline(WidgetTester tester) async {
  await tester.ensureVisible(find.text('在线获取元数据…'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('在线获取元数据…'));
  await pumpFrame(tester);
}

/// 模拟在线标签回填的真实落库 + 变更通知（与 OnlineMetaDialog._applyTags 同口径）。
Future<void> _applyOnlineTagChange(
    WidgetTester tester, DirectSourceManager direct, String title) async {
  await tester.runAsync(() async {
    await direct.index.updateSongUserMeta('local:test', 'a', title: title);
    direct.notifySongMetaChanged();
  });
  await settleWriter(tester);
}

final _closeTopmost = find.text('关闭').last;

void main() {
  testWidgets('在线回填落库即刷新（不关在线窗），手改字段保留', (tester) async {
    final h = (await tester
        .runAsync(() => _Harness.create('selfmusic_metarefresh_live_')))!;
    try {
      await _openEditDialog(tester, h.direct);
      await tester.enterText(find.byType(TextField).at(1), '手改歌手');
      await tester.pump();
      await _openMainOnline(tester);
      await _applyOnlineTagChange(tester, h.direct, '新标题');

      expect(_editFieldTexts(tester), contains('新标题'));
      expect(_editFieldTexts(tester), contains('手改歌手'));

      // 连续第二次回填仍应跟随（此前自动回填的值不算用户手改）。
      await _applyOnlineTagChange(tester, h.direct, '再改标题');
      expect(_editFieldTexts(tester), contains('再改标题'));
      expect(_editFieldTexts(tester), contains('手改歌手'));
    } finally {
      await tester.runAsync(h.dispose);
    }
  });

  testWidgets('封面子窗口在线回填后关闭，主窗标题自动回填', (tester) async {
    final h = (await tester
        .runAsync(() => _Harness.create('selfmusic_metarefresh_cover_')))!;
    try {
      await _openEditDialog(tester, h.direct);

      await tester.ensureVisible(find.text('封面'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('封面'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在线获取'));
      await pumpFrame(tester);
      await _applyOnlineTagChange(tester, h.direct, '封面路径标题');
      await tester.tap(_closeTopmost);
      await pumpFrame(tester);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(_editFieldTexts(tester), contains('封面路径标题'));
    } finally {
      await tester.runAsync(h.dispose);
    }
  });

  testWidgets('歌词子窗口在线回填后关闭，主窗标题自动回填', (tester) async {
    final h = (await tester
        .runAsync(() => _Harness.create('selfmusic_metarefresh_lyrics_')))!;
    try {
      await _openEditDialog(tester, h.direct);

      await tester.ensureVisible(find.text('歌词'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('歌词'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('在线获取'));
      await pumpFrame(tester);
      await _applyOnlineTagChange(tester, h.direct, '歌词路径标题');
      await tester.tap(_closeTopmost);
      await pumpFrame(tester);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(_editFieldTexts(tester), contains('歌词路径标题'));
    } finally {
      await tester.runAsync(h.dispose);
    }
  });

  testWidgets('主窗在线窗关闭后封面/歌词摘要同步刷新', (tester) async {
    final h = (await tester
        .runAsync(() => _Harness.create('selfmusic_metarefresh_media_')))!;
    try {
      await _openEditDialog(tester, h.direct);
      expect(find.text('无（点击设置）'), findsNWidgets(2));

      final coverFile = File('${h.dir.path}/cv.png');
      await tester.runAsync(() async {
        await coverFile.writeAsBytes(Uint8List.fromList(_k1x1Png));
        await h.direct.index
            .enrichSong('local:test', 'a', coverPath: coverFile.path);
        await h.direct.index
            .setLyrics('local:test', 'a', '[00:01.00]第一行\n[00:02.00]第二行\n');
      });

      await _openMainOnline(tester);
      await tester.tap(_closeTopmost);
      await tester.pumpAndSettle();

      expect(find.text('已设置（点击查看/更换）'), findsOneWidget);
      expect(find.text('2 行（点击查看/编辑）'), findsOneWidget);
    } finally {
      await tester.runAsync(h.dispose);
    }
  });
}
