import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/playlist_store.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
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
  final dir = await Directory.systemTemp.createTemp('selfmusic_backfill_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

const _addr = 'https://dav.example.com/music';

Future<void> _addWebdavSource(LocalIndex index) async {
  expect(
      await index.applySourceSnapshot(
        uuid: 'src-1',
        kind: 'webdav',
        name: 'NAS',
        address: _addr,
        config: null,
        enabled: true,
        deleted: false,
      ),
      isTrue);
}

class _FakeApi extends ApiClient {
  Map<String, dynamic>? pullData;
  _FakeApi() : super();
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
  Future<Map<String, dynamic>?> syncPull(int cursor) async => pullData;
}

void main() {
  test('歌单补推：配对前存量建单补 create，直连条目补 item_add（server 行跳过）',
      () async {
    final index = await _openIndex();
    await _addWebdavSource(index);
    // 直写索引模拟“配对前”数据：有行无事件。
    final pid = await index.createPlaylist('老歌单', description: 'd');
    await index.addPlaylistItem(pid,
        sourceKey: 'webdav:NAS',
        songRef: 'dav:/a.mp3',
        title: 'A',
        source: 'webdav');
    await index.addPlaylistItem(pid,
        sourceKey: 'server', songRef: 'srv:1', title: 'S', source: 'webdav');
    expect(index.pendingOutboxCount(), 0);

    final store = PlaylistStore(index, serverAvailable: () => true);
    final r = await store.backfill();
    expect(r, {'playlists': 1, 'items': 1});

    final outbox = index.pendingOutbox();
    expect(outbox.map((e) => e.type).toList(), [
      SyncEventTypes.playlistCreate,
      SyncEventTypes.playlistItemAdd,
    ]);
    final create =
        jsonDecode(outbox[0].payload) as Map<String, dynamic>;
    expect(create['name'], '老歌单');
    expect(create['description'], 'd');
    final uuid = index.playlistIdOfUuid(create['client_uuid'] as String);
    expect(uuid, pid);
    final add = jsonDecode(outbox[1].payload) as Map<String, dynamic>;
    expect(add['playlist_uuid'], create['client_uuid']);
    expect(add['source_ref'], 'dav:/a.mp3');
    expect(add['source_id'], 'src-1');
    expect(add['sort_order'], 1);
  });

  test('歌单补推离线门控：直连条目在 serverAvailable 为假时跳过（建单仍补）',
      () async {
    final index = await _openIndex();
    await _addWebdavSource(index);
    final pid = await index.createPlaylist('老歌单');
    await index.addPlaylistItem(pid,
        sourceKey: 'webdav:NAS',
        songRef: 'dav:/a.mp3',
        title: 'A',
        source: 'webdav');
    final store = PlaylistStore(index, serverAvailable: () => false);
    final r = await store.backfill();
    expect(r, {'playlists': 1, 'items': 0});
    expect(index.pendingOutbox().map((e) => e.type).toList(),
        [SyncEventTypes.playlistCreate]);
  });

  test('权重补推：脏行补 song.state 绝对态（含 streak/factor），server 行跳过',
      () async {
    final index = await _openIndex();
    await _addWebdavSource(index);
    await index.upsertPlayMeta('webdav:NAS', 'dav:/a.mp3',
        likeStreak: 4, factor: 1.1);
    await index.upsertPlayMeta('webdav:NAS', 'dav:/b.mp3', favorite: true);
    await index.upsertPlayMeta('webdav:NAS', 'dav:/c.mp3',
        dislikeStreak: 2, factor: 0.9, frozen: true);
    await index.upsertPlayMeta('server', 'srv:9', favorite: true);
    expect(index.pendingOutboxCount(), 0);

    final store = SongWeightStore(index, serverAvailable: () => true);
    expect(await store.backfill(), 3);
    final outbox = index.pendingOutbox();
    expect(
        outbox.map((e) => e.type).toSet(), {SyncEventTypes.songState});
    final byRef = {
      for (final e in outbox)
        (jsonDecode(e.payload) as Map)['source_ref']: jsonDecode(e.payload),
    };
    final a = byRef['dav:/a.mp3'] as Map;
    expect(a['like_streak'], 4);
    expect(a['dislike_streak'], 0);
    expect(a['weight'], 1.1);
    expect(a['frozen'], false);
    expect(a['is_favorite'], false);
    expect(a['source_id'], 'src-1');
    final c = byRef['dav:/c.mp3'] as Map;
    expect(c['frozen'], true);
    expect((byRef['dav:/b.mp3'] as Map)['is_favorite'], true);
  });

  test('权重补推离线门控：serverAvailable 为假时直连行跳过', () async {
    final index = await _openIndex();
    await _addWebdavSource(index);
    await index.upsertPlayMeta('webdav:NAS', 'dav:/a.mp3', likeStreak: 4);
    final store = SongWeightStore(index, serverAvailable: () => false);
    expect(await store.backfill(), 0);
    expect(index.pendingOutboxCount(), 0);
  });

  test('song.state 拉回端到端：权重快照落地 streak/factor/收藏', () async {
    final index = await _openIndex();
    final api = _FakeApi()
      ..pullData = {
        'cursor': 9,
        'has_more': false,
        'songs': [
          {
            'source_id': 'src-1',
            'source': 'webdav',
            'source_ref': 'dav:/a.mp3',
            'like_streak': 4,
            'dislike_streak': 0,
            'weight': 1.1,
            'frozen': false,
            'is_favorite': true,
          },
        ],
        'sources': [],
        'playlists': [],
        'playstates': [],
      };
    final engine =
        SyncEngine(api: api, index: index, settings: AppSettings(index));
    await engine.syncNow(force: true);
    expect(engine.lastError, isEmpty);
    final m = index.playMetaOf('server', 'dav:/a.mp3');
    expect(m.likeStreak, 4);
    expect(m.factor, 1.1);
    expect(m.favorite, isTrue);
    engine.stop();
  });
}
