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

Song _song(String sourceKey, String ref) => Song(
      id: 0,
      sourceKey: sourceKey,
      title: ref,
      source: 'webdav',
      sourceRef: ref,
      fileSize: 0,
    );

void main() {
  test('批量权重/时长读取与逐首一致；行缓存经失效后反映外部写入', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_wbatch_');
    // Windows 下写连接可能仍占用库文件，删不掉就留给系统临时目录。
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final weight = SongWeightStore(index);

    final songs = [
      for (var i = 0; i < 6; i++)
        _song('webdav:${i % 2 == 0 ? 'a' : 'b'}', 'r$i'),
    ];
    await weight.setLiked(songs[0]);
    await weight.setDisliked(songs[2], true);
    await index.addPlaySec('webdav:a', 'r4', 42);

    final keys = weight.sortKeysOf(songs, factors: true, playSecs: true);
    for (final s in songs) {
      expect(keys.factorOf(s), weight.factorOf(s), reason: s.sourceRef);
      expect(keys.playSecOf(s), weight.playSecOf(s), reason: s.sourceRef);
    }
    // 批量值与真实状态对得上（喜欢 → 1.5；不喜欢 → 0.5；累计播放时长）。
    expect(keys.factorOf(songs[0]), 1.5);
    expect(keys.factorOf(songs[2]), 0.5);
    expect(keys.playSecOf(songs[4]), 42);
    // 只取需要的键时不触发另一类查询（返回空 map，默认值兜底）。
    final onlyFactors = weight.sortKeysOf(songs, factors: true);
    expect(onlyFactors.factorOf(songs[0]), 1.5);
    expect(onlyFactors.playSecOf(songs[4]), 0);

    // 行缓存命中：直接改库（模拟同步引擎落库）不自动可见，显式失效后可见。
    await index.setFavorite('webdav:a', 'r0', false);
    expect(weight.metaOf(songs[0]).favorite, isTrue);
    weight.notifyExternalWrite();
    expect(weight.metaOf(songs[0]).favorite, isFalse);

    index.close();
  });

  test('playMetasOf 分组批量读整行：与逐首口径一致，未命中不返回', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_wbatch2_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final weight = SongWeightStore(index);

    final songs = [
      for (var i = 0; i < 6; i++)
        _song('webdav:${i % 2 == 0 ? 'a' : 'b'}', 'r$i'),
    ];
    await weight.setLiked(songs[0]);
    await weight.setDisliked(songs[2], true);
    await index.addPlaySec('webdav:a', 'r4', 42);

    final a = index.playMetasOf('webdav:a', ['r0', 'r4', 'nope']);
    expect(a['r0']!.favorite, isTrue);
    expect(a['r0']!.factor, 1.5);
    expect(a['r4']!.playSec, 42);
    expect(a.containsKey('nope'), isFalse);
    final frozenRow = index.playMetasOf('webdav:a', ['r2']);
    expect(frozenRow['r2']!.frozen, isTrue);

    // 批量值与逐首读口径一致（未匹配行在批量里是缺失，逐首为默认行）。
    for (final s in songs) {
      final row = index.playMetasOf(s.sourceKey, [s.sourceRef])[s.sourceRef];
      final single = index.playMetaOf(s.sourceKey, s.sourceRef);
      expect(row?.favorite ?? false, single.favorite, reason: s.sourceRef);
      expect(row?.frozen ?? false, single.frozen, reason: s.sourceRef);
      expect(row?.factor ?? 1.0, single.factor, reason: s.sourceRef);
    }

    index.close();
  });

  test('warmMetaOf 批量预热行缓存：metaOf 命中且与真实状态一致；失效仍生效', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_warm_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final weight = SongWeightStore(index);

    final songs = [
      for (var i = 0; i < 6; i++)
        _song('webdav:${i % 2 == 0 ? 'a' : 'b'}', 'r$i'),
    ];
    await weight.setLiked(songs[0]);
    await weight.setDisliked(songs[2], true);
    await index.addPlaySec('webdav:a', 'r4', 42);

    await weight.warmMetaOf(songs);
    for (final s in songs) {
      final meta = weight.metaOf(s);
      final single = index.playMetaOf(s.sourceKey, s.sourceRef);
      expect(meta.favorite, single.favorite, reason: s.sourceRef);
      expect(meta.frozen, single.frozen, reason: s.sourceRef);
      expect(meta.playSec, single.playSec, reason: s.sourceRef);
    }
    expect(weight.metaOf(songs[0]).favorite, isTrue);
    expect(weight.metaOf(songs[2]).frozen, isTrue);

    // 预热写入了缓存：直接改库不经 _apply，metaOf 仍读缓存（stale）……
    await index.setFavorite('webdav:a', 'r0', false);
    expect(weight.metaOf(songs[0]).favorite, isTrue);
    // ……显式失效后可见外部写入。
    weight.notifyExternalWrite();
    expect(weight.metaOf(songs[0]).favorite, isFalse);

    // 库里没有匹配行不写入缓存，metaOf 走默认行兜底。
    final ghost = _song('webdav:x', 'ghost');
    await weight.warmMetaOf([ghost]);
    expect(weight.metaOf(ghost).favorite, isFalse);
    expect(weight.metaOf(ghost).factor, 1.0);

    // 空列表安全。
    await weight.warmMetaOf(const []);

    index.close();
  });
}
