import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/webdav_url.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/utils/url_input.dart';

void main() {
  group('url_input 纯函数：scheme 检测与补全', () {
    test('urlHasScheme 大小写不敏感，空白容忍', () {
      expect(urlHasScheme('192.168.1.10:18443'), isFalse);
      expect(urlHasScheme('nas.local/dav'), isFalse);
      expect(urlHasScheme('https://h'), isTrue);
      expect(urlHasScheme('HTTP://h'), isTrue);
      expect(urlHasScheme('  https://h  '), isTrue);
      expect(urlHasScheme(''), isFalse);
      expect(urlHasScheme('https ://h'), isFalse);
    });

    test('urlIsExplicitHttp 仅 http（大小写不敏感）', () {
      expect(urlIsExplicitHttp('http://h:18089'), isTrue);
      expect(urlIsExplicitHttp('HTTP://h:18089'), isTrue);
      expect(urlIsExplicitHttp('  http://h  '), isTrue);
      expect(urlIsExplicitHttp('https://h'), isFalse);
      expect(urlIsExplicitHttp('nas.local:8443'), isFalse);
      expect(urlIsExplicitHttp(''), isFalse);
    });

    test('urlWithHttpsPrefix 缺 scheme 补 https，已有不动', () {
      expect(urlWithHttpsPrefix('192.168.1.10:18443'),
          'https://192.168.1.10:18443');
      expect(urlWithHttpsPrefix('  nas.local/dav  '), 'https://nas.local/dav');
      expect(urlWithHttpsPrefix('https://h:8443/api'), 'https://h:8443/api');
      expect(urlWithHttpsPrefix('HTTP://h:18089'), 'HTTP://h:18089');
      expect(urlWithHttpsPrefix(''), '');
      expect(urlWithHttpsPrefix('   '), '');
    });
  });

  group('二重保险：normalize 大小写/尾斜杠/空串', () {
    test('ApiClient.normalizeBaseUrl 保留显式 scheme 并去多尾斜杠', () {
      expect(ApiClient.normalizeBaseUrl('HTTP://h:18089/'), 'HTTP://h:18089');
      expect(
          ApiClient.normalizeBaseUrl('https://h:8443/api///'), 'https://h:8443/api');
      expect(ApiClient.normalizeBaseUrl('   '), '');
    });

    test('webdavNormalizeBase 空串保持空串（历史 bug：曾变成 https:）', () {
      expect(webdavNormalizeBase(''), '');
      expect(webdavNormalizeBase('   '), '');
      expect(webdavNormalizeBase('192.168.1.10:5005/media//'),
          'https://192.168.1.10:5005/media');
      expect(webdavNormalizeBase('HTTP://h/dav/'), 'HTTP://h/dav');
    });

    test('validate 大写 HTTP 同样受开关约束', () {
      expect(ApiClient.validateEndpointUrl('HTTP://h:18089', allowHttp: false),
          isNotNull);
      expect(ApiClient.validateEndpointUrl('HTTP://h:18089', allowHttp: true),
          isNull);
      expect(ApiClient.validateEndpointUrl('  http://h  ', allowHttp: false),
          isNotNull);
    });
  });
}
