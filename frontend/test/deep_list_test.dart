import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/deep_list.dart';
import 'package:selfmusic/data/local/local_index.dart';
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
  final dir = await Directory.systemTemp.createTemp('selfmusic_deep_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

Song _song(String ref) => Song(
      id: 0,
      sourceKey: 'local:x',
      title: ref,
      source: 'local',
      sourceRef: ref,
      fileSize: 0,
    );

bool _same(Song a, Song b) =>
    a.sourceKey == b.sourceKey && a.sourceRef == b.sourceRef;

void main() {
  group('DeepListController', () {
    test('countEntries：JSON 字符串/已解码 List/坏数据同口径', () {
      expect(DeepListController.countEntries(null), 0);
      expect(DeepListController.countEntries(''), 0);
      expect(DeepListController.countEntries('{bad json'), 0);
      expect(DeepListController.countEntries('{"a":1}'), 0);
      expect(DeepListController.countEntries('[]'), 0);
      expect(
          DeepListController.countEntries(
              '[{"source":"webdav","source_ref":"a"}]'),
          1);
      expect(DeepListController.countEntries([1, 2, 3]), 3);
    });

    test('pushPlayed：推入末尾、末尾去重、超容量清空重来', () {
      final dl = DeepListController(capacity: 3);
      dl.pushPlayed(_song('a'), same: _same);
      dl.pushPlayed(_song('b'), same: _same);
      dl.pushPlayed(_song('b'), same: _same); // 末尾重复 → 不动
      expect(dl.entries.map((s) => s.sourceRef), ['a', 'b']);

      dl.pushPlayed(_song('c'), same: _same);
      expect(dl.length, 3);
      // 第 4 首 = 已播完一轮 → 清空后从当前曲重新开始
      dl.pushPlayed(_song('d'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['d']);
    });

    test('pushPlayed：容量收缩（歌单删歌）后超容量同样清空重来', () {
      final dl = DeepListController(capacity: 3);
      for (final r in ['a', 'b', 'c']) {
        dl.pushPlayed(_song(r), same: _same);
      }
      dl.capacity = 2; // 歌单删到 2 首
      dl.pushPlayed(_song('d'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['d']);
    });

    test('replaceTail：替换末尾不增长、空列表直接推入、末尾重复不动', () {
      final dl = DeepListController(capacity: 5);
      dl.replaceTail(_song('a'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['a']);
      // 空/单元素时替换即覆盖，不新增
      dl.replaceTail(_song('b'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['b']);
      dl.pushPlayed(_song('c'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['b', 'c']);
      dl.replaceTail(_song('d'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['b', 'd']);
      dl.replaceTail(_song('d'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['b', 'd']);
    });

    test('popTail：弹出当前曲，末尾回退；空栈返回 null', () {
      final dl = DeepListController(capacity: 5);
      expect(dl.popTail(), isNull);
      dl.pushPlayed(_song('a'), same: _same);
      dl.pushPlayed(_song('b'), same: _same);
      expect(dl.popTail()!.sourceRef, 'b');
      expect(dl.tail!.sourceRef, 'a');
      expect(dl.popTail()!.sourceRef, 'a');
      expect(dl.tail, isNull);
    });

    test('removeRef：移除全部引用（含非末尾）', () {
      final dl = DeepListController(capacity: 5);
      for (final r in ['a', 'b', 'a', 'c']) {
        dl.pushPlayed(_song(r), same: _same);
      }
      dl.removeRef(_song('a'), same: _same);
      expect(dl.entries.map((s) => s.sourceRef), ['b', 'c']);
    });

    test('toJson/parseEntries 往返；坏行跳过', () {
      final dl = DeepListController(capacity: 5);
      dl.pushPlayed(_song('a'), same: _same);
      dl.pushPlayed(_song('b'), same: _same);
      final raw = jsonDecode(jsonEncode(dl.toJson()));
      final parsed = DeepListController.parseEntries(raw);
      expect(parsed.map((s) => s.sourceRef), ['a', 'b']);
      expect(DeepListController.parseEntries('bad'), isEmpty);
      expect(
          DeepListController.parseEntries([
            {'sourceKey': 'x'},
            'bad',
            _song('c').toJson(),
          ]).map((s) => s.sourceRef),
          ['c']);
    });
  });

  group('持久化', () {
    test('save/load/deleteDeepList 往返', () async {
      final index = await _openIndex();
      expect(index.loadDeepList('puuid-1'), isNull);
      await index.saveDeepList('puuid-1', jsonEncode([_song('a').toJson()]));
      final raw = index.loadDeepList('puuid-1')!;
      expect(DeepListController.parseEntries(jsonDecode(raw)).single.sourceRef,
          'a');
      await index.deleteDeepList('puuid-1');
      expect(index.loadDeepList('puuid-1'), isNull);
      index.close();
    });

    test('删除歌单同步清理其深层列表', () async {
      final index = await _openIndex();
      await index.createPlaylist('p');
      final pid = index.listPlaylists().single.id;
      final uuid = await index.ensurePlaylistUuid(pid);
      await index.saveDeepList(uuid, jsonEncode([_song('a').toJson()]));
      expect(index.loadDeepList(uuid), isNotNull);
      await index.deletePlaylist(pid);
      expect(index.loadDeepList(uuid), isNull);
      index.close();
    });
  });
}
