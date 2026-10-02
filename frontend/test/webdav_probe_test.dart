import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/data/sources/webdav_direct_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:sqlite3/open.dart';

/// WebDAV 预热（probe）的 HTTP 语义。
///
/// 预热是「后台切歌不再冷启动」的关键路径的一半：请求必须与真实取流同口径
/// （GET + Range，鉴权头一致），且只取 1 字节——服务器忽略 Range 返回 200 时也
/// 不能把整首读进来（否则预热反而变成一次隐藏的整曲下载）。

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

void main() {
  test('预热发 Range: bytes=0-0 且只读 1 字节（206）', () async {
    var seenRange = '';
    var seenAuth = '';
    var bytesWritten = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      seenRange = req.headers.value(HttpHeaders.rangeHeader) ?? '';
      seenAuth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
      final body = List<int>.filled(4096, 0x41);
      final resp = req.response;
      resp.statusCode = HttpStatus.partialContent;
      resp.headers
          .set(HttpHeaders.contentRangeHeader, 'bytes 0-0/${body.length}');
      resp.contentLength = 1;
      resp.add(body.take(1).toList());
      await resp.close();
      bytesWritten = 1;
    });

    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    final tmp = Directory.systemTemp.createTempSync('selftest-probe');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    final index = LocalIndex();
    final src = WebdavDirectSource(
      name: 'nas',
      baseUrl: 'http://127.0.0.1:${server.port}',
      username: 'u',
      password: 'p',
      index: index,
    );
    await index.open();
    addTearDown(index.close);

    await src.probe(Song(
      id: 0,
      sourceKey: src.key,
      title: 'A',
      source: 'webdav',
      sourceRef: 'a.mp3',
      fileSize: 4096,
    ));

    expect(seenRange, 'bytes=0-0', reason: '预热必须与真实取流同口径（GET+Range）');
    expect(seenAuth, isNotEmpty, reason: '预热要带上鉴权头，否则探测不到 401');
    expect(bytesWritten, 1, reason: '预热只取 1 字节，不应拖整首下来');
  });

  test('服务器忽略 Range 返回 200 时，预热照样成功且只读 1 字节', () async {
    // 服务器无视 Range 直接回整首：预热必须客户端侧就收手，不能把整首读进来。
    // 慢速吐字节（1KB/10ms）才能看出客户端提前断开——整首 1MB 要写 10 秒。
    const totalChunks = 1000;
    var written = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final resp = req.response;
      resp.statusCode = HttpStatus.ok; // 无视 Range 的服务器
      resp.contentLength = 1024 * totalChunks;
      try {
        for (var i = 0; i < totalChunks; i++) {
          resp.add(List<int>.filled(1024, 0x42));
          written++;
          await resp.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        await resp.close();
      } catch (_) {
        // 客户端已收手：写端后续 flush 报错，忽略。
      }
    });

    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    final tmp = Directory.systemTemp.createTempSync('selftest-probe2');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    final index = LocalIndex();
    final src = WebdavDirectSource(
      name: 'nas',
      baseUrl: 'http://127.0.0.1:${server.port}',
      index: index,
    );
    await index.open();
    addTearDown(index.close);

    await src.probe(Song(
      id: 0,
      sourceKey: src.key,
      title: 'A',
      source: 'webdav',
      sourceRef: 'a.mp3',
      fileSize: 1024 * 1024,
    ));

    // 客户端 drain 到 1 字节响应就 close(force)：写端随后收不动，1MB 传不完。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(written, lessThan(50), reason: '预热应只取首个数据块就断开，不能把整首（1MB）拖下来');
  });

  test('预热失败必须抛出（供上层退避重试），不静默', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final resp = req.response..statusCode = HttpStatus.unauthorized;
      await resp.close();
    });

    open.overrideFor(OperatingSystem.linux, _openOnLinux);
    final tmp = Directory.systemTemp.createTempSync('selftest-probe3');
    addTearDown(() => tmp.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);

    final index = LocalIndex();
    final src = WebdavDirectSource(
      name: 'nas',
      baseUrl: 'http://127.0.0.1:${server.port}',
      index: index,
    );
    await index.open();
    addTearDown(index.close);

    // 401/403 一律抛 SourceAuthException（密码过期要能响亮失败并触发上层退避
    // 重试；曾静默返回空列表导致上层把整库当「全部消失」清掉）。此处断言的是
    // 异常类型而非具体消息，避免后续改文案就红。
    await expectLater(
      src.probe(Song(
        id: 0,
        sourceKey: src.key,
        title: 'A',
        source: 'webdav',
        sourceRef: 'a.mp3',
        fileSize: 10,
      )),
      throwsA(isA<SourceAuthException>()),
    );
  });
}
