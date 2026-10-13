import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/data/sources/sibling_cover.dart';
import 'package:selfmusic/data/sources/webdav_direct_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:sqlite3/open.dart';

/// 同目录图片回退的「不许落盘截断图」防线。
///
/// 旧实现只按前 12 字节的图片签名判定，一张比读取上限还大的图被截断后照样通过
/// 校验并落盘 → Android `ImageDecoder` 解码失败，界面上什么都没有，而这行已被
/// 标成「已读」，再也不会重试。
///
/// 修法是让调用方能回答「资源一共多大」：范围读取时 [OpenedStream.contentLength]
/// 只是「这次拿到多少」，新增的 [OpenedStream.totalLength] 才是真实总长度（本地
/// 源给文件大小，WebDAV 从 `Content-Range` 尾部取）。

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

/// 带 PNG 签名 + IEND 尾的完整字节（轻量完整性校验可通过）。
Uint8List pngBytes(int totalBytes) {
  final b = Uint8List(totalBytes);
  b.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  for (var i = 8; i < totalBytes; i++) {
    b[i] = 0x41;
  }
  // IEND 块尾（12B）：00 00 00 00 49 45 4E 44 AE 42 60 82。
  if (totalBytes >= 12) {
    b.setAll(totalBytes - 12,
        [0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]);
  }
  return b;
}

