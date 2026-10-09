import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/playlist_store.dart';
import 'package:selfmusic/providers/playlists_provider.dart';
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
  final dir = await Directory.systemTemp.createTemp('selfmusic_plincref_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

void main() {
  test('增量 refresh：只重查变更歌单计数，其余沿用缓存；全量 refresh 兜底', () async {
    final index = await _openIndex();
    final store = PlaylistStore(index, serverAvailable: () => false);
    final id1 = await store.create('p1');
    final id2 = await store.create('p2');
    final provider = PlaylistsProvider(store);

    provider.refresh();
    expect(provider.countOf(id1), 0);
    expect(provider.countOf(id2), 0);

    // 旁路直写（模拟同步落库）：provider 未感知，计数缓存保持旧值。
    final pid1 = index.playlistIdOfUuid(index.playlistUuidOf(id1)!)!;
    await index.addPlaylistItem(pid1,
        sourceKey: 'webdav:NAS', songRef: 'a.mp3', title: 'A');
    provider.refresh(changedUuids: const {'不存在的-uuid'});
    expect(provider.countOf(id1), 0, reason: '未在变更集合 → 沿用缓存，不重查');

    // 明确变更 → 只对该歌单重查。
    provider.refresh(changedUuids: {index.playlistUuidOf(id1)!});
    expect(provider.countOf(id1), 1);
    expect(provider.countOf(id2), 0);

    // 再来一条旁路写 + 全量 refresh 兜底（changedUuids 为空 = 全量语义）。
    await index.addPlaylistItem(pid1,
        sourceKey: 'webdav:NAS', songRef: 'b.mp3', title: 'B');
    provider.refresh();
    expect(provider.countOf(id1), 2);
    expect(provider.countOf(id2), 0);

    index.close();
  });
}
