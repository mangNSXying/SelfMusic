import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/meta_enrich.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/data/sources/sibling_cover.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/cover_thumb.dart';
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

/// 按 Range 返回对应区间字节的假直连源（记录每次请求的区间）。
class _RangeFakeSource extends MusicSource {
  final Uint8List bytes;
  final List<IntRange?> requestedRanges = [];
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
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    requestedRanges.add(range);
    final start = range?.start ?? 0;
    final length = range?.length ?? bytes.length;
    if (start >= bytes.length) {
      return OpenedStream(
        contentLength: bytes.length,
        contentType: 'audio/mpeg',
        stream: const Stream.empty(),
      );
    }
    final end = (start + length) > bytes.length ? bytes.length : start + length;
    return OpenedStream(
      contentLength: bytes.length,
      contentType: 'audio/mpeg',
      stream: Stream.value(Uint8List.sublistView(bytes, start, end)),
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
  // mock 通道（selfmusic/platform）需要测试绑定。
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(clearSiblingImageCache);
  test('播放补读：采样截断时按结构补读（不整读）并落盘', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_enrich_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    final bytes = bigCoverMp3();
    final src = _RangeFakeSource(bytes);
    await index.upsertSongs([
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
    // 第一段 256KB 采样 → 封面被截断 → 从采样末尾**增量续读**到 ID3v2 头里
    // 声明的标签末尾（不重下已读段、更不整读文件）。
    final ranges = src.requestedRanges.whereType<IntRange>().toList();
    expect(ranges.length, 2);
    expect(ranges.first.start, 0);
    expect(ranges.first.length, 256 * 1024);
    expect(ranges.last.start, 256 * 1024, reason: '增量续读：从已读末尾继续');
    final secondEnd = ranges.last.start + (ranges.last.length ?? 0);
    expect(secondEnd, greaterThan(400 * 1024), reason: '按声明长度补读到标签末尾');
    expect(secondEnd, lessThan(bytes.length), reason: '不整读文件');

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
    await index.upsertSongs([
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

    final reset = await index.resetMetaReadForMissingCovers();
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

    await index.upsertSongs([
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

    final reset = await index.resetMetaReadForMissingArtist(['webdav:t']);
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
    await index.upsertSongs([
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

  group('补读与缩略图解耦（ohos 原生管线，mock 通道，ohos-thumb-native-decode）', () {
    const channel = MethodChannel('selfmusic/platform');

    /// mock 侧收到的调用记录。
    final calls = <MethodCall>[];

    /// 注册 mock：统一记录调用后交 [responder] 应答（覆盖前一次注册）。
    void mockThumb(Future<Object?>? Function(MethodCall call) responder) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return await responder(call);
      });
    }

    setUp(() {
      // 宿主（Windows）非 'ohos'：置测试开关让 unawaited 的
      // ensureCoverThumb 走原生桥分支（plan.md R-7）。
      forceNativeThumbInTests = true;
      calls.clear();
    });

    tearDown(() {
      forceNativeThumbInTests = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('桥返回 false → 补读仍成功标已读，封面落盘，缩略图静默放弃', () async {
      mockThumb((_) async => false);
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_enrich_no_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final index = LocalIndex();
      await index.open();

      final bytes = bigCoverMp3();
      final src = _RangeFakeSource(bytes);
      await index.upsertSongs([
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
      // 缩略图桥失败不影响补读主链路：成功解析、标已读（R-5 静默兜底）。
      expect(ok, isTrue);
      final row = index.songByRef('webdav:t', 'Music/a.mp3')!;
      expect(row.coverPath, isNotNull);
      expect(File(row.coverPath!).existsSync(), isTrue);
      expect(index.unreadSongs('webdav:t', 10), isEmpty);

      await pumpEventQueue();
      expect(calls, hasLength(1)); // 桥被请求过一次。
      // 静默回原图：不落缩略图、展示路径不变、不抛错。
      expect(File(coverThumbPathFor(row.coverPath!)).existsSync(), isFalse);
      expect(coverDisplayPath(row.coverPath!), row.coverPath);

      index.close();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上 db-writer isolate 退出与删除竞争（errno 32）：残留
        // 系统临时目录无害，不计失败（区别于既有用例的直删断言）。
      }
    });

    test('桥挂起 → 补读先返回不等缩略图；桥完成后缩略图才就绪', () async {
      final gate = Completer<Object?>();
      mockThumb((_) => gate.future);
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_enrich_go_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final index = LocalIndex();
      await index.open();

      final bytes = bigCoverMp3();
      final src = _RangeFakeSource(bytes);
      await index.upsertSongs([
        DirectSongRow(
          sourceKey: 'webdav:t',
          ref: 'Music/b.mp3',
          title: 'b',
          format: 'mp3',
          size: bytes.length,
          mtime: 1,
        ),
      ]);
      final song = index.songByRef('webdav:t', 'Music/b.mp3')!;

      final ok = await enrichSongMeta(index, src, song);
      // 桥仍挂起时补读已返回：unawaited 解耦（meta_enrich.dart 不等缩略图）。
      expect(ok, isTrue);
      final row = index.songByRef('webdav:t', 'Music/b.mp3')!;
      expect(row.coverPath, isNotNull);
      expect(calls, hasLength(1));
      // 缩略图未就绪：展示路径仍是原图。
      expect(coverDisplayPath(row.coverPath!), row.coverPath);

      gate.complete(true);
      await pumpEventQueue();
      // 桥成功后：缓存/展示路径切到缩略图（Dart 侧不落盘，mock 不写文件）。
      expect(coverDisplayPath(row.coverPath!), coverThumbPathFor(row.coverPath!));
      expect(File(coverThumbPathFor(row.coverPath!)).existsSync(), isFalse);

      index.close();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // 同上：best-effort 清理，竞争残留不计失败。
      }
    });
  });
}
