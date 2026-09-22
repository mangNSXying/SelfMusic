import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/meta_enrich.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/data/sources/sibling_cover.dart';
import 'package:selfmusic/models/album.dart';
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

Uint8List syncsafe(int v) => Uint8List.fromList([
      (v >> 21) & 0x7F,
      (v >> 14) & 0x7F,
      (v >> 7) & 0x7F,
      v & 0x7F,
    ]);

/// 大内嵌封面 MP3（400KB APIC），模拟真实带高清封面的曲库。
Uint8List bigCoverMp3() {
  final img = BytesBuilder();
  img.add([0xFF, 0xD8, 0xFF, 0xE0]);
  img.add(Uint8List(400 * 1024));
  img.add([0xFF, 0xD9]);
  final body = <int>[0, ...'image/jpeg'.codeUnits, 0, 3, 0, ...img.toBytes()];
  final frame = <int>[
    ...'APIC'.codeUnits,
    ...syncsafe(body.length),
    0, 0,
    ...body,
  ];
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    3, 0, 0,
    ...syncsafe(frame.length),
    ...frame,
    0xFF, 0xFB, 0x90, 0x00,
  ]);
}

/// 按 Range 长度返回前缀字节的假直连源（记录每次请求的长度）。
class _RangeFakeSource extends MusicSource {
  final Uint8List bytes;
  final List<int?> requestedLengths = [];
  _RangeFakeSource(this.bytes);

  @override
  String get key => 'webdav:t';
  @override
  String get name => 't';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;

  @override
  Future<List<Song>> fetchSongs({String? query, int page = 1, int size = 50}) async =>
      const [];
  @override
  Future<List<Album>> fetchAlbums({String? query, int page = 1, int size = 50}) async =>
      const [];
  @override
  Future<List<Song>> fetchAlbumSongs(int albumId) async => const [];
  @override
  String? streamUrl(int songId) => null;
  @override
  Map<String, String>? streamHeaders() => null;

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    final limit = range?.length ?? bytes.length;
    requestedLengths.add(limit);
    final end = limit < bytes.length ? limit : bytes.length;
    return OpenedStream(
      contentLength: bytes.length,
      contentType: 'audio/mpeg',
      stream: Stream.value(Uint8List.sublistView(bytes, 0, end)),
    );
  }
}

/// 按 ref 映射返回字节的假源（未知 ref 抛异常模拟 404）。
class _RefMapFakeSource extends MusicSource {
  final Map<String, Uint8List> files;
  final List<String> requested = [];
  _RefMapFakeSource(this.files);

  @override
  String get key => 'webdav:sib';
  @override
  String get name => 'sib';
  @override
  SourceKind get kind => SourceKind.webdav;
  @override
  bool get supportsDirect => true;

  @override
  Future<List<Song>> fetchSongs({String? query, int page = 1, int size = 50}) async =>
      const [];
  @override
  Future<List<Album>> fetchAlbums({String? query, int page = 1, int size = 50}) async =>
      const [];
  @override
  Future<List<Song>> fetchAlbumSongs(int albumId) async => const [];
  @override
  String? streamUrl(int songId) => null;
  @override
  Map<String, String>? streamHeaders() => null;

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    requested.add(song.sourceRef);
    final bytes = files[song.sourceRef];
    if (bytes == null) throw StateError('404 ${song.sourceRef}');
    final start = range?.start ?? 0;
    final length = range?.length ?? bytes.length;
    if (start >= bytes.length) {
      return OpenedStream(
          contentLength: bytes.length,
          contentType: 'application/octet-stream',
          stream: const Stream.empty());
    }
    final end = (start + length) > bytes.length ? bytes.length : start + length;
    return OpenedStream(
      contentLength: bytes.length,
      contentType: 'application/octet-stream',
      stream: Stream.value(Uint8List.sublistView(bytes, start, end)),
    );
  }
}

/// 无封面 MP3：ID3v2 + TIT2，无 APIC。
Uint8List noCoverMp3(String title) {
  final body = <int>[3, ...utf8.encode(title)];
  final frame = <int>[
    ...'TIT2'.codeUnits,
    ...syncsafe(body.length),
    0, 0,
    ...body,
  ];
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    4, 0, 0,
    ...syncsafe(frame.length),
    ...frame,
    0xFF, 0xFB, 0x90, 0x00,
  ]);
}

