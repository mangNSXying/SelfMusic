import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/playlist_store.dart';
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

Song _song(String ref) => Song.direct(
      id: 1,
      sourceKey: 'webdav:nas',
      title: '歌',
      artist: '歌手',
      source: 'webdav',
      sourceRef: ref,
      fileSize: 0,
      format: 'mp3',
    );

void main() {
  test('歌单归属查询与切换：toggle、多歌单、历史 ref 变体', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_plmem_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final store = PlaylistStore(index);

    final idA = await store.create('A');
    final idB = await store.create('B');
    final song = _song('/dav/中文 名.mp3');

    expect(store.containingPlaylists(song), isEmpty);

    await store.addSong(idA, song);
    expect(store.contains(idA, song), isTrue);
    expect(store.contains(idB, song), isFalse);
    expect(store.containingPlaylists(song), {idA});

    expect(await store.toggleSong(idA, song), isFalse); // 已加入 → 移出
    expect(store.contains(idA, song), isFalse);
    expect(await store.toggleSong(idA, song), isTrue); // 未加入 → 加入
    expect(store.contains(idA, song), isTrue);

    // 多歌单归属一次查全。
    await store.addSong(idB, song);
    expect(store.containingPlaylists(song), {idA, idB});

    // 历史 ENCODE 入库的 ref：用解码 ref 也能查到并移除。
    final idC = await store.create('C');
    await index.addPlaylistItem(idC,
        sourceKey: 'webdav:nas',
        songRef: '/dav/%E4%B8%AD%E6%96%87%20%E5%90%8D.mp3',
        title: '歌');
    expect(store.contains(idC, song), isTrue);
    expect(store.containingPlaylists(song), {idA, idB, idC});
    await store.removeSong(idC, song);
    expect(store.contains(idC, song), isFalse);
    expect(index.playlistItems(idC), isEmpty);

    index.close();
    dir.deleteSync(recursive: true);
  });
}
