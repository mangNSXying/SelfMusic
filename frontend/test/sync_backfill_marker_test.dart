import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/playlist_store.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:sqlite3/open.dart';

/// 补录标记（backfill:true）：配对前存量补推的三类事件带标记，
/// 服务端据此“只建行、不赢现行行”。日常事件（用户操作）不带标记。
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

Future<(LocalIndex, Directory)> _openIndex(String prefix) async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp(prefix);
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return (index, dir);
}

/// 仅提供 baseUrl 的 Api（源自举只读可达性，不发网络）。
class _BaseUrlApi extends ApiClient {
  @override
  String get baseUrl => 'https://sync.example';
  @override
  Future<String?> getClientId() async => 'test-client';
}

Song _directSong() => Song.direct(
      id: 1,
      sourceKey: 'webdav:NAS',
      title: '直连歌',
      artist: 'A',
      albumName: 'B',
      source: 'webdav',
      sourceRef: '/music/z.mp3',
      fileSize: 100,
    );

void main() {
  test('权重 backfill：song.state 带标记；日常事件不带', () async {
    final (index, dir) = await _openIndex('selfmusic_bfweight_');
    try {
      await index.upsertSource('webdav:NAS', 'webdav', 'NAS', '{}');
      await index.upsertSongs([
        DirectSongRow(
            sourceKey: 'webdav:NAS',
            ref: '/music/z.mp3',
            title: '直连歌',
            size: 100,
            mtime: 1),
      ]);
      // 直连行变脏（喜欢）：backfill 覆盖它。
      await index.applySongSnapshot(
        songRef: '/music/z.mp3',
        source: 'webdav',
        likeStreak: 0,
        dislikeStreak: 0,
        factor: 1.5,
        frozen: false,
        favorite: true,
      );

      final weight = SongWeightStore(index, serverAvailable: () => true);
      expect(await weight.backfill(), 1);

      final pending = await index.pendingOutbox();
      expect(pending, hasLength(1));
      expect(pending.single.type, SyncEventTypes.songState);
      expect(pending.single.payload['backfill'], isTrue,
          reason: '补录权重应带标记');
      expect(pending.single.payload['source_ref'], '/music/z.mp3');

      // 日常事件（用户点喜欢）不带标记：走正常 LWW/重放。
      await weight.setUnliked(_directSong());
      final last =
          (await index.pendingOutbox()).lastWhere((e) => e.type == SyncEventTypes.songUnfavorite);
      expect(last.payload.containsKey('backfill'), isFalse);
    } finally {
      index.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('歌单 backfill：create/item_add 带标记；日常建单不带', () async {
    final (index, dir) = await _openIndex('selfmusic_bfplaylist_');
    try {
      final store = PlaylistStore(index, serverAvailable: () => true);
      final pid = await store.create('单');
      await store.addSong(pid, _directSong());
      // 日常事件：create + item_add，均无标记。
      for (final e in await index.pendingOutbox()) {
        expect(e.payload.containsKey('backfill'), isFalse);
      }

      final r = await store.backfill();
      expect(r['playlists'], 1);
      expect(r['items'], 1);
      final pending = await index.pendingOutbox();
      expect(pending, hasLength(4));
      // 补录的 create 与 item_add 带标记。
      expect(pending[2].type, SyncEventTypes.playlistCreate);
      expect(pending[2].payload['backfill'], isTrue);
      expect(pending[3].type, SyncEventTypes.playlistItemAdd);
      expect(pending[3].payload['backfill'], isTrue);
    } finally {
      index.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  test('源自举 backfill：存量源补 source.create 带标记', () async {
    final dir = await Directory.systemTemp.createTemp('selfmusic_bfsource_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final direct = DirectSourceManager();
    try {
      await direct.init();
      await direct.index.upsertSource('webdav:NAS', 'webdav', 'NAS', '{}');
      expect(direct.index.sourceUuidOf('webdav:NAS'), isNull);

      direct.attachApi(_BaseUrlApi());
      var waited = 0;
      while (await direct.index.pendingOutboxCount() == 0 && waited < 100) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        waited++;
      }
      final pending = await direct.index.pendingOutbox();
      final create = pending.firstWhere(
          (e) => e.type == SyncEventTypes.sourceCreate,
          orElse: () => throw StateError('自举未补发 source.create'));
      expect(create.payload['backfill'], isTrue,
          reason: '存量源自举补发应带标记');
      expect(create.payload['client_uuid'],
          direct.index.sourceUuidOf('webdav:NAS'));

      // 用户新建源走正常事件：需经源管理入口，此处只断言自举仅发一次
      //（uuid 已存在后不再重发）。
      direct.attachApi(_BaseUrlApi());
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
          (await direct.index.pendingOutbox())
              .where((e) => e.type == SyncEventTypes.sourceCreate)
              .length,
          1,
          reason: 'uuid 已存在不应重复补发');
    } finally {
      direct.dispose();
      direct.index.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });
}
