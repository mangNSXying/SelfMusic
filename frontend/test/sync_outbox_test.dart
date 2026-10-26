import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/playlist_store.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/play_progress.dart';
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

    expect(await index.pendingOutboxCount(), 0);
    final u1 = await index.enqueueOutbox(SyncEventTypes.songLiked,
        {'source': 'webdav', 'source_ref': 'a/b.flac'});
    final u2 = await index.enqueueOutbox(SyncEventTypes.playlistItemAdd,
        {'playlist_uuid': 'p1', 'source': 'local', 'source_ref': 'c.mp3'});
    expect(u1, isNotEmpty);
    expect(u1, isNot(equals(u2)));
    expect(await index.pendingOutboxCount(), 2);

    final pending = await index.pendingOutbox();
    expect(pending.map((e) => e.eventUuid), containsAll([u1, u2]));
    expect(pending.firstWhere((e) => e.eventUuid == u1).type,
        SyncEventTypes.songLiked);
    final payload = pending.firstWhere((e) => e.eventUuid == u1).payload;
    expect(payload['source_ref'], 'a/b.flac');

    // 服务端接受 → 删队
    await index.deleteOutbox([u1]);
    expect(await index.pendingOutboxCount(), 1);

    // 服务端拒绝 → 死信，不再出现在待推里
    await index.deadLetterOutbox([u2]);
    expect(await index.pendingOutboxCount(), 0);
    expect(await index.pendingOutbox(), isEmpty);

    index.close();
  });

  test('歌单 uuid：新建即带；重复 ensure 不再生', () async {
    final index = await _openIndex();

    final id = await index.createPlaylist('测试');
    final uuid = index.playlistUuidOf(id);
    expect(uuid, isNotNull);
    expect(uuid, isNotEmpty);
    // 已有 uuid 的行：ensure 直接返回，不再生
    expect(await index.ensurePlaylistUuid(id), uuid);
    expect(index.playlistUuidOf(id), uuid);

    index.close();
  });

  test('pull 歌单快照：新增 / 更新 / 墓碑删除；保留本地直连条目', () async {
    final index = await _openIndex();

    // 新增（含服务端条目）
    await index.applyPlaylistSnapshot(
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
    await index.addPlaylistItem(pid,
        sourceKey: 'webdav:NAS',
        songRef: 'local/z.mp3',
        title: '本地歌',
        source: 'webdav');
    await index.applyPlaylistSnapshot(
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
    await index.applyPlaylistSnapshot(
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

    await index.applySongSnapshot(
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

    await index.upsertBreakpointMirror(
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

  test('断点同步 base 持久化 + force 合并快照绕过镜像时钟', () async {
    final index = await _openIndex();
    final id = await index.createPlaylist('base 歌单');
    final uuid = index.playlistUuidOf(id)!;

    await index.setBreakpointBaseDeepList(
        uuid, '[{"source":"webdav","source_ref":"/a.mp3"}]');
    expect(index.breakpointBaseDeepList(uuid), contains('/a.mp3'));

    // 普通镜像：较新者落库；base 不跟镜像走（由播放器采用历史时显式推进）。
    await index.applyPlaystateMirror({
      'client_uuid': uuid,
      'source': 'webdav',
      'source_ref': '/b.mp3',
      'position_ms': 1000,
      'updated_at': '2026-10-01T00:00:00',
      'last_event_at': '2026-10-01T00:00:00',
      'deep_list': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
        {'source': 'webdav', 'source_ref': '/b.mp3'},
      ],
    });
    expect(index.breakpointMirrorOf(uuid)!.sourceRef, '/b.mp3');
    expect(index.breakpointBaseDeepList(uuid), contains('/a.mp3'));
    expect(index.breakpointBaseDeepList(uuid), isNot(contains('/b.mp3')));

    // force：即使 last_event_at 更旧也写入（push merged 回执含对端分支）。
    await index.applyPlaystateMirror({
      'client_uuid': uuid,
      'source': 'webdav',
      'source_ref': '/c.mp3',
      'position_ms': 2000,
      'updated_at': '2026-01-01T00:00:00',
      'last_event_at': '2026-01-01T00:00:00',
      'deep_list': [
        {'source': 'webdav', 'source_ref': '/a.mp3'},
        {'source': 'webdav', 'source_ref': '/c.mp3'},
      ],
    }, force: true);
    expect(index.breakpointMirrorOf(uuid)!.sourceRef, '/c.mp3');
    expect(index.breakpointBaseDeepList(uuid), contains('/a.mp3'));
    expect(index.breakpointBaseDeepList(uuid), isNot(contains('/c.mp3')));

    // 播放器真正采用某份历史后才显式推进 base。
    await index.setBreakpointBaseDeepList(
        uuid, '[{"source":"webdav","source_ref":"/c.mp3"}]');
    expect(index.breakpointBaseDeepList(uuid), contains('/c.mp3'));

    index.close();
  });

  test('pull 歌曲快照带 play_sec；累计值只增不减（单调量不被旧值覆盖）', () async {
    final index = await _openIndex();

    await index.applySongSnapshot(
      songRef: 'st/x.flac',
      source: 'webdav',
      likeStreak: 0,
      dislikeStreak: 0,
      factor: 1.0,
      frozen: false,
      favorite: false,
      playSec: 600,
    );
    expect(index.playMetaOf('server', 'st/x.flac').playSec, 600);

    // 更小的服务端值（别的设备没听过）不覆盖本地累计
    await index.applySongSnapshot(
      songRef: 'st/x.flac',
      likeStreak: 0,
      dislikeStreak: 0,
      factor: 1.0,
      frozen: false,
      favorite: false,
      playSec: 120,
    );
    expect(index.playMetaOf('server', 'st/x.flac').playSec, 600);

    // 更大的值正常覆盖
    await index.applySongSnapshot(
      songRef: 'st/x.flac',
      likeStreak: 0,
      dislikeStreak: 0,
      factor: 1.0,
      frozen: false,
      favorite: false,
      playSec: 900,
    );
    expect(index.playMetaOf('server', 'st/x.flac').playSec, 900);

    // 老服务端快照无 play_sec（null）→ 本地值保持
    await index.applySongSnapshot(
      songRef: 'st/x.flac',
      likeStreak: 1,
      dislikeStreak: 0,
      factor: 1.0,
      frozen: false,
      favorite: false,
    );
    final m = index.playMetaOf('server', 'st/x.flac');
    expect(m.playSec, 900);
    expect(m.likeStreak, 1);

    index.close();
  });

  test('AppSettings 同步三键：默认值、持久化、白名单', () async {    final index = await _openIndex();
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

  Song directSong() => Song.direct(
        id: 1,
        sourceKey: 'webdav:NAS',
        title: '直连歌',
        artist: 'A',
        albumName: 'B',
        source: 'webdav',
        sourceRef: '/music/z.mp3',
        fileSize: 100,
      );

  Song serverSong() => Song.direct(
        id: 2,
        sourceKey: 'server',
        title: '服务歌',
        source: 'webdav',
        sourceRef: '/music/s.mp3',
        fileSize: 200,
      );

  test('权重埋点：服务器歌恒进队；直连歌需连着服务器', () async {
    // 未注门控：服务器歌进，直连歌不进
    var index = await _openIndex();
    var weight = SongWeightStore(index);
    await weight.setLiked(serverSong());
    expect(await index.pendingOutboxCount(), 1);
    await weight.setLiked(directSong());
    expect(await index.pendingOutboxCount(), 1);
    index.close();

    // 门控开：直连歌进队，载荷带身份
    index = await _openIndex();
    weight = SongWeightStore(index, serverAvailable: () => true);
    await weight.onSkipped(directSong());
    expect(await index.pendingOutboxCount(), 1);
    final single = (await index.pendingOutbox()).single;
    final payload = single.payload;
    expect(single.type, SyncEventTypes.songSkipped);
    expect(payload['source'], 'webdav');
    expect(payload['source_ref'], '/music/z.mp3');
    index.close();

    // 门控关：直连歌不进队（避免未配对用户积压）
    index = await _openIndex();
    weight = SongWeightStore(index, serverAvailable: () => false);
    await weight.setLiked(directSong());
    expect(await index.pendingOutboxCount(), 0);
    index.close();
  });

  test('歌单条目埋点：直连歌随门控进队，载荷带标题', () async {
    var index = await _openIndex();
    var store = PlaylistStore(index, serverAvailable: () => true);
    final pid = await store.create('单');
    expect(await index.pendingOutboxCount(), 1); // create 恒进
    await store.addSong(pid, directSong());
    expect(await index.pendingOutboxCount(), 2);
    final payload = (await index.pendingOutbox()).last.payload;
    expect(payload['source'], 'webdav');
    expect(payload['source_ref'], '/music/z.mp3');
    expect(payload['title'], '直连歌');
    index.close();

    index = await _openIndex();
    store = PlaylistStore(index, serverAvailable: () => false);
    final pid2 = await store.create('单');
    await store.addSong(pid2, directSong());
    // 只有 create，条目未进
    expect(await index.pendingOutboxCount(), 1);
    index.close();
  });

  test('pull 歌曲快照：按源协议回写直连行 play_meta', () async {    final index = await _openIndex();
    await index.upsertSongs([
      DirectSongRow(
          sourceKey: 'webdav:NAS',
          ref: '/music/z.mp3',
          title: '直连歌',
          size: 100,
          mtime: 1),
      DirectSongRow(
          sourceKey: 'local:Disk',
          ref: '/music/z.mp3',
          title: '同名本地歌',
          size: 100,
          mtime: 1),
    ]);

    await index.applySongSnapshot(
      songRef: '/music/z.mp3',
      source: 'webdav',
      likeStreak: 3,
      dislikeStreak: 0,
      factor: 1.5,
      frozen: false,
      favorite: true,
    );

    // 服务端行（旧行为保留）+ 同协议直连行落库
    expect(index.playMetaOf('server', '/music/z.mp3').favorite, isTrue);
    final direct = index.playMetaOf('webdav:NAS', '/music/z.mp3');
    expect(direct.favorite, isTrue);
    expect(direct.factor, 1.5);
    expect(direct.likeStreak, 3);
    // 不同协议的同名行不受影响
    expect(index.playMetaOf('local:Disk', '/music/z.mp3').favorite, isFalse);

    index.close();
  });

  test('信息汇总：metaStats/formatStats 口径', () async {
    final index = await _openIndex();
    await index.upsertSongs([
      DirectSongRow(
          sourceKey: 'webdav:NAS',
          ref: '/music/full.mp3',
          title: '全',
          artist: 'A',
          album: 'B',
          albumArtist: 'AA',
          trackNo: 1,
          year: 2020,
          genre: 'Rock',
          duration: 200,
          format: 'mp3',
          size: 1000,
          mtime: 1),
      DirectSongRow(
          sourceKey: 'webdav:NAS',
          ref: '/music/bare.flac',
          title: '秃',
          size: 500,
          mtime: 1),
    ]);
    await index.setLyrics('webdav:NAS', '/music/full.mp3', '[00:01] la');
    await index.enrichSong('webdav:NAS', '/music/full.mp3');

    final stats = index.metaStats();
    expect(stats['total'], 2);
    expect(stats['missing'], 0);
    expect(stats['meta_read'], 1);
    expect(stats['artist'], 1);
    expect(stats['album'], 1);
    expect(stats['lyrics'], 1);
    expect(stats['duration'], 1);
    expect(stats['cover'], 0);
    expect(stats['bitrate'], 1); // 仅 full 行大小+时长齐全

    final formats = index.formatStats();
    expect(formats['mp3'], 1);
    expect(formats['未知'], 1); // bare 行 format 为空

    index.close();
  });

  test('进度事件载荷：complete/skip 带 pct，独立样本走 song.progress', () async {
    final index = await _openIndex();
    final weight = SongWeightStore(index, serverAvailable: () => true);

    await weight.onCompleted(directSong(), progressPct: 100);
    var pending = await index.pendingOutbox();
    expect(pending.last.type, SyncEventTypes.songComplete);
    expect(pending.last.payload['progress_pct'], 100);

    await weight.onSkipped(directSong(), progressPct: 20);
    pending = await index.pendingOutbox();
    expect(pending.last.type, SyncEventTypes.songSkipped);
    expect(pending.last.payload['progress_pct'], 20);

    await weight.recordProgress(directSong(), 42);
    pending = await index.pendingOutbox();
    expect(pending.last.type, SyncEventTypes.songProgress);
    expect(pending.last.payload['progress_pct'], 42);

    await weight.onCompletedManual(directSong(), tracked: true);
    pending = await index.pendingOutbox();
    expect(pending.last.type, SyncEventTypes.songCompleteManual);
    expect(pending.last.payload['tracked'], true);
    expect(pending.last.payload.containsKey('progress_pct'), isFalse);

    index.close();
  });

  test('补推基线；快照直方图按桶 max 合并且缺字段不覆盖', () async {
    final index = await _openIndex();
    await index.upsertSource('webdav:NAS', 'webdav', 'NAS', '{}');
    await index.recordProgress('webdav:NAS', '/music/z.mp3', 80);
    expect(await index.pendingOutboxCount(), 0);

    final weight = SongWeightStore(index, serverAvailable: () => true);
    expect(await weight.backfill(), 1);
    final pending = await index.pendingOutbox();
    final baseline = pending
        .firstWhere((e) => e.type == SyncEventTypes.songProgress);
    expect(baseline.payload['baseline'], true);
    final baselineHist = baseline.payload['progress_hist'] as List;
    expect(baselineHist.length, 101);
    expect(baselineHist[80], 1);

    List<int> histWith(Map<int, int> buckets) {
      final out = List<int>.filled(101, 0);
      buckets.forEach((k, v) => out[k] = v);
      return out;
    }

    Future<void> snapshot(List<int>? hist) => index.applySongSnapshotRaw({
          'source_ref': '/music/snap.mp3',
          'source': 'webdav',
          'like_streak': 0,
          'dislike_streak': 0,
          'weight': 1.0,
          'frozen': false,
          'is_favorite': false,
          'play_sec': 0,
          if (hist != null) 'progress_hist': hist,
        });

    await snapshot(histWith({80: 1, 100: 1}));
    var merged = PlayProgressHistogram.fromJson(
        index.playMetaOf('server', '/music/snap.mp3').progressHist);
    expect(merged.total, 2);

    await snapshot(histWith({80: 3, 100: 1}));
    merged = PlayProgressHistogram.fromJson(
        index.playMetaOf('server', '/music/snap.mp3').progressHist);
    expect(merged.total, 4);
    expect(merged.toList()[80], 3);
    expect(merged.toList()[100], 1);

    // 老服务端/空字段不覆盖本地直方图
    await snapshot(null);
    merged = PlayProgressHistogram.fromJson(
        index.playMetaOf('server', '/music/snap.mp3').progressHist);
    expect(merged.total, 4);

    index.close();
  });
}
