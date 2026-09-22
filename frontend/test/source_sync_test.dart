import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/playlist_store.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
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
  final dir = await Directory.systemTemp.createTemp('selfmusic_srcsync_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

const _addr = 'https://dav.example.com/music';

void main() {
  test('源同步：create 落库 / kind+地址去重合并 / 更新 / 墓碑删除 / 本地源跳过', () async {
    final index = await _openIndex();

    expect(
        index.applySourceSnapshot(
          uuid: 'u1',
          kind: 'webdav',
          name: 'NAS',
          address: _addr,
          config: {'name': 'NAS', 'baseUrl': _addr, 'username': 'u'},
          enabled: true,
          deleted: false,
        ),
        isTrue);
    expect(index.getSource('webdav:NAS'), isNotNull);
    expect(index.sourceUuidOf('webdav:NAS'), 'u1');

    // 另一台设备先有自己的 uuid，收到服务端去重后的权威 uuid（correction）→ 重绑不重复建源。
    expect(
        index.applySourceSnapshot(
          uuid: 'u2',
          kind: 'webdav',
          name: 'NAS-alt',
          address: _addr,
          config: {'name': 'NAS-alt', 'baseUrl': _addr},
          enabled: true,
          deleted: false,
        ),
        isTrue);
    expect(index.listSources().length, 1);
    expect(index.sourceUuidOf('webdav:NAS'), 'u2');
    expect(
        index.applySourceSnapshot(
          uuid: 'u1',
          kind: 'webdav',
          name: 'NAS',
          address: _addr,
          config: {'name': 'NAS', 'baseUrl': _addr},
          enabled: true,
          deleted: false,
        ),
        isTrue);
    expect(index.listSources().length, 1);
    expect(index.sourceUuidOf('webdav:NAS'), 'u1');

    // uuid 命中 → 更新名称/开关（key 由名称派生，不随远端名变化）。
    expect(
        index.applySourceSnapshot(
          uuid: 'u1',
          kind: 'webdav',
          name: 'NAS2',
          address: _addr,
          config: {'name': 'NAS2', 'baseUrl': _addr},
          enabled: false,
          deleted: false,
        ),
        isTrue);
    final row = index.getSource('webdav:NAS')!;
    expect(row.name, 'NAS2');
    expect(row.enabled, isFalse);

    // 本地文件夹源不参与同步。
    expect(
        index.applySourceSnapshot(
          uuid: 'u9',
          kind: 'local',
          name: '本地',
          address: '/music',
          config: null,
          enabled: true,
          deleted: false,
        ),
        isFalse);

    // 墓碑：本地硬删（源 + 索引）。
    expect(
        index.applySourceSnapshot(
          uuid: 'u1',
          kind: 'webdav',
          name: null,
          address: _addr,
          config: null,
          enabled: true,
          deleted: true,
        ),
        isTrue);
    expect(index.getSource('webdav:NAS'), isNull);

    index.close();
  });

  test('源实例 uuid：权重 / 歌单条目载荷携带 source_id', () async {
    final index = await _openIndex();
    index.upsertSource('webdav:NAS', 'webdav', 'NAS',
        jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final uuid = index.ensureSourceUuid('webdav:NAS');
    expect(index.sourceKeyOfUuid(uuid), 'webdav:NAS');
    expect(index.ensureSourceUuid('webdav:NAS'), uuid); // 稳定不重生成

    final song = Song.direct(
      id: 1,
      sourceKey: 'webdav:NAS',
      title: 't',
      source: 'webdav',
      sourceRef: '/music/a.flac',
      fileSize: 1,
    );
    final weight = SongWeightStore(index, serverAvailable: () => true);
    weight.setLiked(song);
    var payload = jsonDecode(index.pendingOutbox().last.payload)
        as Map<String, dynamic>;
    expect(payload['source_id'], uuid);
    expect(payload['source'], 'webdav');

    index.deleteOutbox(
        index.pendingOutbox().map((e) => e.eventUuid).toList());
    final playlists = PlaylistStore(index, serverAvailable: () => true);
    playlists.create('p');
    index.deleteOutbox(
        index.pendingOutbox().map((e) => e.eventUuid).toList());
    final pid = index.listPlaylists().single.id;
    playlists.addSong(pid, song);
    payload = jsonDecode(index.pendingOutbox().last.payload)
        as Map<String, dynamic>;
    expect(index.pendingOutbox().last.type, SyncEventTypes.playlistItemAdd);
    expect(payload['source_id'], uuid);
    expect(payload['title'], 't');

    index.close();
  });

  test('源实例 uuid 落库映射：权重写本机源行、歌单条目按源 key 落库（无重复快照行）', () async {
    final index = await _openIndex();
    index.upsertSource('webdav:NAS', 'webdav', 'NAS',
        jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final uuid = index.ensureSourceUuid('webdav:NAS');

    // 权重快照：uuid 命中 → 写本机源 key，不再写 server 快照行。
    index.applySongSnapshot(
      songRef: '/music/a.flac',
      source: 'webdav',
      sourceId: uuid,
      likeStreak: 0,
      dislikeStreak: 0,
      factor: 1.5,
      frozen: false,
      favorite: true,
    );
    expect(index.playMetaOf('webdav:NAS', '/music/a.flac').favorite, isTrue);
    expect(index.playMetaOf('server', '/music/a.flac').favorite, isFalse);

    // 歌单条目：uuid 命中 → 落本机源 key（可直接播放）。
    index.applyPlaylistSnapshot(
      uuid: 'puuid-1',
      name: '远端歌单',
      deleted: false,
      items: const [
        SyncedItem(
          sourceId: 'UUID_PLACEHOLDER',
          source: 'webdav',
          songRef: '/music/a.flac',
          title: '远端歌',
          sortOrder: 1,
        ),
      ],
    );
    // 用真实 uuid 重放（const 无法插值）。
    index.applyPlaylistSnapshot(
      uuid: 'puuid-1',
      name: '远端歌单',
      deleted: false,
      items: [
        SyncedItem(
          sourceId: uuid,
          source: 'webdav',
          songRef: '/music/a.flac',
          title: '远端歌',
          sortOrder: 1,
        ),
      ],
    );
    final pid = index.playlistIdOfUuid('puuid-1')!;
    final items = index.playlistItems(pid);
    expect(items.length, 1);
    expect(items.single.sourceKey, 'webdav:NAS');

    index.close();
  });

  test('源去重地址工具：WebDAV=baseUrl，本地源不参与同步', () {
    expect(isSyncableKind('local'), isFalse);
    expect(isSyncableKind('webdav'), isTrue);
    expect(isSyncableKind('smb'), isTrue);
    expect(sourceAddressOf('webdav', {'baseUrl': ' https://x/dav '}),
        'https://x/dav');
    expect(sourceAddressOf('local', {'path': '/music'}), '');
  });
}
