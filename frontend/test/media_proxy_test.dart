import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/media_proxy.dart';
import 'package:selfmusic/utils/perf_log.dart';

/// MediaProxy 的 loopback HTTP/Range/生命周期回归。
///
/// worker 的 `file` 适配器仅测试用；SMB/SFTP 适配器走同一 HTTP/session 层，
/// 真实协议连接由真机日志验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 测试 binding 默认 mock HttpClient；这里要真实 loopback 请求。
  HttpOverrides.global = null;

  late Directory dir;
  late File file;
  late Uint8List data;
  late MediaProxyClient client;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('selfmusic_proxy_');
    data = Uint8List.fromList(List<int>.generate(256 * 1024, (i) => i & 0xff));
    file = File('${dir.path}/a.bin');
    await file.writeAsBytes(data);
    client = MediaProxyClient();
  });

  tearDown(() async {
    await client.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<Uri> start() async {
    final url = await client.start({
      'kind': 'file',
      'sourceKey': 'test:file',
      'path': file.path,
      'size': data.length,
      'mime': 'application/octet-stream',
    }, basename: 'a.bin');
    expect(url, isNotNull, reason: 'file 适配器应启动成功');
    return url!;
  }

  Future<List<int>> getBytes(Uri url, {String? range}) async {
    final http = HttpClient();
    try {
      final req = await http.getUrl(url);
      if (range != null) req.headers.set(HttpHeaders.rangeHeader, range);
      final resp = await req.close();
      final body = await resp.fold<List<int>>(
          <int>[], (acc, chunk) => acc..addAll(chunk));
      expect(resp.statusCode, range == null ? 200 : 206);
      return body;
    } finally {
      http.close(force: true);
    }
  }

  test('full GET 与 Range/HEAD/416/token', () async {
    final url = await start();
    expect(await getBytes(url), data.sublist(0));

    final ranged = await getBytes(url, range: 'bytes=100-199');
    expect(ranged, data.sublist(100, 200));

    // HEAD
    final http = HttpClient();
    try {
      final req = await http.openUrl('HEAD', url);
      final resp = await req.close();
      expect(resp.statusCode, 200);
      expect(resp.contentLength, data.length);
      expect(await resp.fold<int>(0, (n, c) => n + c.length), 0);
    } finally {
      http.close(force: true);
    }

    // 416
    final badHttp = HttpClient();
    try {
      final req = await badHttp.getUrl(url);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=999999-');
      final resp = await req.close();
      expect(resp.statusCode, 416);
      expect(resp.headers.value(HttpHeaders.contentRangeHeader),
          'bytes */${data.length}');
    } finally {
      badHttp.close(force: true);
    }

    // 错误 token
    final wrong = url.replace(pathSegments: [
      'media',
      'deadbeef',
      'a.bin',
    ]);
    final wrongHttp = HttpClient();
    try {
      final resp = await (await wrongHttp.getUrl(wrong)).close();
      expect(resp.statusCode, anyOf(404, 410));
    } finally {
      wrongHttp.close(force: true);
    }
  });

  test('stop 后旧 URL 失效，重新 start 可用', () async {
    final first = await start();
    await client.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final http = HttpClient();
    try {
      final resp = await (await http.getUrl(first)).close();
      expect(resp.statusCode, anyOf(404, 410));
    } finally {
      http.close(force: true);
    }

    final second = await start();
    expect(await getBytes(second), data.sublist(0));
  });

  test('中止在途请求记 http.abort，不记 http.error', () async {
    final big = File('${dir.path}/big.bin');
    final bigData = Uint8List(16 * 1024 * 1024);
    await big.writeAsBytes(bigData);
    final logs = <String>[];
    final prevSink = perfLogSink;
    perfLogSink = logs.add;
    addTearDown(() => perfLogSink = prevSink);

    final url = await client.start({
      'kind': 'file',
      'sourceKey': 'test:file',
      'path': big.path,
      'size': bigData.length,
      'mime': 'application/octet-stream',
    }, basename: 'big.bin');
    expect(url, isNotNull);

    final http = HttpClient();
    final resp = await (await http.getUrl(url!)).close();
    late StreamSubscription<List<int>> sub;
    // 暂停消费制造背压，让 worker 停在 flush；随后 stop + 断开模拟切歌。
    sub = resp.listen((_) => sub.pause());

    await Future<void>.delayed(const Duration(milliseconds: 100));
    await client.stop();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await sub.cancel();
    http.close(force: true);
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(logs.where((l) => l.contains('http.error')), isEmpty,
        reason: '切歌/停止导致的提前断开是正常中止');
    expect(logs.where((l) => l.contains('http.abort')), isNotEmpty);
  });
}
