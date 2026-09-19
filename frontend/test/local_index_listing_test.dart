import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
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

  test('旧 ENCODE 收藏行被新解码 ref 继承并合并（取消喜欢不残留）', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxfav_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    const decodedRef = '/dav/佐藤しずく - Growing!.flac';
    const encodedRef =
        '/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing%21.flac';
    index.upsertSongs([
      DirectSongRow(
        sourceKey: 'webdav:nas',
        ref: decodedRef,
        title: 'Growing!',
        artist: '佐藤しずく',
        album: '',
        duration: 200,
        format: 'flac',
        size: 1024,
        mtime: 1,
      ),
    ]);
    // 模拟历史版本写入的 ENCODE 收藏行（无歌曲快照）。
    index.upsertPlayMeta('webdav:nas', encodedRef, favorite: true);

    // 读侧：新 ref 能看到旧收藏态。
    expect(index.playMetaOf('webdav:nas', decodedRef).favorite, isTrue);
    // 喜欢列表：经回查补全出歌曲。
    final liked = index.likedSongs();
    expect(liked.length, 1);
    expect(liked.first.title, 'Growing!');

    // 写侧：取消喜欢后旧行被合并，不再残留。
    index.setFavorite('webdav:nas', decodedRef, false);
    expect(index.likedSongs(), isEmpty);
    expect(index.playMetaOf('webdav:nas', decodedRef).favorite, isFalse);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('不喜欢锁定最低权重：可取消、跳过自动调权、喜欢可解冻', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxdis_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final weight = SongWeightStore(index);
    final song = Song.direct(
      id: 1,
      sourceKey: 'webdav:nas',
      title: 'Growing!',
      source: 'webdav',
      sourceRef: '/dav/a.flac',
      fileSize: 1024,
    );

    // 标记不喜欢 → 权重最低并锁定。
    weight.setDisliked(song, true);
    expect(weight.isDisliked(song), isTrue);
    expect(weight.factorOf(song), SongWeightStore.minFactor);
    // 锁定后跳过/播完只记 streak，不调权重。
    weight.onSkipped(song);
    weight.onSkipped(song);
    weight.onSkipped(song);
    expect(weight.factorOf(song), SongWeightStore.minFactor);
    expect(weight.isDisliked(song), isTrue);

    // 再次点击取消 → 解锁回 1.0。
    weight.setDisliked(song, false);
    expect(weight.isDisliked(song), isFalse);
    expect(weight.factorOf(song), SongWeightStore.defaultFactor);

    // 喜欢可解冻：先锁再喜欢 → 解锁且 factor 拉满。
    weight.setDisliked(song, true);
    weight.setLiked(song);
    expect(weight.isDisliked(song), isFalse);
    expect(weight.factorOf(song), SongWeightStore.maxFactor);

    index.close();
    dir.deleteSync(recursive: true);
  });
}