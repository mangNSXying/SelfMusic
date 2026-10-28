import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/navigation_provider.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/screens/settings_screen.dart';
import 'package:selfmusic/services/equalizer/equalizer_types.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/widgets/eq_curve_editor.dart';
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

void main() {
  late Directory dir;
  late LocalIndex index;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_eq_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
  });

  tearDown(() {
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('均衡器设置模型', () {
    test('默认 10 段全 0，保存保留一位小数', () {
      final s = AppSettings(index);
      expect(s.eqBands, hasLength(kEqBandCount));
      expect(s.eqBands, everyElement(0));

      s.eqBands = const [
        1.26,
        -3.44,
        0.04,
        0.06,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
        0.0,
      ];
      expect(AppSettings(index).eqBands.first, closeTo(1.3, 0.001));
      expect(AppSettings(index).eqBands[1], closeTo(-3.4, 0.001));
      expect(AppSettings(index).eqBands[2], closeTo(0.0, 0.001));
      expect(index.settingsGet(AppSettings.kEqSchema), '2');
    });

    test('旧 5 段启动时迁移到 10 段并写入 schema', () {
      index.settingsSet(AppSettings.kEqBands, jsonEncode([12, 0, 0, 0, -12]));
      final s = AppSettings(index);
      final bands = s.eqBands;
      expect(bands, hasLength(kEqBandCount));
      expect(bands.first, closeTo(12, 0.1), reason: '31.5Hz 沿用最低旧段');
      expect(bands[1], greaterThan(10), reason: '63Hz 靠近旧 60Hz');
      expect(bands[2], inInclusiveRange(4, 7), reason: '125Hz 插值');
      expect(bands[9], closeTo(-12, 0.001), reason: '16k 沿用最高旧段');
      expect(index.settingsGet(AppSettings.kEqSchema), '2');
      // 二次构造不再改写。
      final raw = index.settingsGet(AppSettings.kEqBands);
      AppSettings(index);
      expect(index.settingsGet(AppSettings.kEqBands), raw);
    });

    test('任意长度规范为 10 段并钳制 ±12dB', () {
      final s = AppSettings(index);
      s.eqBands = const [20, -20, 1];
      final bands = s.eqBands;
      expect(bands, hasLength(kEqBandCount));
      expect(bands[0], 12);
      expect(bands[1], -12);
      expect(bands[2], 1);
      expect(bands[9], 0);
    });

    test('preamp 钳制 [-12, 0] 且持久化', () {
      final s = AppSettings(index);
      expect(s.eqPreampDb, 0);
      s.eqPreampDb = -30;
      expect(s.eqPreampDb, -12);
      s.eqPreampDb = 3;
      expect(s.eqPreampDb, 0);
      s.eqPreampDb = -6.4;
      expect(AppSettings(index).eqPreampDb, closeTo(-6.4, 0.001));
    });

    test('knownKeys 包含均衡器新键', () {
      expect(AppSettings.knownKeys, contains(AppSettings.kEqBands));
      expect(AppSettings.knownKeys, contains(AppSettings.kEqSchema));
      expect(AppSettings.knownKeys, contains(AppSettings.kEqPreamp));
    });

    test('预设均为 10 段且在范围内；可识别当前预设', () {
      for (final p in kEqPresets) {
        expect(p.gains, hasLength(kEqBandCount), reason: p.name);
        for (final g in p.gains) {
          expect(g, inInclusiveRange(kEqMinDb, kEqMaxDb), reason: p.name);
        }
      }
      expect(matchingEqPreset(const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), isNull);
      expect(matchingEqPreset(kEqPresets[1].gains)?.name, kEqPresets[1].name);
    });

    test('原生 capabilities 解析：Dynamics/回退/不支持', () {
      final dp = EqualizerCapabilities.fromChannelMap({
        'kind': 'dynamics',
        'bandCount': kEqBandCount,
        'frequencies': kEqFrequencies,
        'minDb': -12,
        'maxDb': 12,
      });
      expect(dp.supported, isTrue);
      expect(dp.kind, EqBackendKind.dynamics);
      expect(dp.frequencies, hasLength(kEqBandCount));

      final eq = EqualizerCapabilities.fromChannelMap({
        'kind': 'equalizer',
        'bandCount': 5,
        'frequencies': [60, 230, 910, 3600, 14000],
        'minDb': -15,
        'maxDb': 15,
        'note': '5 段兼容',
      });
      expect(eq.supported, isTrue);
      expect(eq.isFallback, isTrue);
      expect(eq.note, '5 段兼容');

      expect(EqualizerCapabilities.fromChannelMap(null).supported, isFalse);
      expect(EqualizerCapabilities.fromChannelMap({'kind': 'nope'}).supported,
          isFalse);
    });
  });

  group('mpv af 链', () {
    test('10 个命名 equalizer + preamp volume', () {
      final chain = buildMpvEqualizerChain(
        gains: const [3, 0, 0, 0, 0, 0, 0, 0, 0, -4],
        preampDb: -6,
      );
      expect(chain, contains('@pre:lavfi-volume=volume=-6.0dB'));
      expect(chain, contains('@eq0:lavfi-equalizer=frequency=31.5'));
      expect(chain, contains('gain=3.00'));
      expect(chain, contains('@eq5:lavfi-equalizer=frequency=1000'));
      expect(chain, contains('@eq9:lavfi-equalizer=frequency=16000'));
      expect(chain, contains('gain=-4.00'));
      expect('@eq'.allMatches(chain).length, kEqBandCount);
    });

    test('preamp 为 0 时不插入 volume', () {
      final chain = buildMpvEqualizerChain(
          gains: List<double>.filled(kEqBandCount, 0), preampDb: 0);
      expect(chain.startsWith('@eq0:'), isTrue);
      expect(chain, isNot(contains('lavfi-volume')));
    });
  });

  group('曲线几何', () {
    const size = Size(400, 200);
    test('20Hz/20kHz 映射到绘图区两端', () {
      final plot = EqCurveGeometry.plotRect(size);
      expect(EqCurveGeometry.xForFrequency(20, size), closeTo(plot.left, 0.01));
      expect(EqCurveGeometry.xForFrequency(20000, size),
          closeTo(plot.right, 0.01));
    });

    test('dB 与 Y 互为逆映射', () {
      final plot = EqCurveGeometry.plotRect(size);
      expect(EqCurveGeometry.gainForY(plot.top, size), closeTo(12, 0.01));
      expect(EqCurveGeometry.gainForY(plot.bottom, size), closeTo(-12, 0.01));
      expect(
          EqCurveGeometry.gainForY(EqCurveGeometry.yForGain(3.5, size), size),
          closeTo(3.5, 0.01));
    });

    test('点击 1kHz 附近选到第 5 段', () {
      final x = EqCurveGeometry.xForFrequency(1000, size);
      expect(EqCurveGeometry.nearestBandIndex(x, size), 5);
    });
  });

  testWidgets('曲线拖动回调到对应频段与增益', (tester) async {
    int? changedIndex;
    double? changedDb;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: EqCurveEditor(
              gains: List<double>.filled(kEqBandCount, 0),
              onChanged: (i, db) {
                changedIndex = i;
                changedDb = db;
              },
            ),
          ),
        ),
      ),
    ));
    final box = tester.getRect(find.byType(EqCurveEditor));
    final localSize = Size(box.width, box.height);
    final target = Offset(
      box.left + EqCurveGeometry.xForFrequency(1000, localSize),
      box.top + EqCurveGeometry.yForGain(6, localSize),
    );
    await tester.tapAt(target);
    await tester.pump();
    expect(changedIndex, 5);
    expect(changedDb, closeTo(6, 0.5));
  });

  testWidgets('设置页开启均衡器后显示曲线、预设与前级；预设点击写入 10 段', (tester) async {
    final settings = AppSettings(index)..equalizerEnabled = true;
    final direct = DirectSourceManager()..settings = settings;
    final nav = NavigationProvider()..openSettings(SettingsItem.playback);
    final player = PlayerProvider()..attachAppSettings(settings);
    addTearDown(player.dispose);

    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<NavigationProvider>.value(value: nav),
        ChangeNotifierProvider<DirectSourceManager>.value(value: direct),
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SettingsScreen()),
      ),
    ));
    await tester.pump();

    expect(find.text('均衡器'), findsOneWidget);
    expect(find.byType(EqCurveEditor), findsOneWidget);
    expect(find.byKey(const ValueKey('eq-preamp-slider')), findsOneWidget);
    expect(find.text('流行'), findsOneWidget);

    await tester.tap(find.text('流行'));
    await tester.pump();
    expect(settings.eqBands, kEqPresets[1].gains);
  });

  testWidgets('开关/调段不重建播放器（EQ 实时下发）', (tester) async {
    final settings = AppSettings(index);
    final player = PlayerProvider();
    final first = player.player;
    player.attachAppSettings(settings);
    expect(identical(player.player, first), isTrue);

    await tester.runAsync(() async {
      await player.setEqualizerEnabled(true);
      await player.setEqBand(2, 4.5);
      await player.flushEqualizer();
    });

    expect(identical(player.player, first), isTrue, reason: 'EQ 不应重建播放器');
    expect(settings.eqBands[2], 4.5);
    player.dispose();
  });
}