/// 只有头签名、无尾的半图（断流产物：totalLength 即使一致也要拒收）。
Uint8List truncatedPngBytes(int totalBytes) {
  final b = Uint8List(totalBytes);
  b.setAll(0, [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  for (var i = 8; i < totalBytes; i++) {
    b[i] = 0x41;
  }
  return b;
}

/// 只按 [OpenedStream] 语义发数的假源，覆盖各种截断组合。
///
/// [delivered] 是这次真的发出去的字节数（可以少于 [body]），[contentLength] 与
/// [totalLength] 按各自语义分别给。
class _FakeSource implements MusicSource {
  _FakeSource({
    required this.body,
    required this.contentLength,
    required this.totalLength,
    int? delivered,
  }) : delivered = delivered ?? body.length;

  final Uint8List body;
  final int contentLength;
  final int? totalLength;
  final int delivered;
  int requests = 0;

  @override
  String get key => 'fake:1';

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    requests++;
    return OpenedStream(
      contentLength: contentLength,
      contentType: 'image/png',
      totalLength: totalLength,
      stream: Stream<List<int>>.value(body.sublist(0, delivered)),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song() => Song(
      id: 1,
      sourceKey: 'fake:1',
      title: '歌',
      source: 'fake',
      sourceRef: 'Album/01 song.flac',
      fileSize: 4096,
    );

void main() {
  setUp(clearSiblingImageCache);

  group('isImageBytes 的长度校验', () {
    test('签名像图且长度与真实总长一致 → 接受', () {
      expect(isImageBytes(pngBytes(4096), totalLength: 4096), isTrue);
    });

    test('总长未知且流自然结束 → 接受（只能信签名）', () {
      expect(isImageBytes(pngBytes(4096)), isTrue);
    });

    test('总长大于读到的字节（被截断）→ 拒绝', () {
      expect(isImageBytes(pngBytes(4096), totalLength: 8192), isFalse,
          reason: '截断图解码必然失败，不该落盘');
    });

    test('连签名都不像 → 拒绝', () {
      expect(isImageBytes(List<int>.filled(64, 0x41), totalLength: 64), isFalse);
    });

    test('短于 12 字节 → 拒绝', () {
      expect(isImageBytes([0x89, 0x50, 0x4E, 0x47], totalLength: 4), isFalse);
    });

    test('总长一致但缺尾（断流半图，totalLength 为 null 也拒）→ 拒绝', () {
      // 问题1：流提前断开时 totalLength 可能为 null，只能靠尾判拦截。
      expect(isImageBytes(truncatedPngBytes(4096), totalLength: 4096), isFalse);
      expect(isImageBytes(truncatedPngBytes(4096)), isFalse);
    });
  });

  group('fetchSiblingImage 的截断处理', () {
    test('完整图片：正常返回', () async {
      final img = await fetchSiblingImage(
        _FakeSource(
            body: pngBytes(64 * 1024),
            totalLength: 64 * 1024,
            contentLength: 64 * 1024),
        _song(),
      );
      expect(img, isNotNull);
      expect(img!.length, 64 * 1024);
    });

    test('图片大于读取上限 → 判定读不全，不返回字节', () async {
      // 20MB 的图，只读到 8MB 上限：签名在前 12 字节，光看签名会误收。
      final src = _FakeSource(
        body: pngBytes(20 * 1024 * 1024),
        totalLength: 20 * 1024 * 1024,
        contentLength: 8 * 1024 * 1024,
        delivered: 8 * 1024 * 1024,
      );
      final img = await fetchSiblingImage(src, _song());
      expect(img, isNull, reason: '截断图不能当成有效封面');
    });

    test('服务端提前断流（短于真实总长）→ 拒绝', () async {
      final src = _FakeSource(
        body: pngBytes(2048),
        totalLength: 512 * 1024,
        contentLength: 2048,
        delivered: 2048,
      );
      expect(await fetchSiblingImage(src, _song()), isNull);
    });

    test('否定缓存：截断后不再反复探测同一个候选', () async {
      final src = _FakeSource(
        body: pngBytes(20 * 1024 * 1024),
        totalLength: 20 * 1024 * 1024,
        contentLength: 8 * 1024 * 1024,
        delivered: 8 * 1024 * 1024,
      );
      expect(await fetchSiblingImage(src, _song()), isNull);
      final after = src.requests;
      expect(await fetchSiblingImage(src, _song()), isNull);
      expect(src.requests, after, reason: '同会话内不该重复探测');
    });
  });

  group('WebDAV 的 totalLength 来自 Content-Range', () {
    late Directory tmp;

    setUp(() async {
      open.overrideFor(OperatingSystem.linux, _openOnLinux);
      tmp = Directory.systemTemp.createTempSync('selftest-cover');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('206 响应：totalLength = Content-Range 尾部的真实总长', () async {
      const total = 20 * 1024 * 1024;
      const served = 8 * 1024 * 1024;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final resp = req.response;
        resp.statusCode = HttpStatus.partialContent;
        resp.headers.set(HttpHeaders.contentRangeHeader,
            'bytes 0-${served - 1}/$total');
        resp.contentLength = served;
        resp.add(pngBytes(served));
        await resp.close();
      });

      final index = LocalIndex();
      await index.open();
      addTearDown(index.close);
      final src = WebdavDirectSource(
        name: 'nas',
        baseUrl: 'http://127.0.0.1:${server.port}',
        username: 'u',
        password: 'p',
        index: index,
      );

      final opened = await src.open(
        Song(
          id: 1,
          sourceKey: src.key,
          title: 'A',
          source: 'webdav',
          sourceRef: 'cover.png',
          fileSize: total,
        ),
        range: const IntRange(0, served), // 第二个参数是长度
      );
      expect(opened.contentLength, served,
          reason: 'contentLength 只是这次拿到的字节数');
      expect(opened.totalLength, total,
          reason: 'totalLength 才是资源真实大小，供调用方判断截断');
    });

    test('服务端无视 Range 返回 200 全量：totalLength = Content-Length', () async {
      const total = 4096;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final resp = req.response;
        resp.statusCode = HttpStatus.ok;
        resp.contentLength = total;
        resp.add(pngBytes(total));
        await resp.close();
      });

      final index = LocalIndex();
      await index.open();
      addTearDown(index.close);
      final src = WebdavDirectSource(
        name: 'nas',
        baseUrl: 'http://127.0.0.1:${server.port}',
        username: 'u',
        password: 'p',
        index: index,
      );
      final opened = await src.open(
        Song(
          id: 1,
          sourceKey: src.key,
          title: 'A',
          source: 'webdav',
          sourceRef: 'cover.png',
          fileSize: total,
        ),
        range: const IntRange(0, 1024),
      );
      expect(opened.totalLength, total);
    });

    test('206 但服务端不回 Content-Range：totalLength 为 null（不瞎猜）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((req) async {
        final resp = req.response;
        resp.statusCode = HttpStatus.partialContent;
        resp.contentLength = 2048;
        resp.add(pngBytes(2048));
        await resp.close();
      });

      final index = LocalIndex();
      await index.open();
      addTearDown(index.close);
      final src = WebdavDirectSource(
        name: 'nas',
        baseUrl: 'http://127.0.0.1:${server.port}',
        username: 'u',
        password: 'p',
        index: index,
      );
      final opened = await src.open(
        Song(
          id: 1,
          sourceKey: src.key,
          title: 'A',
          source: 'webdav',
          sourceRef: 'cover.png',
          fileSize: 8192,
        ),
        range: const IntRange(0, 2048),
      );
      expect(opened.totalLength, isNull);
    });
  });
}