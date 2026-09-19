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

void main() {
  test('源列表不再截断：size 缺省返回全部歌曲（回归 200 上限）', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxlim_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    final rows = <DirectSongRow>[
      for (var i = 0; i < 250; i++)
        DirectSongRow(
          sourceKey: 'local:test',
          ref: 'song_$i',
          title: '歌曲 $i',
          artist: '歌手 ${i % 5}',
          album: '专辑',
          duration: 100,
          format: 'mp3',
          size: 1024,
          mtime: i,
        ),
    ];
    index.upsertSongs(rows);

    // 全部返回（不限 200）
    expect(index.searchSongs(sourceKey: 'local:test').length, 250);
    expect(index.countSongs('local:test'), 250);

    // 分页仍可用
    expect(index.searchSongs(sourceKey: 'local:test', size: 100).length, 100);

    index.close();
    dir.deleteSync(recursive: true);
  });
}