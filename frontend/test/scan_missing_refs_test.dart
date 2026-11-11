import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/scan_commit.dart';
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

DirectSongRow _row(String ref) => DirectSongRow(
      sourceKey: 'webdav:test',
      ref: ref,
      title: ref,
      size: 1,
      mtime: 1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalIndex index;
  late Directory dir;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_scanmissing_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
    await index.upsertSource('webdav:test', 'webdav', 'test', '{}');
    await index.upsertSongs([_row('s1'), _row('s2'), _row('s3')]);
  });

  tearDown(() async {
    index.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('取消扫描不产生 missing diff', () async {
    final known = index.scanFingerprint('webdav:test');
    final summary = await commitScan(
      index,
      sourceKey: 'webdav:test',
      items: const [],
      known: known,
      cancelled: true,
    );

    expect(summary.cancelled, isTrue);
    expect(summary.missingRefs, isEmpty);
    expect(index.countSongs('webdav:test'), 3,
        reason: '取消的半途扫描不能把未遍历到的歌标成 missing');
    expect(index.scanFingerprint('webdav:test').length, 3);
  });

  test('完整扫描返回 missingRefs，并只清未收藏的缺失行', () async {
    final known = index.scanFingerprint('webdav:test');
    final summary = await commitScan(
      index,
      sourceKey: 'webdav:test',
      items: [
        ScannedSong(row: _row('s1'), kind: ScanItemKind.unchanged),
      ],
      known: known,
    );

    expect(summary.missingRefs, containsAll(['s2', 's3']));
    expect(index.countSongs('webdav:test'), 1);
    expect(index.scanFingerprint('webdav:test').keys, ['s1']);
  });

  test('pruneUnavailable 清断点队列与深历史里的死引用', () async {
    final queue = jsonEncode([
      _song('s2').toJson(),
      _song('s1').toJson(),
    ]);
    await index.saveDeepList(
        'playlist:u', jsonEncode([_song('s2').toJson()]));
    await index.savePlayState(queue, 0, 0, anchorKey: 'playlist:u');

    await index.pruneUnavailable('webdav:test', {'s2'});

    final deepRaw = index.loadDeepList('playlist:u');
    final deep = deepRaw == null ? const [] : jsonDecode(deepRaw) as List;
    expect(deep.any((e) => (e as Map)['sourceRef'] == 's2'), isFalse);
    final state = index.getPlayState()!;
    final restored = jsonDecode(state.queueJson) as List;
    expect(restored.any((e) => (e as Map)['sourceRef'] == 's2'), isFalse);
    expect(restored.any((e) => (e as Map)['sourceRef'] == 's1'), isTrue);
  });
}

Song _song(String ref) => Song(
      id: 0,
      sourceKey: 'webdav:test',
      title: ref,
      source: 'webdav',
      sourceRef: ref,
      fileSize: 0,
    );
