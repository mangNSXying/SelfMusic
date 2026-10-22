import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/webdav_direct_source.dart';

void main() {
  test('WebDAV 测试连接：PROPFIND 2xx 成功，401 抛鉴权错误', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final auth = req.headers.value(HttpHeaders.authorizationHeader);
      final expected = 'Basic ${base64Encode(utf8.encode('u:p'))}';
      if (req.method != 'PROPFIND' ||
          req.headers.value('Depth') != '0' ||
          auth != expected) {
        req.response.statusCode = HttpStatus.unauthorized;
      } else {
        req.response.statusCode = 207;
        req.response
            .write('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>');
      }
      await req.response.close();
    });

    final base = 'http://127.0.0.1:${server.port}/dav';
    await WebdavDirectSource.testConnection(
      baseUrl: base,
      username: 'u',
      password: 'p',
    );

    await expectLater(
      WebdavDirectSource.testConnection(
        baseUrl: base,
        username: 'u',
        password: 'wrong',
      ),
      throwsA(
          isA<WebdavStatusException>().having((e) => e.status, 'status', 401)),
    );
  });
}
