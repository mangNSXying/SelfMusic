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
        await index.applySourceSnapshot(
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
        await index.applySourceSnapshot(
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
        await index.applySourceSnapshot(
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
        await index.applySourceSnapshot(
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
        await index.applySourceSnapshot(
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
        await index.applySourceSnapshot(
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

  test('删除源时一并清除该源在歌单中的条目（其它源条目保留）', () async {
    final index = await _openIndex();
    await index.upsertSource('webdav:NAS', 'webdav', 'NAS',
        jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final uuid = await index.ensureSourceUuid('webdav:NAS');
    final pid = await index.createPlaylist('p');
    await index.addPlaylistItem(pid,
        sourceKey: 'webdav:NAS', songRef: '/music/a.flac', title: 'A');
    await index.addPlaylistItem(pid,
        sourceKey: 'local:Other', songRef: '/music/b.flac', title: 'B');

    expect(
        await index.applySourceSnapshot(
          uuid: uuid,
          kind: 'webdav',
          name: null,
          address: _addr,
          config: null,
          enabled: true,
          deleted: true,
        ),
        isTrue);

    final items = index.playlistItems(pid);
    expect(items.length, 1);
    expect(items.single.sourceKey, 'local:Other');

    index.close();
  });

  test('删源前补发歌单条目 item_remove，且 source_id 仍可解析', () async {
    final index = await _openIndex();
    await index.upsertSource('webdav:NAS', 'webdav', 'NAS',
        jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final uuid = await index.ensureSourceUuid('webdav:NAS');
    final pid = await index.createPlaylist('p');
    await index.addPlaylistItem(pid,
        sourceKey: 'webdav:NAS',
        songRef: '/music/a.flac',
        title: 'A',
        source: 'webdav');
    final store = PlaylistStore(index, serverAvailable: () => true);

    await store.removeItemsOfSource('webdav:NAS');

    expect(index.playlistItems(pid), isEmpty);
    final removals = [
      for (final e in await index.pendingOutbox())
        if (e.type == SyncEventTypes.playlistItemRemove) e
    ];
    expect(removals.length, 1);
    expect(removals.single.payload['source_id'], uuid);

    index.close();
  });

  test('源实例 uuid：权重 / 歌单条目载荷携带 source_id', () async {
    final index = await _openIndex();
    await index.upsertSource('webdav:NAS', 'webdav', 'NAS',
        jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final uuid = await index.ensureSourceUuid('webdav:NAS');
    expect(index.sourceKeyOfUuid(uuid), 'webdav:NAS');
    expect(await index.ensureSourceUuid('webdav:NAS'), uuid); // 稳定不重生成

    final song = Song.direct(
      id: 1,
      sourceKey: 'webdav:NAS',
      title: 't',
      source: 'webdav',
      sourceRef: '/music/a.flac',
      fileSize: 1,
    );
    final weight = SongWeightStore(index, serverAvailable: () => true);
    await weight.setLiked(song);
    var payload = (await index.pendingOutbox()).last.payload;
    expect(payload['source_id'], uuid);
    expect(payload['source'], 'webdav');

    await index.deleteOutbox(
        (await index.pendingOutbox()).map((e) => e.eventUuid).toList());
    final playlists = PlaylistStore(index, serverAvailable: () => true);
    await playlists.create('p');
    await index.deleteOutbox(
        (await index.pendingOutbox()).map((e) => e.eventUuid).toList());
    final pid = index.listPlaylists().single.id;
    await playlists.addSong(pid, song);
    final last = (await index.pendingOutbox()).last;
    payload = last.payload;
    expect(last.type, SyncEventTypes.playlistItemAdd);
    expect(payload['source_id'], uuid);
    expect(payload['title'], 't');

    index.close();
  });

  test('源实例 uuid 落库映射：权重写本机源行、歌单条目按源 key 落库（无重复快照行）', () async {
    final index = await _openIndex();
    await index.upsertSource('webdav:NAS', 'webdav', 'NAS',
        jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final uuid = await index.ensureSourceUuid('webdav:NAS');

    // 权重快照：uuid 命中 → 写本机源 key，不再写 server 快照行。
    await index.applySongSnapshot(
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
    await index.applyPlaylistSnapshot(
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
    await index.applyPlaylistSnapshot(
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

  test('歌单同步保留封面：已有条目快照保留；本机索引封面可回填', () async {
    final index = await _openIndex();
    await index.upsertSource('webdav:NAS', 'webdav', 'NAS',
        jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final uuid = await index.ensureSourceUuid('webdav:NAS');

    await index.applyPlaylistSnapshot(
      uuid: 'puuid-cover',
      name: 'p',
      deleted: false,
      items: [
        SyncedItem(
            sourceId: uuid,
            source: 'webdav',
            songRef: '/music/a.flac',
            title: 'A',
            sortOrder: 1),
      ],
    );
    final pid = index.playlistIdOfUuid('puuid-cover')!;

    // 本机补齐条目封面快照（模拟本地已有封面）。
    await index.removePlaylistItem(pid, 'webdav:NAS', '/music/a.flac');
    await index.addPlaylistItem(pid,
        sourceKey: 'webdav:NAS',
        songRef: '/music/a.flac',
        title: 'A',
        coverPath: '/tmp/a.jpg',
        source: 'webdav');

    // 再次同步（服务端快照无封面）→ 保留本机封面快照。
    await index.applyPlaylistSnapshot(
      uuid: 'puuid-cover',
      name: 'p',
      deleted: false,
      items: [
        SyncedItem(
            sourceId: uuid,
            source: 'webdav',
            songRef: '/music/a.flac',
            title: 'A',
            sortOrder: 1),
      ],
    );
    expect(index.playlistItems(pid).single.coverPath, '/tmp/a.jpg');

    // 本机索引兜底：歌已扫描出封面，同步首次落库即回填。
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: 'webdav:NAS',
        ref: '/music/b.flac',
        title: 'B',
        titleFromMeta: true,
        format: 'flac',
        size: 1,
        mtime: 1,
        coverPath: '/tmp/b.jpg',
      ),
    ]);
    await index.applyPlaylistSnapshot(
      uuid: 'puuid-cover',
      name: 'p',
      deleted: false,
      items: [
        SyncedItem(
            sourceId: uuid,
            source: 'webdav',
            songRef: '/music/a.flac',
            title: 'A',
            sortOrder: 1),
        SyncedItem(
            sourceId: uuid,
            source: 'webdav',
            songRef: '/music/b.flac',
            title: 'B',
            sortOrder: 2),
      ],
    );
    final items = index.playlistItems(pid);
    expect(items.length, 2);
    expect(items[0].coverPath, '/tmp/a.jpg');
    expect(items[1].coverPath, '/tmp/b.jpg');

    index.close();
  });

  test('删源连带清理权重/歌词/缓存/设置项/深层列表/播放队列（其它源不受影响）', () async {
    final index = await _openIndex();
    const key = 'webdav:NAS';
    const other = 'local:Other';
    await index.upsertSource(
        key, 'webdav', 'NAS', jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    await index.upsertSongs([
      DirectSongRow(
          sourceKey: key, ref: '/music/a.flac', title: 'A', size: 8, mtime: 1),
      DirectSongRow(
          sourceKey: other, ref: '/music/b.flac', title: 'B', size: 8, mtime: 1),
    ]);
    // 权重/收藏 + 歌词：源删除后不可播，不能留成「查不到归属」的孤儿行。
    await index.upsertPlayMeta(key, '/music/a.flac',
        likeStreak: 3, favorite: true);
    await index.setLyrics(key, '/music/a.flac', '[00:01]hi');
    expect(index.playMetaOf(key, '/music/a.flac').favorite, isTrue);
    expect(index.lyricsOf(key, '/music/a.flac'), '[00:01]hi');
    // 离线缓存：原文件 + 转码变体各一行（都带 source_key），另一源一行做对照。
    await index.cacheSave('cacheA', List<int>.filled(4, 1),
        sourceKey: key, songRef: '/music/a.flac');
    await index.cacheSave('cacheA_v1', List<int>.filled(4, 1),
        sourceKey: key, songRef: '/music/a.flac', variantOf: 'cacheA');
    await index.cacheSave('cacheB', List<int>.filled(4, 1),
        sourceKey: other, songRef: '/music/b.flac');
    final cacheAFile = File(index.cachePathForKey('cacheA'));
    final cacheBFile = File(index.cachePathForKey('cacheB'));
    expect(cacheAFile.existsSync(), isTrue);
    // 按源 key 存的两类设置项（线路锁定 / 应用内建过的文件夹）。
    index.settingsSet(sourceLineSettingKey(key), 'fb0');
    index.settingsSet(sourceCreatedFoldersSettingKey(key), 'Inbox');
    index.settingsSet('unrelated_setting', 'keep');
    // 深层列表：混源栈（本源 + 其它源）与该源自身的浏览列表锚定。
    Song song(String sourceKey, String ref) => Song.direct(
          id: 1,
          sourceKey: sourceKey,
          title: ref,
          source: sourceKey.split(':').first,
          sourceRef: ref,
          fileSize: 8,
        );
    final a = song(key, '/music/a.flac');
    final a2 = song(key, '/music/a2.flac');
    final b = song(other, '/music/b.flac');
    await index.saveDeepList(
        'playlist:p-1', jsonEncode([a.toJson(), b.toJson()]));
    await index.saveDeepList('source:$key', jsonEncode([a.toJson()]));
    // 播放队列：A(本源) / B(其它源) / A2(本源)，当前停在第 0 位（本源歌）。
    await index.savePlayState(
        jsonEncode([a.toJson(), b.toJson(), a2.toJson()]), 0, 1000,
        anchorKey: 'source:$key');

    await index.deleteSource(key);

    expect(index.getSource(key), isNull);
    expect(index.songByRef(key, '/music/a.flac'), isNull);
    expect(index.scanFingerprint(key), isEmpty);
    expect(index.playMetaOf(key, '/music/a.flac').favorite, isFalse,
        reason: '权重/收藏行应随源删除');
    expect(index.playMetaOf(key, '/music/a.flac').likeStreak, 0);
    expect(index.lyricsOf(key, '/music/a.flac'), isNull, reason: '歌词行应随源删除');
    // 缓存：本源两行（含变体）一起清，文件也真删掉；其它源原样保留。
    final leftCache = index.listCache();
    expect(leftCache.where((c) => c.sourceKey == key), isEmpty);
    expect(cacheAFile.existsSync(), isFalse);
    expect(leftCache.where((c) => c.sourceKey == other).length, 1);
    expect(cacheBFile.existsSync(), isTrue);
    // 设置项：本源两项清掉，无关设置保留。
    expect(index.settingsGet(sourceLineSettingKey(key)), isNull);
    expect(index.settingsGet(sourceCreatedFoldersSettingKey(key)), isNull);
    await index.flushWrites();
    expect(index.settingsAll().containsKey(sourceLineSettingKey(key)), isFalse);
    expect(index.settingsGet('unrelated_setting'), 'keep');
    // 深层列表：混源栈只剩其它源那首；本源浏览列表锚定整行删除。
    final playlistStack = index.loadDeepList('playlist:p-1');
    expect(playlistStack, isNotNull);
    final entries = jsonDecode(playlistStack!) as List;
    expect(entries.length, 1);
    expect((entries.single as Map)['sourceKey'], other);
    expect(index.loadDeepList('source:$key'), isNull);
    // 播放队列：本源两首剔除，下标落到还活着的 B，锚定（本源浏览列表）作废。
    final state = index.getPlayState();
    expect(state, isNotNull);
    final queue = jsonDecode(state!.queueJson) as List;
    expect(queue.length, 1);
    expect((queue.single as Map)['sourceKey'], other);
    expect(state.idx, 0);
    expect(state.anchorKey, isNull);

    index.close();
  });

  test('删源把队列/深层列表剔空时整行删除（无断点、无空历史）', () async {
    final index = await _openIndex();
    const key = 'webdav:NAS';
    await index.upsertSource(
        key, 'webdav', 'NAS', jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final a = Song.direct(
      id: 1,
      sourceKey: key,
      title: 'A',
      source: 'webdav',
      sourceRef: '/music/a.flac',
      fileSize: 8,
    );
    await index.saveDeepList('liked', jsonEncode([a.toJson()]));
    await index.savePlayState(jsonEncode([a.toJson()]), 0, 500);

    await index.deleteSource(key);

    expect(index.loadDeepList('liked'), isNull, reason: '剔空的深层历史无意义');
    expect(index.getPlayState(), isNull, reason: '队列剔空等价于无断点');

    index.close();
  });

  test('同步墓碑删源同样清缓存与按源设置项（其它设备删源的路径）', () async {
    final index = await _openIndex();
    const key = 'webdav:NAS';
    await index.upsertSource(
        key, 'webdav', 'NAS', jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
    final uuid = await index.ensureSourceUuid(key);
    await index.cacheSave('cacheA', List<int>.filled(4, 1),
        sourceKey: key, songRef: '/music/a.flac');
    index.settingsSet(sourceLineSettingKey(key), 'primary');
    final file = File(index.cachePathForKey('cacheA'));
    expect(file.existsSync(), isTrue);

    expect(
        await index.applySourceSnapshot(
          uuid: uuid,
          kind: 'webdav',
          name: null,
          address: _addr,
          config: null,
          enabled: true,
          deleted: true,
        ),
        isTrue);

    expect(index.getSource(key), isNull);
    expect(index.listCache().where((c) => c.sourceKey == key), isEmpty);
    expect(file.existsSync(), isFalse);
    expect(index.settingsGet(sourceLineSettingKey(key)), isNull);

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
