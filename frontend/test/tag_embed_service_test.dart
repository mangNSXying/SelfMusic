import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/local_direct_source.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/services/tag_embed_service.dart';
import 'package:sqlite3/open.dart';


DynamicLibrary _openSqlite() {
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

const String _tempDir = '/home/shamiko/.vscode/project/selfmusic/temp';
const String _lyrics =
    '[ti:embed-flow]\n[00:01.00]嵌入流程歌\n[00:05.00]第二行\n';

/// 内存目录型假远端源（webdav 口径：open/uploadFile/deleteSidecar）。
class _FakeRemoteSource extends MusicSource {
  final String root;
  _FakeRemoteSource(this.root);

  @override
  String get key => 'webdav:t';

  @override
  String get name => 't';

  @override
  SourceKind get kind => SourceKind.webdav;

  @override
  bool get supportsDirect => true;

  @override
  bool get supportsWrite => true;

  File _file(String ref) => File('$root/$ref');

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    final f = _file(song.sourceRef);
    final len = await f.length();
    final start = range?.start ?? 0;
    final end = range?.length == null
        ? len
        : (start + range!.length!).clamp(0, len);
    Stream<List<int>> stream() async* {
      final raf = await f.open();
      try {
        await raf.setPosition(start);
        var rest = end - start;
        while (rest > 0) {
          final c = await raf.read(rest > 65536 ? 65536 : rest);
          if (c.isEmpty) break;
          yield c;
          rest -= c.length;
        }
      } finally {
        await raf.close();
      }
    }

    return OpenedStream(
      contentLength: end - start,
      contentType: 'audio/mpeg',
      stream: stream(),
      totalLength: len,
    );
  }

  @override
  Future<void> uploadFile(String parentRef, String filename,
      Stream<List<int>> bytes, int length) async {
    final dir = parentRef.isEmpty ? root : '$root/$parentRef';
    await Directory(dir).create(recursive: true);
    final sink = File('$dir/$filename').openWrite();
    try {
      await sink.addStream(bytes);
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> deleteSidecar(String parentRef, String filename) async {
    final p = parentRef.isEmpty ? '$root/$filename' : '$root/$parentRef/$filename';
    final f = File(p);
    if (await f.exists()) await f.delete();
  }

  @override
  String displayPath(Song song) => '$root/${song.sourceRef}';
}

Future<LocalIndex> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openSqlite());
  final dir = await Directory.systemTemp.createTemp('selfmusic_embedflow_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return index;
}

Future<Uint8List> _rangeOf(File f, int start, int length) async {
  final raf = await f.open();
  try {
    await raf.setPosition(start);
    final out = BytesBuilder();
    var rest = length;
    while (rest > 0) {
      final c = await raf.read(rest > 65536 ? 65536 : rest);
      if (c.isEmpty) break;
      out.add(c);
      rest -= c.length;
    }
    return out.takeBytes();
  } finally {
    await raf.close();
  }
}

Future<AudioMeta?> _readBack(String path, String format, int size) {
  final f = File(path);
  return readAudioMeta(
    readRange: (start, length) => _rangeOf(f, start, length),
    format: format,
    fileSize: size,
  );
}

void main() {
  test('远端全流程：GET→嵌入→PUT→复验→清sidecar→刷指纹', () async {
    final index = await _openIndex();
    final settings = AppSettings(index);
    final root = await Directory.systemTemp.createTemp('selfmusic_fakeroot_');
    await Directory('${root.path}/sub').create();
    final origBytes = await File('$_tempDir/周杰伦 - 发如雪.flac').readAsBytes();
    await File('${root.path}/sub/song.flac').writeAsBytes(origBytes);
    // 预置 sidecar（嵌入后应被删）。
    await File('${root.path}/sub/song.lrc').writeAsString('[00:01.00]旧\n');
    await File('${root.path}/sub/cover.jpg').writeAsBytes(List.filled(20, 0));

    const sourceKey = 'webdav:t';
    const ref = 'sub/song.flac';
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: sourceKey,
        ref: ref,
        title: '发如雪',
        artist: '周杰伦',
        duration: 302,
        format: 'flac',
        size: origBytes.length,
        mtime: 1,
      ),
    ]);
    await index.setLyrics(sourceKey, ref, _lyrics);
    final song = index.songByRef(sourceKey, ref)!;

    final svc = TagEmbedService(index: index, settings: settings);
    final src = _FakeRemoteSource(root.path);
    await svc.embedSong(song, src);

    // 远端文件已带新歌词。
    final after = await _readBack(
        '${root.path}/$ref', 'flac', await File('${root.path}/$ref').length());
    expect(after, isNotNull);
    expect(after!.lyrics, contains('嵌入流程歌'));
    // sidecar 已清。
    expect(await File('${root.path}/sub/song.lrc').exists(), isFalse);
    expect(await File('${root.path}/sub/cover.jpg').exists(), isFalse);
    // 指纹已刷（size 变化，mtime 推进）。
    final row = index.songByRef(sourceKey, ref)!;
    expect(row.fileSize, isNot(origBytes.length));
    index.close();
  });

  test('本地全流程：tmp+rename，旧歌词保留合并', () async {
    final index = await _openIndex();
    final settings = AppSettings(index);
    final root = await Directory.systemTemp.createTemp('selfmusic_localroot_');
    final origBytes = await File('$_tempDir/test-audio-aiff-16bit-44khz.aiff')
        .readAsBytes();
    await File('${root.path}/s.aiff').writeAsBytes(origBytes);

    const sourceKey = 'local:t';
    const ref = 's.aiff';
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: sourceKey,
        ref: ref,
        title: 's',
        duration: 30,
        format: 'aiff',
        size: origBytes.length,
        mtime: 1,
      ),
    ]);
    await index.setLyrics(sourceKey, ref, _lyrics);
    final song = index.songByRef(sourceKey, ref)!;

    final src = LocalDirectSource(name: 't', rootPath: root.path, index: index);
    final svc = TagEmbedService(index: index, settings: settings);
    await svc.embedSong(song, src);

    final after = await _readBack(
        '${root.path}/$ref', 'aiff', await File('${root.path}/$ref').length());
    expect(after, isNotNull);
    expect(after!.lyrics, contains('嵌入流程歌'));
    final row = index.songByRef(sourceKey, ref)!;
    expect(row.fileSize, isNot(origBytes.length));
    index.close();
  });

  test('无可嵌入内容拒绝', () async {
    final index = await _openIndex();
    final settings = AppSettings(index);
    const sourceKey = 'webdav:t';
    const ref = 'sub/x.flac';
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: sourceKey,
        ref: ref,
        title: 'x',
        duration: 10,
        format: 'flac',
        size: 100,
        mtime: 1,
      ),
    ]);
    final song = index.songByRef(sourceKey, ref)!;
    final svc = TagEmbedService(index: index, settings: settings);
    final root = await Directory.systemTemp.createTemp('selfmusic_empty_');
    expect(
      () => svc.embedSong(song, _FakeRemoteSource(root.path)),
      throwsA(isA<StateError>()),
    );
    index.close();
  });
}
