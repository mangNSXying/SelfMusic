import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
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

class _FakeApi extends ApiClient {
  final Map<String, dynamic> pullData;
  _FakeApi(this.pullData);

  @override
  String get baseUrl => 'http://test';

  @override
  Future<String?> getClientId() async => 'dev-a';

  @override
  Future<Map<String, dynamic>?> syncPull(int cursor) async => pullData;
}

Future<LocalIndex> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_settings_pull_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

void main() {
  test('pull 应用界面键，主题键走外部桥并按类目回传变化键', () async {
    final index = await _openIndex();
    final settings = AppSettings(index);
    settings.syncSettingsEnabled = true;
    settings.syncSettingsPlayback = false;
    settings.syncSettingsLibrary = false;
    settings.syncSettingsInterface = true;
    settings.syncSettingsTheme = true;

    final external = <String, String>{};
    final applied = <String>{};
    final sync = SyncEngine(
      api: _FakeApi({
        'cursor': 1,
        'has_more': false,
        'songs': const [],
        'sources': const [],
        'playlists': const [],
        'playstates': const [],
        'settings': [
          {'setting_key': 'player_transition', 'setting_value': 'fade'},
          {'setting_key': 'theme_mode', 'setting_value': 'dark'},
        ],
        'breakpoint_protocol': 2,
        'server_time': DateTime.now().toIso8601String(),
      }),
      index: index,
      settings: settings,
    );
    sync.applyExternalSetting = (key, value) async {
      external[key] = value;
      return true;
    };
    sync.onSettingsApplied = (keys) => applied.addAll(keys);

    await sync.syncNow(force: true);

    expect(settings.playerTransition, PlayerTransition.fade);
    expect(external['theme_mode'], 'dark');
    expect(applied, containsAll(['player_transition', 'theme_mode']));

    sync.stop();
    index.close();
  });
}
