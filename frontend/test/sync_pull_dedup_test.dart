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
  final dir = await Directory.systemTemp.createTemp('selfmusic_dedup_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

Map<String, dynamic> _song() => {
      'source_id': 'src-1',
      'source': 'webdav',
      'source_ref': 'dav:/a.mp3',
      'like_streak': 4,
      'dislike_streak': 0,
      'weight': 1.1,
      'frozen': false,
      'is_favorite': true,
    };

Map<String, dynamic> _playlist() => {
      'client_uuid': 'pl-1',
      'name': '远端歌单',
      'description': null,
      'deleted': false,
      'items': [
        {
          'source_id': 'src-1',
          'source': 'webdav',
          'source_ref': 'dav:/a.mp3',
          'title': 'A',
          'artist': null,
          'album': null,
          'sort_order': 0,
        },
      ],
    };

Map<String, dynamic> _playstate() => {
      'client_uuid': 'pl-1',
      'song_id': null,
      'source_id': 'src-1',
      'source': 'webdav',
      'source_ref': 'dav:/a.mp3',
      'position_ms': 42000,
      'deep_list': [],
      'updated_at': '2026-10-09T12:00:00',
    };

/// 两页都回同一个实体（模拟实体事件横跨页边界）：
/// 服务端只在单页内去重，客户端必须跨页去重，否则重复落库/计数。
class _PagedApi extends ApiClient {
  int pulls = 0;
  @override
  String get baseUrl => 'https://sync.example';
  @override
  Future<String?> getClientId() async => 'test-client';
  @override
  Future<Map<String, dynamic>?> syncPush(
      String clientId, List<Map<String, dynamic>> events) async {
    return {'applied': [], 'duplicates': []};
  }

  @override
  Future<Map<String, dynamic>?> syncPull(int cursor) async {
    pulls++;
    if (cursor == 0) {
      return {
        'cursor': 1,
        'has_more': true,
        'songs': [_song()],
        'sources': [],
        'playlists': [_playlist()],
        'playstates': [_playstate()],
      };
    }
    return {
      'cursor': 2,
      'has_more': false,
      'songs': [_song()],
      'sources': [],
      'playlists': [_playlist()],
      'playstates': [_playstate()],
    };
  }
}

void main() {
  test('跨页实体去重：重复快照只应用/计数一次', () async {
    final index = await _openIndex();
    final api = _PagedApi();
    final engine =
        SyncEngine(api: api, index: index, settings: AppSettings(index));
    var playlistsFired = 0;
    Set<String> changed = {};
    engine.onPlaylistsApplied = (uuids) {
      playlistsFired++;
      changed = uuids;
    };

    await engine.syncNow(force: true);

    expect(engine.lastError, isEmpty);
    expect(api.pulls, 2, reason: 'has_more 应继续翻页');
    expect(engine.lastPulledSongs, 1, reason: '两页同一歌曲只计一次');
    expect(engine.lastPulledPlaylists, 1, reason: '两页同一歌单只计一次');
    expect(playlistsFired, 1);
    expect(changed, {'pl-1'});

    // 原始形态落库：歌曲权重、歌单、断点镜像都在位。
    expect(index.playMetaOf('server', 'dav:/a.mp3').favorite, isTrue);
    final pid = index.playlistIdOfUuid('pl-1');
    expect(pid, isNotNull);
    expect(index.playlistItems(pid!), hasLength(1));
    final mirror = index.breakpointMirrorOf('pl-1');
    expect(mirror, isNotNull);
    expect(mirror!.positionMs, 42000);

    engine.stop();
    index.close();
  });
}
