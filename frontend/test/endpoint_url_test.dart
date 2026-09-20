import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/api_client.dart';

void main() {
  group('ApiClient.normalizeBaseUrl 默认 https', () {
    test('缺 scheme 一律补 https://', () {
      expect(ApiClient.normalizeBaseUrl('192.168.1.10:18443'),
          'https://192.168.1.10:18443');
      expect(ApiClient.normalizeBaseUrl('nas.local/dav'),
          'https://nas.local/dav');
    });

    test('显式 scheme 保留，去末尾斜杠', () {
      expect(ApiClient.normalizeBaseUrl('https://h:8443/api/'),
          'https://h:8443/api');
      expect(ApiClient.normalizeBaseUrl('http://h:18089/'),
          'http://h:18089');
    });

    test('空串保持空串', () {
      expect(ApiClient.normalizeBaseUrl(''), '');
      expect(ApiClient.normalizeBaseUrl('   '), '');
    });
  });

  group('ApiClient.validateEndpointUrl', () {
    test('空串/无 scheme 放行', () {
      expect(ApiClient.validateEndpointUrl('', allowHttp: false), isNull);
      expect(ApiClient.validateEndpointUrl('nas.local:8443', allowHttp: false),
          isNull);
    });

    test('默认关时显式 http 拒绝，https 放行', () {
      expect(ApiClient.validateEndpointUrl('http://h:18089', allowHttp: false),
          isNotNull);
      expect(
          ApiClient.validateEndpointUrl('https://h:18443', allowHttp: false),
          isNull);
    });

    test('允许开关打开后 http 放行', () {
      expect(ApiClient.validateEndpointUrl('http://h:18089', allowHttp: true),
          isNull);
    });
  });
}