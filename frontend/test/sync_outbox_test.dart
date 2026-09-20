import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
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
  final dir = await Directory.systemTemp.createTemp('selfmusic_sync_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

void main() {
  test('outbox：入队 / 待推 / 确认删除 / 死信隔离', () async {
    final index = await _openIndex();

    expect(index.pendingOutboxCount(), 0);
    final u1 = index.enqueueOutbox(SyncEventTypes.songLiked,
        {'source': 'webdav', 'source_ref': 'a/b.flac'});
    final u2 = index.enqueueOutbox(SyncEventTypes.playlistItemAdd,
        {'playlist_uuid': 'p1', 'source': 'local', 'source_ref': 'c.mp3'});
    expect(u1, isNotEmpty);
    expect(u1, isNot(equals(u2)));
    expect(index.pendingOutboxCount(), 2);

    final pending = index.pendingOutbox();
    expect(pending.map((e) => e.eventUuid), containsAll([u1, u2]));
    expect(pending.firstWhere((e) => e.eventUuid == u1).type,
        SyncEventTypes.songLiked);
    final payload =
        jsonDecode(pending.firstWhere((e) => e.eventUuid == u1).payload)
            as Map<String, dynamic>;
    expect(payload['source_ref'], 'a/b.flac');

    // 服务端接受 → 删队
    index.deleteOutbox([u1]);
    expect(index.pendingOutboxCount(), 1);

    // 服务端拒绝 → 死信，不再出现在待推里
    index.deadLetterOutbox([u2]);
    expect(index.pendingOutboxCount(), 0);
    expect(index.pendingOutbox(), isEmpty);

    index.close();
  });

  test('歌单 uuid：新建即带；重复 ensure 不再生', () async {
    final index = await _openIndex();

    final id = index.createPlaylist('测试');
    final uuid = index.playlistUuidOf(id);
    expect(uuid, isNotNull);
    expect(uuid, isNotEmpty);
    // 已有 uuid 的行：ensure 直接返回，不再生
    expect(index.ensurePlaylistUuid(id), uuid);
    expect(index.playlistUuidOf(id), uuid);

    index.close();
  });

  test('pull 歌单快照：新增 / 更新 / 墓碑删除；保留本地直连条目', () async {
    final index = await _openIndex();

    // 新增（含服务端条目）
    index.applyPlaylistSnapshot(
      uuid: 'puuid-1',
      name: '远端歌单',
      description: 'd',
      deleted: false,
      items: const [
        SyncedItem(
            source: 'webdav',
            songRef: 'x/y.flac',
            title: '远端歌',
            artist: 'A',
            album: 'B',
            sortOrder: 1),
      ],
    );
    var pid = index.playlistIdOfUuid('puuid-1');
    expect(pid, isNotNull);
    var items = index.playlistItems(pid!);
    expect(items.length, 1);
    expect(items.single.source, 'webdav');
    expect(items.single.songRef, 'x/y.flac');

    // 本地直连条目：pull 全量替换不得误删
    index.addPlaylistItem(pid,
        sourceKey: 'webdav:NAS',
        songRef: 'local/z.mp3',
        title: '本地歌',
        source: 'webdav');
    index.applyPlaylistSnapshot(
      uuid: 'puuid-1',
      name: '远端歌单改名',
      description: 'd',
      deleted: false,
      items: const [
        SyncedItem(
            source: 'webdav',
            songRef: 'x/y.flac',
            title: '远端歌',
            artist: 'A',
            album: 'B',
            sortOrder: 1),
        SyncedItem(
            source: 'local',
            songRef: 'w.mp3',
            title: '新远端歌',
            artist: null,
            album: null,
            sortOrder: 2),
      ],
    );
    items = index.playlistItems(pid);
    // 2 服务端行 + 1 本地直连行
    expect(items.length, 3);
    expect(items.where((e) => e.sourceKey != 'server').length, 1);
    expect(
        index.listPlaylists().firstWhere((p) => p.id == pid).name, '远端歌单改名');

    // 墓碑：本地硬删
    index.applyPlaylistSnapshot(
      uuid: 'puuid-1',
      name: 'x',
      deleted: true,
      items: const [],
    );
    expect(index.playlistIdOfUuid('puuid-1'), isNull);

    index.close();
  });

  test('pull 歌曲快照落 play_meta；断点镜像 roundtrip', () async {
    final index = await _openIndex();

    index.applySongSnapshot(
      songRef: 'a/b.flac',
      likeStreak: 0,
      dislikeStreak: 0,
      factor: 1.5,
      frozen: false,
      favorite: true,
    );
    final meta = index.playMetaOf('server', 'a/b.flac');
    expect(meta.favorite, isTrue);
    expect(meta.factor, 1.5);

    index.upsertBreakpointMirror(
      playlistUuid: 'puuid-9',
      songId: 42,
      source: 'webdav',
      sourceRef: 'a/b.flac',
      positionMs: 83000,
      updatedAt: '2026-09-20T12:00:00',
      deviceId: null,
    );
    final mirror = index.breakpointMirrorOf('puuid-9');
    expect(mirror, isNotNull);
    expect(mirror!.positionMs, 83000);
    expect(mirror.sourceRef, 'a/b.flac');

    index.close();
  });

  test('AppSettings 同步三键：默认值、持久化、白名单', () async {
    final index = await _openIndex();
    final s = AppSettings(index);
    expect(s.syncCursor, 0);
    expect(s.syncEnabled, isTrue);
    expect(s.lastSyncAt, '');

    s.syncCursor = 12345;
    s.syncEnabled = false;
    s.lastSyncAt = '2026-09-20T12:00:00';

    final s2 = AppSettings(index);
    expect(s2.syncCursor, 12345);
    expect(s2.syncEnabled, isFalse);
    expect(s2.lastSyncAt, '2026-09-20T12:00:00');

    for (final k in [
      AppSettings.kSyncCursor,
      AppSettings.kSyncEnabled,
      AppSettings.kLastSyncAt,
    ]) {
      expect(AppSettings.knownKeys, contains(k));
    }
    index.close();
  });
}
