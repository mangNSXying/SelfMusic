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

Future<LocalIndex> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_plrefresh_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

/// 假服务端：只吐 pull/corrections，不走网络。
class _FakeApi extends ApiClient {
  Map<String, dynamic>? pullData;
  Map<String, dynamic>? pushData;
  _FakeApi() : super();
  @override
  String get baseUrl => 'https://sync.example';
  @override
  Future<String?> getClientId() async => 'test-client';
  @override
  Future<Map<String, dynamic>?> syncPush(
      String clientId, List<Map<String, dynamic>> events) async {
    return pushData ?? {'applied': [], 'duplicates': []};
  }

  @override
  Future<Map<String, dynamic>?> syncPull(int cursor) async => pullData;
}

Map<String, dynamic> _playlistPage() => {
      'cursor': 7,
      'has_more': false,
      'songs': [],
      'sources': [],
      'playlists': [
        {
          'client_uuid': 'pl-uuid-1',
          'name': '远端歌单',
          'description': 'sync',
          'deleted': false,
          'items': [
            {
              'source_id': null,
              'source': 'webdav',
              'source_ref': 'dav:/m/a.mp3',
              'title': 'A',
              'artist': 'Art',
              'album': 'Alb',
              'sort_order': 0,
            },
          ],
        },
      ],
      'playstates': [],
    };

Map<String, dynamic> _emptyPage() => {
      'cursor': 8,
      'has_more': false,
      'songs': [],
      'sources': [],
      'playlists': [],
      'playstates': [],
    };

void main() {
  test('歌单同步触发 onPlaylistsApplied（pull 落库后 UI 可刷新）', () async {
    final index = await _openIndex();
    final api = _FakeApi()..pullData = _playlistPage();
    final engine = SyncEngine(
        api: api, index: index, settings: AppSettings(index));
    var fired = 0;
    engine.onPlaylistsApplied = () => fired++;
    await engine.syncNow(force: true);
    expect(engine.lastError, isEmpty);
    expect(fired, 1);
    expect(engine.lastPulledPlaylists, 1);
    // 快照已落库：列表查询可见（含条目）。
    final rows = index.listPlaylists();
    expect(rows.where((r) => r.clientUuid == 'pl-uuid-1'), hasLength(1));
    expect(index.playlistItems(rows.firstWhere((r) => r.clientUuid == 'pl-uuid-1').id),
        hasLength(1));
    engine.stop();
  });

  test('无歌单变更时不触发回调（避免空转刷新）', () async {
    final index = await _openIndex();
    final api = _FakeApi()..pullData = _emptyPage();
    final engine = SyncEngine(
        api: api, index: index, settings: AppSettings(index));
    var fired = 0;
    engine.onPlaylistsApplied = () => fired++;
    await engine.syncNow(force: true);
    expect(engine.lastError, isEmpty);
    expect(fired, 0);
    engine.stop();
  });

  test('push 回包 corrections 含歌单同样触发一次回调', () async {
    final index = await _openIndex();
    // _push 仅在 outbox 非空时发请求：先塞一个哑事件让流程走到 corrections。
    await index.enqueueOutbox('song.noop', {'source_ref': 'x'});
    final api = _FakeApi()
      ..pullData = _emptyPage()
      ..pushData = {
        'applied': [],
        'duplicates': [],
        'corrections': {
          'pl-uuid-1': (_playlistPage()['playlists'] as List).first,
        },
      };
    final engine = SyncEngine(
        api: api, index: index, settings: AppSettings(index));
    var fired = 0;
    engine.onPlaylistsApplied = () => fired++;
    await engine.syncNow(force: true);
    expect(engine.lastError, isEmpty);
    expect(fired, 1);
    expect(index.playlistIdOfUuid('pl-uuid-1'), isNotNull);
    engine.stop();
  });
}
