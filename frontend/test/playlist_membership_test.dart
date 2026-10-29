import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/playlist_store.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
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

  test('批量加入歌单：追加顺序、重复跳过、item_add 顺序一致', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_plbatch_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final store = PlaylistStore(index, serverAvailable: () => true);

    final id = await store.create('批量');
    Song song(String ref, String title) => Song.direct(
          id: 1,
          sourceKey: 'local:test',
          title: title,
          artist: '歌手',
          source: 'local',
          sourceRef: ref,
          fileSize: 0,
        );
    final a = song('a', 'A');
    final b = song('b', 'B');
    final c = song('c', 'C');

    // 先放一首 B，批量里再带一次 B：冲突行跳过、不产生事件。
    await store.addSong(id, b);
    final before = await index.pendingOutbox();
    final addsBefore =
        before.where((e) => e.type == SyncEventTypes.playlistItemAdd).length;

    expect(await store.addSongs(id, [a, b, c]), 2);
    final rows = index.playlistItems(id);
    expect([for (final r in rows) r.title], ['B', 'A', 'C']);
    expect([for (final r in rows) r.sortOrder], [1, 2, 3]);

    final adds = (await index.pendingOutbox())
        .where((e) => e.type == SyncEventTypes.playlistItemAdd)
        .toList();
    expect(adds.length, addsBefore + 2);
    expect(adds[adds.length - 2].payload['sort_order'], 2);
    expect(adds.last.payload['sort_order'], 3);

    // 再整批加一次：全部已在歌单 → 0 条新增、无新事件。
    final outboxSize = (await index.pendingOutbox()).length;
    expect(await store.addSongs(id, [a, c]), 0);
    expect((await index.pendingOutbox()).length, outboxSize);

    index.close();
    dir.deleteSync(recursive: true);
  });
}
