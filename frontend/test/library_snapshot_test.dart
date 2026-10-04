import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/models/album.dart';
import 'package:selfmusic/models/artist.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/off_thread.dart';
import 'package:sqlite3/open.dart';

/// 启动聚焦的读写分离回归（UI 卡顿治理）：
/// `librarySnapshotInBackground` 在后台 isolate 另开连接读库并完成分组，
/// 结果必须与主连接的同步查询完全一致（同一份 SQL/映射/分组逻辑）。

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

DirectSongRow _song(String ref, String artist, {String? album}) =>
    DirectSongRow(
      sourceKey: 'local:test',
      ref: ref,
      title: '标题 $ref',
      artist: artist,
      album: album ?? '专辑',
      duration: 100,
      format: 'mp3',
      size: 1024,
      mtime: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('后台快照：歌曲/专辑/歌手与同步查询完全一致', () async {
    // 本用例专测后台 isolate 路径：测试环境默认内联（见 off_thread.dart），
    // 这里强制走真实 Isolate.run。
    forceOffThreadIsolateInTests = true;
    addTearDown(() => forceOffThreadIsolateInTests = false);
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_snap_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    try {
      await index.upsertSongs([
        _song('a', '组合X', album: '专辑一'),
        _song('b', '组合X', album: '专辑一'),
        _song('c', '组合X', album: '专辑二'),
        _song('d', '独唱Y', album: '专辑三'),
      ]);
      await index.reconcileArtists();
      // 组合→角色→声优：确保歌手分组带身份数据（二级祖先计数）。
      final group = index.artistRowByCanonical('组合X')!;
      await index.artistUpsert(
        artistKey: group.artistKey,
        canonicalKey: group.canonicalKey,
        mbid: 'gx',
        displayName: '组合X',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );
      await index.artistSetMembers(artistKey: group.artistKey, members: [
        {
          'mbid': 'cx',
          'name': '角色X',
          'type': 'character',
          'relation': 'member of band',
        },
      ]);
      final ch = index.artistRowByMbid('cx')!;
      await index.artistSetMembers(artistKey: ch.artistKey, members: [
        {
          'mbid': 'px',
          'name': '声优X',
          'type': 'person',
          'relation': 'voice actor',
        },
      ]);

      final snap = await index.librarySnapshotInBackground(
          sourceKeys: ['local:test']);

      final syncSongs = index.searchSongs(sourceKey: 'local:test');
      String key(Song s) => '${s.sourceKey}:${s.sourceRef}';
      expect(snap.songs.map(key), syncSongs.map(key));
      expect(snap.albums.map((a) => '${a.artist}\u0000${a.album}'),
          Album.fromSongs(syncSongs).map((a) => '${a.artist}\u0000${a.album}'));

      final syncArtists = [
        ...index.identityArtistGroups(),
        ...index.identityFallbackGroups(),
      ];
      String label(Artist a) => '${a.name}/${a.songCount}/${a.albumCount}';
      expect(snap.artists.map(label), syncArtists.map(label));

      // 只刷歌手的后台路径也同口径。
      final artists =
          await index.artistGroupsInBackground();
      expect(artists.map(label), syncArtists.map(label));
    } finally {
      index.close();
      for (var i = 0; i < 20; i++) {
        try {
          if (!dir.existsSync()) break;
          dir.deleteSync(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
        }
      }
    }
  });
}
