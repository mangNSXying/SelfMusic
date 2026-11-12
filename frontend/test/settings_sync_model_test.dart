import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/sync_entity_key.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
import 'package:selfmusic/data/local/syncable_settings.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
import 'package:selfmusic/theme/theme_provider.dart';
import 'package:selfmusic/utils/zh_variant.dart';
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

Future<LocalIndex> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_syncsettings_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

void main() {
  late LocalIndex index;
  late AppSettings settings;

  setUp(() async {
    index = await _openIndex();
    settings = AppSettings(index);
  });

  tearDown(() {
    index.close();
  });

  test('白名单覆盖 v1/v2 四类，且非主题键都在 knownKeys', () {
    expect(SyncableSettings.playbackKeys, {
      AppSettings.kPlayModeDefault,
      AppSettings.kResumeOnStartup,
      AppSettings.kPreloadNext,
      AppSettings.kSleepPlayThroughDefault,
      AppSettings.kSleepDefaultDurationMinutes,
      AppSettings.kSleepDefaultCount,
      AppSettings.kLyricFocusIdleSec,
      AppSettings.kWeightedRandomEnabled,
      AppSettings.kWeightedDrawCooldown,
      AppSettings.kWeightedCountCooldownRatio,
      AppSettings.kCurveWeightEnabled,
      AppSettings.kCurveWeightSegments,
      AppSettings.kFadeEnabled,
      AppSettings.kFadeDurationMs,
    });
    expect(SyncableSettings.libraryKeys, {
      AppSettings.kScanIgnoreMinDurationSec,
      AppSettings.kScanIgnoreMinSizeBytes,
      AppSettings.kOnlineMetaLyricSource,
      AppSettings.kOnlineMetaCoverSource,
      AppSettings.kOnlineMetaSaveMode,
      AppSettings.kArtistResolveAuto,
      AppSettings.kFallbackAutoRepair,
    });
    expect(SyncableSettings.interfaceKeys, {
      AppSettings.kSongTitleFormat,
      AppSettings.kZhVariant,
      AppSettings.kPlayerTransition,
      AppSettings.kPlayerShowWeight,
      AppSettings.kLyricsShowCover,
      AppSettings.kPlayerAutoHideIdleSec,
      AppSettings.kLongPressCollapseGroups,
    });
    expect(SyncableSettings.themeKeys, {
      ThemeProvider.syncKeyMode,
      ThemeProvider.syncKeyAccent,
      ThemeProvider.syncKeyBackground,
    });
    expect(SyncableSettings.keys, hasLength(31));

    for (final key in SyncableSettings.keys) {
      // 主题存在 ThemeProvider(secure storage)，不在 app_settings.knownKeys。
      if (SyncableSettings.themeKeys.contains(key)) continue;
      expect(AppSettings.knownKeys, contains(key),
          reason: '缺少 knownKeys: $key');
    }

    // 设备本地 / 凭据 / 缓存 / 快捷键 / 布局永远不在同步白名单。
    for (final key in [
      AppSettings.kAppVolume,
      AppSettings.kEqualizerEnabled,
      AppSettings.kSyncEnabled,
      AppSettings.kSyncSettingsEnabled,
      AppSettings.kAllowInsecureHttp,
      AppSettings.kCacheMaxBytes,
      AppSettings.kShortcutWindowBindings,
      AppSettings.kLyricMaxLines,
      AppSettings.kScanWifiOnly,
    ]) {
      expect(SyncableSettings.isSyncable(key), isFalse, reason: key);
    }
  });

  test('本地同步项触发回调，本地项/类目开关不触发', () {
    final changes = <String>[];
    settings.onLocalSettingChanged = (key, value) => changes.add('$key=$value');

    settings.playModeDefault = 'loopList';
    settings.fadeDurationMs = 1200;
    settings.playerTransition = PlayerTransition.fade;
    settings.longPressCollapseGroups = true;
    expect(changes, [
      'play_mode_default=loopList',
      'fade_duration_ms=1200',
      'player_transition=fade',
      'long_press_collapse_groups=1',
    ]);

    changes.clear();
    settings.appVolume = 40;
    settings.lyricMaxLines = 10;
    settings.syncSettingsEnabled = true;
    settings.syncSettingsPlayback = false;
    expect(changes, isEmpty);
  });

  test('远端应用抑制回声，非法值忽略', () {
    final changes = <String>[];
    settings.onLocalSettingChanged = (key, value) => changes.add('$key=$value');

    expect(settings.applyRemoteSetting(AppSettings.kFadeDurationMs, '1200'),
        isTrue);
    expect(settings.fadeDurationMs, 1200);
    expect(changes, isEmpty, reason: '远端应用不得回推');

    expect(settings.applyRemoteSetting(AppSettings.kFadeDurationMs, '9999'),
        isFalse);
    expect(settings.fadeDurationMs, 1200, reason: '越界值保持原值');

    expect(
        settings.applyRemoteSetting(AppSettings.kOnlineMetaSaveMode, 'sidecar'),
        isTrue);
    expect(settings.onlineMetaSaveMode, OnlineMetaSaveMode.sidecar);

    expect(
        settings.applyRemoteSetting(AppSettings.kCurveWeightSegments,
            '[{"min_sec":300,"max_sec":null,"factor":0.5}]'),
        isTrue);
    expect(settings.weightCurveSegments, hasLength(1));
    expect(settings.weightCurveSegments.single['factor'], 0.5);

    expect(
        settings.applyRemoteSetting(AppSettings.kSongTitleFormat, 'titleOnly'),
        isTrue);
    expect(settings.songTitleFormat, SongTitleFormat.titleOnly);
    expect(settings.applyRemoteSetting(AppSettings.kZhVariant, 'simplified'),
        isTrue);
    expect(settings.zhVariant, ZhVariant.simplified);
    expect(settings.applyRemoteSetting(AppSettings.kPlayerTransition, 'fade'),
        isTrue);
    expect(settings.playerTransition, PlayerTransition.fade);
    expect(settings.applyRemoteSetting(AppSettings.kPlayerShowWeight, '0'),
        isTrue);
    expect(settings.playerShowWeight, isFalse);
    expect(
        settings.applyRemoteSetting(AppSettings.kLyricsShowCover, '0'), isTrue);
    expect(settings.lyricsShowCover, isFalse);
    expect(
        settings.applyRemoteSetting(AppSettings.kPlayerAutoHideIdleSec, '10'),
        isTrue);
    expect(settings.playerAutoHideIdleSec, 10);
    expect(settings.applyRemoteSetting(AppSettings.kPlayerAutoHideIdleSec, '7'),
        isTrue);
    expect(settings.playerAutoHideIdleSec, 7);
    expect(
        settings.applyRemoteSetting(AppSettings.kPlayerAutoHideIdleSec, '61'),
        isFalse);
    expect(settings.playerAutoHideIdleSec, 7);
    expect(settings.applyRemoteSetting(AppSettings.kLyricFocusIdleSec, '17'),
        isTrue);
    expect(settings.lyricFocusIdleSec, 17);
    expect(settings.applyRemoteSetting(AppSettings.kLyricFocusIdleSec, '0'),
        isFalse);
    expect(
        settings.applyRemoteSetting(AppSettings.kLongPressCollapseGroups, '1'),
        isTrue);
    expect(settings.longPressCollapseGroups, isTrue);

    settings.playModeDefault = 'loopList';
    changes.clear();
    expect(settings.applyRemoteSetting(AppSettings.kPlayModeDefault, 'bogus'),
        isFalse);
    expect(settings.playModeDefault, 'loopList');

    expect(settings.applyRemoteSetting('app_volume', '50'), isFalse);
    expect(
        settings.applyRemoteSetting(ThemeProvider.syncKeyMode, 'dark'), isFalse,
        reason: '主题键由 SyncEngine 外部桥接');
    expect(changes, isEmpty);
  });

  test('设置实体键用于本机待推 guard', () {
    expect(syncEntityKey('setting.set', {'key': 'fade_enabled'}),
        'setting|fade_enabled');
    expect(syncEntityKey('setting.set', const {}), isNull);
    expect(syncEntityKey('setting.set', {'key': ''}), isNull);
  });

  test('设置同步类目默认值：总关，v1 开、v2 关', () {
    expect(settings.syncSettingsEnabled, isFalse);
    expect(settings.syncSettingsPlayback, isTrue);
    expect(settings.syncSettingsLibrary, isTrue);
    expect(settings.syncSettingsInterface, isFalse);
    expect(settings.syncSettingsTheme, isFalse);
  });

  test('本地变更按同步开关/类目入队 outbox', () async {
    final sync = SyncEngine(api: ApiClient(), index: index, settings: settings);
    settings.syncSettingsEnabled = true;

    sync.onLocalSettingChanged(AppSettings.kFadeEnabled, '0');
    await index.flushWrites();
    var rows = (await index.pendingOutbox())
        .where((e) => e.type == SyncEventTypes.settingSet)
        .toList();
    expect(rows, hasLength(1));
    expect(rows.single.payload['key'], AppSettings.kFadeEnabled);
    expect(rows.single.payload['value'], '0');

    // 播放类目关闭：不再入队。
    settings.syncSettingsPlayback = false;
    sync.onLocalSettingChanged(AppSettings.kFadeDurationMs, '1200');
    await index.flushWrites();
    rows = (await index.pendingOutbox())
        .where((e) => e.type == SyncEventTypes.settingSet)
        .toList();
    expect(rows, hasLength(1));

    // 设备本地键 / 总开关关闭：都不入队。
    settings.syncSettingsPlayback = true;
    sync.onLocalSettingChanged(AppSettings.kAppVolume, '40');
    settings.syncSettingsEnabled = false;
    sync.onLocalSettingChanged(AppSettings.kFadeEnabled, '1');
    await index.flushWrites();
    rows = (await index.pendingOutbox())
        .where((e) => e.type == SyncEventTypes.settingSet)
        .toList();
    expect(rows, hasLength(1));

    sync.stop();
  });

  test('界面/主题类目默认关，按开关入队', () async {
    final sync = SyncEngine(api: ApiClient(), index: index, settings: settings);
    settings.syncSettingsEnabled = true;
    settings.syncSettingsPlayback = false;
    settings.syncSettingsLibrary = false;

    sync.onLocalSettingChanged(AppSettings.kPlayerTransition, 'fade');
    sync.onLocalSettingChanged(ThemeProvider.syncKeyMode, 'dark');
    await index.flushWrites();
    var rows = (await index.pendingOutbox())
        .where((e) => e.type == SyncEventTypes.settingSet)
        .toList();
    expect(rows, isEmpty);

    settings.syncSettingsInterface = true;
    sync.onLocalSettingChanged(AppSettings.kPlayerTransition, 'fade');
    await index.flushWrites();
    rows = (await index.pendingOutbox())
        .where((e) => e.type == SyncEventTypes.settingSet)
        .toList();
    expect(rows, hasLength(1));
    expect(rows.single.payload['key'], AppSettings.kPlayerTransition);

    settings.syncSettingsTheme = true;
    sync.onLocalSettingChanged(ThemeProvider.syncKeyMode, 'dark');
    await index.flushWrites();
    rows = (await index.pendingOutbox())
        .where((e) => e.type == SyncEventTypes.settingSet)
        .toList();
    expect(rows, hasLength(2));
    expect(
        rows.map((e) => e.payload['key']), contains(ThemeProvider.syncKeyMode));

    sync.stop();
  });
}
