import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/platform/harmonyos/avio_headers.dart';

void main() {
  group('buildAvioHeaders（mdk avio.headers 字符串）', () {
    test('空/null 返回空串（用于清除上一曲残留头）', () {
      expect(buildAvioHeaders(null), '');
      expect(buildAvioHeaders(const {}), '');
    });

    test('多条头以 CRLF 分隔，形如 "Key: Value"', () {
      final s = buildAvioHeaders(const {
        'Authorization': 'Bearer tok',
        'X-Origin-Auth': 'Basic abc',
      });
      // 顺序即插入顺序，便于断言。
      expect(s, 'Authorization: Bearer tok\r\nX-Origin-Auth: Basic abc');
    });

    test('值含冒号/空格原样保留（Basic 凭据里常见）', () {
      final s = buildAvioHeaders(const {
        'Authorization': 'Basic dXNlcjpwYXNz',
      });
      expect(s, 'Authorization: Basic dXNlcjpwYXNz');
    });
  });
}
