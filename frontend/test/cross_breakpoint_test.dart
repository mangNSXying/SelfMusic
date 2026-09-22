import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
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
  final dir = await Directory.systemTemp.createTemp('selfmusic_xbp_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

void main() {
  test('运行时断点带歌单归属：save/get roundtrip（通用队列为 null）', () async {
    final index = await _openIndex();
    index.savePlayState(
      jsonEncode([
        {'sourceKey': 'webdav:NAS', 'title': 'a', 'source': 'webdav', 'sourceRef': '/x/a.flac'}
      ]),
      0,
      83000,
      playlistUuid: 'puuid-1',
    );
    var st = index.getPlayState()!;
    expect(st.positionMs, 83000);
    expect(st.playlistUuid, 'puuid-1');

    index.savePlayState('[]', 0, 0);
    st = index.getPlayState()!;
    expect(st.playlistUuid, isNull);
    index.close();
  });

  test('playlistSongs：按 sort_order 重建可播放队列；镜像全量可读', () async {
    final index = await _openIndex();
    index.createPlaylist('p');
    final pid = index.listPlaylists().single.id;
    index.addPlaylistItem(pid,
        sourceKey: 'server',
        songRef: '/x/a.flac',
        title: 'A',
        source: 'webdav');
    index.addPlaylistItem(pid,
        sourceKey: 'webdav:NAS',
        songRef: '/x/b.flac',
        title: 'B',
        artist: 'ar',
        source: 'webdav');

    final songs = index.playlistSongs(pid);
    expect(songs.map((s) => s.title), ['A', 'B']);
    expect(songs.first.sourceKey, 'server');
    expect(songs.last.sourceKey, 'webdav:NAS');

    index.upsertBreakpointMirror(
      playlistUuid: 'puuid-1',
      songId: null,
      sourceId: 'u1',
      source: 'webdav',
      sourceRef: '/x/b.flac',
      positionMs: 5000,
      updatedAt: '2026-09-23T10:00:00',
      deviceId: 'dev-2',
    );
    final all = index.allBreakpointMirrors();
    expect(all.length, 1);
    expect(all.single.sourceId, 'u1');
    expect(all.single.sourceRef, '/x/b.flac');
    expect(all.single.deviceId, 'dev-2');
    index.close();
  });
}
