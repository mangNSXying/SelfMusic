import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/scan_worker.dart';
import 'package:selfmusic/data/sources/webdav_direct_source.dart';
import 'package:sqlite3/open.dart';

/// 纯 VM 测试无 sqlite3_flutter_libs 提供原生库，回退加载系统 libsqlite3.so.0。
DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

/// 让 [LocalIndex.open] 落到测试临时目录，避免真实平台通道。
class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

Uint8List _syncsafe(int v) =>
    Uint8List.fromList([(v >> 21) & 0x7F, (v >> 14) & 0x7F, (v >> 7) & 0x7F, v & 0x7F]);

/// 合成一个含 ID3v2 TIT2 帧 + MPEG 帧头的 mp3 字节。
Uint8List _mp3Bytes(String title) {
  final text = title.codeUnits;
  final frame = <int>[0, ...text];
  final frameBytes = <int>[
    ...'TIT2'.codeUnits,
    ..._syncsafe(frame.length),
    0,
    0,
    ...frame,
  ];
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    0x04,
    0x00,
    0x00,
    ..._syncsafe(frameBytes.length),
    ...frameBytes,
    0xFF,
    0xFB,
    0x90,
    0x00,
  ]);
}

const _propfindRoot = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response>
  <d:href>/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/folder/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/test.mp3</d:href>
  <d:propstat><d:prop><d:getcontentlength>12345</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>''';

const _propfindFolder = '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
 <d:response>
  <d:href>/folder/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
 <d:response>
  <d:href>/folder/song.mp3</d:href>
  <d:propstat><d:prop><d:getcontentlength>12345</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>''';