void main() {
  setUp(clearSiblingImageCache);
  test('播放补读：采样不足时从头完整读取整个文件（不截断）并落盘', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_enrich_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    final bytes = bigCoverMp3();
    final src = _RangeFakeSource(bytes);
    index.upsertSongs([
      DirectSongRow(
        sourceKey: 'webdav:t',
        ref: 'Music/a.mp3',
        title: 'a',
        format: 'mp3',
        size: bytes.length,
        mtime: 1,
      ),
    ]);
    final song = index.songByRef('webdav:t', 'Music/a.mp3')!;

    final ok = await enrichSongMeta(index, src, song);
    expect(ok, isTrue);
    // 第一段 256KB 采样 → 采样不足（封面被截断）→ 从头完整读取整个文件。
    expect(src.requestedLengths.first, 256 * 1024);
    expect(src.requestedLengths.length, 2);
    expect(src.requestedLengths.last, bytes.length);

    final updated = index.songByRef('webdav:t', 'Music/a.mp3')!;
    expect(updated.coverPath, isNotNull);
    expect(File(updated.coverPath!).existsSync(), isTrue);
    expect(File(updated.coverPath!).lengthSync(), greaterThan(400 * 1024));

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('封面回填一次性重置：已读但无封面的 mp3/flac 行回到未读，有封面行不动', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_reenrich_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    final cover = File('${dir.path}/cover.jpg')..writeAsBytesSync([1, 2, 3]);
    index.upsertSongs([
      DirectSongRow(
        sourceKey: 'webdav:t',
        ref: 'with_cover.mp3',
        title: '有封面',
        format: 'mp3',
        duration: 100,
        size: 1,
        mtime: 1,
        coverPath: cover.path,
      ),
      DirectSongRow(
        sourceKey: 'webdav:t',
        ref: 'no_cover.flac',
        title: '无封面',
        format: 'flac',
        duration: 100,
        size: 1,
        mtime: 2,
      ),
      DirectSongRow(
        sourceKey: 'webdav:t',
        ref: 'no_cover.m4a',
        title: '非解析格式',
        format: 'm4a',
        duration: 100,
        size: 1,
        mtime: 3,
      ),
    ]);
    // 前置：duration 已使三者 meta_read=1
    expect(index.unreadSongs('webdav:t', 10), isEmpty);

    final reset = index.resetMetaReadForMissingCovers();
    expect(reset, 1); // 仅 mp3/flac 且无封面的那一行
    final unread = index.unreadSongs('webdav:t', 10);
    expect(unread.map((s) => s.sourceRef), ['no_cover.flac']);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('元数据回填一次性重置：已读但无歌手的行回到未读（仅限指定直连源）', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_meta_reenrich_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    index.upsertSongs([
      DirectSongRow(
        sourceKey: 'webdav:t',
        ref: 'has_artist.flac',
        title: '有歌手',
        artist: '歌手',
        format: 'flac',
        duration: 100,
        size: 1,
        mtime: 1,
      ),
      DirectSongRow(
        sourceKey: 'webdav:t',
        ref: 'no_artist.flac',
        title: '无歌手',
        format: 'flac',
        duration: 100,
        size: 1,
        mtime: 2,
      ),
      DirectSongRow(
        sourceKey: 'webdav:t',
        ref: 'no_artist.m4a',
        title: '无歌手m4a',
        format: 'm4a',
        duration: 100,
        size: 1,
        mtime: 3,
      ),
      DirectSongRow(
        sourceKey: 'webdav:other',
        ref: 'no_artist.mp3',
        title: '其它源',
        format: 'mp3',
        duration: 100,
        size: 1,
        mtime: 4,
      ),
    ]);
    // 前置：duration 已使四者 meta_read=1
    expect(index.unreadSongs('webdav:t', 10), isEmpty);

    final reset = index.resetMetaReadForMissingArtist(['webdav:t']);
    expect(reset, 2); // 仅该源无歌手的 flac/m4a（所有格式统一）
    final unread = index.unreadSongs('webdav:t', 10);
    expect(unread.map((s) => s.sourceRef),
        containsAll(['no_artist.flac', 'no_artist.m4a']));
    expect(index.unreadSongs('webdav:other', 10), isEmpty); // 未指定源不动

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('无内嵌封面 → 同目录 cover.jpg 回退；目录级命中跨歌缓存', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_sibling_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    final a = noCoverMp3('A');
    final b = noCoverMp3('B');
    final cover = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 7), 0xFF, 0xD9,
    ]);
    final src = _RefMapFakeSource({
      'Music/a.mp3': a,
      'Music/b.mp3': b,
      'Music/cover.jpg': cover,
    });
    index.upsertSongs([
      DirectSongRow(
        sourceKey: 'webdav:sib', ref: 'Music/a.mp3', title: 'a',
        format: 'mp3', size: a.length, mtime: 1,
      ),
      DirectSongRow(
        sourceKey: 'webdav:sib', ref: 'Music/b.mp3', title: 'b',
        format: 'mp3', size: b.length, mtime: 2,
      ),
    ]);

    final ok = await enrichSongMeta(
        index, src, index.songByRef('webdav:sib', 'Music/a.mp3')!);
    expect(ok, isTrue);
    final aRow = index.songByRef('webdav:sib', 'Music/a.mp3')!;
    expect(aRow.coverPath, isNotNull);
    expect(File(aRow.coverPath!).existsSync(), isTrue);
    // 同名候选未命中后落到 cover.jpg。
    expect(src.requested, contains('Music/cover.jpg'));

    final before = src.requested.where((r) => r == 'Music/cover.jpg').length;
    expect(before, 1);
    final ok2 = await enrichSongMeta(
        index, src, index.songByRef('webdav:sib', 'Music/b.mp3')!);
    expect(ok2, isTrue);
    expect(index.songByRef('webdav:sib', 'Music/b.mp3')!.coverPath, isNotNull);
    // 同目录 cover.jpg 已缓存：第二首不再重复请求。
    expect(src.requested.where((r) => r == 'Music/cover.jpg').length, 1);

    index.close();
    dir.deleteSync(recursive: true);
  });
}
