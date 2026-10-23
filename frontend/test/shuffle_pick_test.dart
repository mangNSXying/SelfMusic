import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/deep_list.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/screens/settings_screen.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:sqlite3/open.dart';

ffi.DynamicLibrary _openOnLinux() {
  try {
    return ffi.DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return ffi.DynamicLibrary.open('libsqlite3.so.0');
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

Future<LocalIndex> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_shuffle_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

Song _song(String ref, {String sourceKey = 'local:x'}) => Song(
      id: 0,
      sourceKey: sourceKey,
      title: ref,
      source: 'local',
      sourceRef: ref,
      fileSize: 0,
    );

String _key(Song s) => PlayerProvider.weightedKeyOf(s);

bool _same(Song a, Song b) =>
    a.sourceKey == b.sourceKey && a.sourceRef == b.sourceRef;

Set<String> _deepKeys(DeepListController dl) =>
    {for (final s in dl.entries) _key(s)};

void main() {
  group('shuffleCandidateIndices：普通随机候选池', () {
    final a = _song('a');
    final b = _song('b');
    final c = _song('c');
    final d = _song('d');
    final all = [a, b, c, d];

    test('池 = 全量 - 深层已播 - 当前曲', () {
      final got = PlayerProvider.shuffleCandidateIndices(
          all, {_key(a), _key(b)}, _key(b));
      expect(got, [2, 3]);
    });

    test('池空 → 新一轮候选（除当前曲外的全部唯一曲目）', () {
      final got = PlayerProvider.shuffleCandidateIndices(
          all, {_key(a), _key(b), _key(c), _key(d)}, _key(d));
      expect(got, [0, 1, 2]);
    });

    test('只有当前曲 → 允许重播当前曲', () {
      expect(
          PlayerProvider.shuffleCandidateIndices([a], {_key(a)}, _key(a)), [0]);
    });

    test('空列表 → 空候选', () {
      expect(PlayerProvider.shuffleCandidateIndices(const [], const {}, null),
          isEmpty);
    });

    test('全量重复条目按身份去重', () {
      final got =
          PlayerProvider.shuffleCandidateIndices([a, a, b], const {}, _key(a));
      expect(got, [2]);
    });

    test('不同播放源的同一 sourceRef 视为不同歌曲', () {
      final x = _song('same', sourceKey: 'local:x');
      final y = _song('same', sourceKey: 'local:y');
      final got =
          PlayerProvider.shuffleCandidateIndices([x, y], {_key(x)}, null);
      expect(got, [1]);
    });

    test('深层列表自身重复条目按身份集合处理', () {
      final got = PlayerProvider.shuffleCandidateIndices(
          all, {_key(a), _key(a), _key(b)}, null);
      expect(got, [2, 3]);
    });
  });

  group('深层列表容量即普通随机轮次', () {
    test('一轮内不重复；播完容量后 push 清空重来', () {
      final all = [_song('a'), _song('b'), _song('c'), _song('d')];
      final dl = DeepListController(capacity: all.length);
      Song? current;

      for (var round = 0; round < 2; round++) {
        final played = <String>[
          if (current != null) _key(current),
        ];
        while (true) {
          final deepKeys = _deepKeys(dl);
          final currentKey = current == null ? null : _key(current);
          final remaining = [
            for (final s in all)
              if (!deepKeys.contains(_key(s)) && _key(s) != currentKey) s,
          ];
          if (remaining.isEmpty) break;

          final candidates =
              PlayerProvider.shuffleCandidateIndices(all, deepKeys, currentKey);
          final next = all[candidates.first];
          expect(deepKeys.contains(_key(next)), isFalse,
              reason: '本轮内不得重复抽到已播歌曲');
          dl.pushPlayed(next, same: _same);
          current = next;
          played.add(_key(next));
        }
        expect(played.toSet().length, all.length, reason: '一轮应覆盖全部歌曲');

        // 池空后取新一轮候选；实际起播时 pushPlayed 因容量已满自动清空。
        final restart = PlayerProvider.shuffleCandidateIndices(
            all, _deepKeys(dl), _key(current!));
        expect(restart, isNotEmpty);
        final next = all[restart.first];
        dl.pushPlayed(next, same: _same);
        expect(dl.length, 1, reason: '深层满容量后应从当前曲重新开始');
        current = next;
      }
    });

    test('深层列表含重复条目时仍按容量换轮', () {
      final a = _song('a');
      final b = _song('b');
      final c = _song('c');
      final d = _song('d');
      final dl = DeepListController(capacity: 4, entries: [a, a, b, c]);
      expect(dl.length, 4);

      final candidates = PlayerProvider.shuffleCandidateIndices(
          [a, b, c, d], _deepKeys(dl), _key(c));
      expect(candidates, [3], reason: '身份去重后只剩未播的 d');

      dl.pushPlayed(d, same: _same);
      expect(dl.length, 1, reason: '满容量后先清空，再以当前曲开新一轮');
      expect(_key(dl.tail!), _key(d));
    });
  });

  group('加权随机开关设置', () {
    late LocalIndex index;

    setUp(() async {
      index = await _openIndex();
    });

    tearDown(() {
      index.close();
    });

    test('默认开启；关闭后持久化；knownKeys 含新键', () {
      final s = AppSettings(index);
      expect(s.weightedRandomEnabled, isTrue, reason: '默认开启加权随机');

      s.weightedRandomEnabled = false;
      expect(s.weightedRandomEnabled, isFalse);
      expect(AppSettings(index).weightedRandomEnabled, isFalse,
          reason: '写入后新实例重读一致');

      expect(
          AppSettings.knownKeys, contains(AppSettings.kWeightedRandomEnabled));
    });

    testWidgets('加权关闭时歌单起播走普通随机分支且下标合法', (tester) async {
      final settings = AppSettings(index)..weightedRandomEnabled = false;
      final p = PlayerProvider()
        ..attachAppSettings(settings)
        ..setMode(PlayMode.weighted);
      final songs = [_song('a'), _song('b'), _song('c'), _song('d')];
      for (var i = 0; i < 20; i++) {
        expect(p.startIndexForPlaylist(songs), inInclusiveRange(0, 3));
      }
    });

    testWidgets('设置页：加权随机默认开，关闭后冷却项置灰', (tester) async {
      final settings = AppSettings(index)
        ..playModeDefault = PlayMode.weighted.name;
      final nav = NavigationProvider()..openSettings(SettingsItem.playback);
      final direct = DirectSourceManager()..settings = settings;
      final player = PlayerProvider()..attachAppSettings(settings);
      addTearDown(player.dispose);

      // 超大视口：播放分区是懒构建的 ListView。
      tester.view.physicalSize = const Size(1080, 5000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MultiProvider(providers: [
            ChangeNotifierProvider<NavigationProvider>.value(value: nav),
            ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
            ChangeNotifierProvider<PlayerProvider>.value(value: player),
          ], child: const SettingsScreen()),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('随机播放 · 加权'), findsOneWidget);
      final sw = find.widgetWithText(SwitchListTile, '加权随机');
      expect(tester.widget<SwitchListTile>(sw).value, isTrue,
          reason: '加权随机默认开启');

      ListTile cooldown(String title) =>
          tester.widget<ListTile>(find.widgetWithText(ListTile, title));
      expect(cooldown('加权随机·次数冷却').enabled, isTrue);
      expect(cooldown('加权随机·次数冷却').onTap, isNotNull);
      expect(cooldown('加权随机·曲数冷却').enabled, isTrue);
      expect(cooldown('加权随机·曲数冷却').onTap, isNotNull);

      await tester.tap(sw);
      await tester.pump();

      expect(settings.weightedRandomEnabled, isFalse);
      expect(find.text('随机播放 · 普通（不放回）'), findsOneWidget);
      for (final title in ['加权随机·次数冷却', '加权随机·曲数冷却']) {
        final tile = cooldown(title);
        expect(tile.enabled, isFalse, reason: '$title 应置灰');
        expect(tile.onTap, isNull, reason: '$title 不可点击');
      }
    });
  });
}
