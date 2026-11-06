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

  test('白名单只含播放偏好与媒体库规则，且键都在 knownKeys', () {
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
    expect(SyncableSettings.keys, hasLength(21));

    for (final key in SyncableSettings.keys) {
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
      AppSettings.kSongTitleFormat,
      AppSettings.kLyricMaxLines,
    ]) {
      expect(SyncableSettings.isSyncable(key), isFalse, reason: key);
    }
  });

  test('本地同步项触发回调，本地项/类目开关不触发', () {
    final changes = <String>[];
    settings.onLocalSettingChanged = (key, value) => changes.add('$key=$value');

    settings.playModeDefault = 'loopList';
    settings.fadeDurationMs = 1200;
    expect(changes, ['play_mode_default=loopList', 'fade_duration_ms=1200']);

    changes.clear();
    settings.appVolume = 40;
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

    settings.playModeDefault = 'loopList';
    changes.clear();
    expect(settings.applyRemoteSetting(AppSettings.kPlayModeDefault, 'bogus'),
        isFalse);
    expect(settings.playModeDefault, 'loopList');

    expect(settings.applyRemoteSetting('app_volume', '50'), isFalse);
    expect(
        settings.applyRemoteSetting(AppSettings.kSongTitleFormat, 'titleOnly'),
        isFalse);
    expect(changes, isEmpty);
  });

  test('设置实体键用于本机待推 guard', () {
    expect(syncEntityKey('setting.set', {'key': 'fade_enabled'}),
        'setting|fade_enabled');
    expect(syncEntityKey('setting.set', const {}), isNull);
    expect(syncEntityKey('setting.set', {'key': ''}), isNull);
  });

  test('设置同步类目默认值：总关、播放/媒体库类目开', () {
    expect(settings.syncSettingsEnabled, isFalse);
    expect(settings.syncSettingsPlayback, isTrue);
    expect(settings.syncSettingsLibrary, isTrue);
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
}