void main() {
  late HttpServer server;
  late String base;
  final log = <String>[];
  final bytes1 = _mp3Bytes('Song One');
  final bytes2 = _mp3Bytes('Song Two');

  setUp(() async {
    log.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final resp = req.response;
      if (req.method == 'PROPFIND') {
        log.add('PROPFIND ${req.uri.path}');
        resp.statusCode = HttpStatus.multiStatus; // 207
        resp.headers.contentType = ContentType('application', 'xml');
        final body = req.uri.path.startsWith('/folder') ? _propfindFolder : _propfindRoot;
        resp.write(body);
        await resp.close();
        return;
      }
      // GET（Range 读头部）
      log.add('GET ${req.uri.path}');
      final mp3 = req.uri.path.startsWith('/folder') ? bytes2 : bytes1;
      resp.statusCode = HttpStatus.partialContent; // 206
      resp.headers.set(HttpHeaders.contentRangeHeader,
          'bytes 0-${mp3.length - 1}/${mp3.length}');
      resp.contentLength = mp3.length;
      resp.headers.contentType = ContentType('audio', 'mpeg');
      resp.add(mp3);
      await resp.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('扫描把 WebDAV 目录递归落库（跨 isolate）', () async {
    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    final tmp = Directory.systemTemp.createTempSync('selftest-webdav');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    final index = LocalIndex();
    final src = WebdavDirectSource(
      name: 'nas',
      baseUrl: base,
      index: index,
    );
    await index.open();
    addTearDown(index.close);

    final summary = await src.scan();

    expect(summary.added, 2);
    expect(index.countSongs(src.key), 2);
    final all = index.searchSongs(sourceKey: src.key);
    final titles = all.map((s) => s.title).toSet();
    expect(titles, contains('Song One'));
    expect(titles, contains('Song Two'));

    // 增量：指纹（size/mtime/etag）未变 → 二次扫描零读头（GET 不再增加）。
    final getsAfterFirst = log.where((l) => l.startsWith('GET')).length;
    expect(getsAfterFirst, 2);
    final summary2 = await src.scan();
    expect(summary2.unchanged, 2, reason: '未变化的文件应直接跳过读头');
    expect(summary2.added, 0);
    final getsAfterSecond = log.where((l) => l.startsWith('GET')).length;
    expect(getsAfterSecond, getsAfterFirst, reason: '增量扫描不应产生新的 GET');
  });

  test('增量：校验 etag/getlastmodified；etag 变化仅重探该文件', () async {
    // 服务器返回固定 size + 可变 etag；第二次改 etag → 仅该文件重新探测。
    var etagRoot = '"abc"';
    final etagServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => etagServer.close(force: true));
    etagServer.listen((req) async {
      final resp = req.response;
      if (req.method == 'PROPFIND') {
        resp.statusCode = HttpStatus.multiStatus;
        resp.headers.contentType = ContentType('application', 'xml');
        resp.write('''<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/a.mp3</d:href><d:propstat><d:prop><d:getcontentlength>100</d:getcontentlength><d:getetag>$etagRoot</d:getetag><d:getlastmodified>Wed, 18 Sep 2026 10:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/b.mp3</d:href><d:propstat><d:prop><d:getcontentlength>100</d:getcontentlength><d:getetag>"fixed"</d:getetag><d:getlastmodified>Wed, 18 Sep 2026 10:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
        await resp.close();
        return;
      }
      final b = _mp3Bytes('A');
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(HttpHeaders.contentRangeHeader,
          'bytes 0-${b.length - 1}/${b.length}');
      resp.contentLength = b.length;
      resp.headers.contentType = ContentType('audio', 'mpeg');
      resp.add(b);
      await resp.close();
    });

    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    final tmp = Directory.systemTemp.createTempSync('selftest-etag');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    final index = LocalIndex();
    final src = WebdavDirectSource(
      name: 'etag',
      baseUrl: 'http://127.0.0.1:${etagServer.port}',
      index: index,
    );
    await index.open();
    addTearDown(index.close);

    final s1 = await src.scan();
    expect(s1.added, 2);

    // a.mp3 的 etag 变化 → 仅它被重新探测（updated），b.mp3 跳过。
    etagRoot = '"def"';
    final s2 = await src.scan();
    expect(s2.updated, 1, reason: 'etag 变化的 a.mp3 应重探');
    expect(s2.unchanged, 1, reason: 'etag 不变的 b.mp3 应跳过');
  });

  test('目录 base 不带尾斜杠时也能扫描（服务器 301 重定向场景）', () async {
    // 模拟真实服务器行为：PROPFIND 无尾斜杠的目录路径返回 301 重定向，
    // 带尾斜杠才返回 207。修复前扫描会因 301 非 207/200 而被判为空目录。
    final redirectServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => redirectServer.close(force: true));
    const basePath = '/dav';
    redirectServer.listen((req) async {
      final resp = req.response;
      final trailing = req.uri.path.endsWith('/');
      if (!trailing && req.method == 'PROPFIND') {
        resp.statusCode = HttpStatus.movedPermanently; // 301
        resp.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${redirectServer.port}$basePath/');
        await resp.close();
        return;
      }
      if (req.method == 'PROPFIND') {
        // 返回路径相关的多状态：self + 一个音频文件
        resp.statusCode = HttpStatus.multiStatus;
        resp.headers.contentType = ContentType('application', 'xml');
        resp.write('''<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>$basePath/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>$basePath/test.mp3</d:href><d:propstat><d:prop><d:getcontentlength>12345</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
        await resp.close();
        return;
      }
      final b = _mp3Bytes('Song One');
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(HttpHeaders.contentRangeHeader,
          'bytes 0-${b.length - 1}/${b.length}');
      resp.contentLength = b.length;
      resp.headers.contentType = ContentType('audio', 'mpeg');
      resp.add(b);
      await resp.close();
    });

    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    final tmp = Directory.systemTemp.createTempSync('selftest-redirect');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    final index = LocalIndex();
    // base 不带尾斜杠：'http://127.0.0.1:port/dav'
    final src = WebdavDirectSource(
      name: 'redirect',
      baseUrl: 'http://127.0.0.1:${redirectServer.port}/dav',
      index: index,
    );
    await index.open();
    addTearDown(index.close);

    final summary = await src.scan();
    expect(summary.added, 1, reason: '301 重定向的目录也应能扫描出根下音频');
    expect(index.countSongs(src.key), 1);
  });

  test('PROPFIND 401 时扫描响亮报错且不清库（密码过期回归）', () async {
    // 2026-09-29 真机事故：WebDAV 密码在服务器侧被改，App 存的旧密码 401，
    // _propfind 曾静默返回空 → 扫描"成功"0 首 → 上层把整库当「全部消失」清掉，
    // 且 UI 无任何报错。修复后必须：扫描抛鉴权错误 + 本地库原样保留。
    var authOk = true;
    final authServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => authServer.close(force: true));
    authServer.listen((req) async {
      final resp = req.response;
      if (req.method == 'PROPFIND') {
        if (!authOk) {
          resp.statusCode = HttpStatus.unauthorized; // 401
          await resp.close();
          return;
        }
        resp.statusCode = HttpStatus.multiStatus;
        resp.headers.contentType = ContentType('application', 'xml');
        resp.write('''<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/test.mp3</d:href><d:propstat><d:prop><d:getcontentlength>12345</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
        await resp.close();
        return;
      }
      final b = _mp3Bytes('Song One');
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(HttpHeaders.contentRangeHeader,
          'bytes 0-${b.length - 1}/${b.length}');
      resp.contentLength = b.length;
      resp.headers.contentType = ContentType('audio', 'mpeg');
      resp.add(b);
      await resp.close();
    });

    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    final tmp = Directory.systemTemp.createTempSync('selftest-auth401');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    final index = LocalIndex();
    final src = WebdavDirectSource(
      name: 'auth401',
      baseUrl: 'http://127.0.0.1:${authServer.port}',
      index: index,
    );
    await index.open();
    addTearDown(index.close);

    final s1 = await src.scan();
    expect(s1.added, 1);
    expect(index.countSongs(src.key), 1);

    // 密码失效：扫描必须抛鉴权错误，而不是"成功"0 首并清库。
    authOk = false;
    await expectLater(
        src.scan(),
        throwsA(isA<ScanWorkerException>().having(
            (e) => e.toString(), 'message', contains('鉴权失败'))));
    expect(index.countSongs(src.key), 1, reason: '鉴权失败绝不能清空本地曲库');
  });

  test('扫描结果为空时防误清库（指向空目录回归）', () async {
    // baseUrl 指到存在但为空的目录（如路径手误）时，PROPFIND 是正常的 207
    // 但列不出任何音频——此时若照常提交会 markMissingExcept(空)+clearMissing
    // 把整库清掉。修复后：中止并报错，本地库原样保留。
    var emptyListing = false;
    final emptyServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => emptyServer.close(force: true));
    emptyServer.listen((req) async {
      final resp = req.response;
      if (req.method == 'PROPFIND') {
        resp.statusCode = HttpStatus.multiStatus;
        resp.headers.contentType = ContentType('application', 'xml');
        resp.write(emptyListing
            ? '''<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>'''
            : '''<d:multistatus xmlns:d="DAV:">
 <d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/test.mp3</d:href><d:propstat><d:prop><d:getcontentlength>12345</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
        await resp.close();
        return;
      }
      final b = _mp3Bytes('Song One');
      resp.statusCode = HttpStatus.partialContent;
      resp.headers.set(HttpHeaders.contentRangeHeader,
          'bytes 0-${b.length - 1}/${b.length}');
      resp.contentLength = b.length;
      resp.headers.contentType = ContentType('audio', 'mpeg');
      resp.add(b);
      await resp.close();
    });

    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    final tmp = Directory.systemTemp.createTempSync('selftest-emptyguard');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    final index = LocalIndex();
    final src = WebdavDirectSource(
      name: 'emptyguard',
      baseUrl: 'http://127.0.0.1:${emptyServer.port}',
      index: index,
    );
    await index.open();
    addTearDown(index.close);

    final s1 = await src.scan();
    expect(s1.added, 1);
    expect(index.countSongs(src.key), 1);

    // 服务器目录变空：扫描中止报错，不许静默清库。
    emptyListing = true;
    await expectLater(
        src.scan(),
        throwsA(isA<ScanWorkerException>().having(
            (e) => e.toString(), 'message', contains('误清库'))));
    expect(index.countSongs(src.key), 1, reason: '空结果防误清库闸门失效');
  });
}
