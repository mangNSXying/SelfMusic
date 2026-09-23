import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/webdav_url.dart';
import 'package:selfmusic/utils/url_display.dart';

void main() {
  group('webdavNormalizeBase', () {
    test('补 scheme、去尾斜杠', () {
      expect(webdavNormalizeBase('192.168.1.10:5005/media/'),
          'https://192.168.1.10:5005/media');
      expect(webdavNormalizeBase('https://nas.example.com:8443/dav'),
          'https://nas.example.com:8443/dav');
    });
  });

  group('webdavResolve', () {
    test('根绝对路径且位于 base 之下（NAS 最常见）', () {
      expect(webdavResolve('/media/song.mp3', 'http://h:5005/media'),
          'http://h:5005/media/song.mp3');
    });

    test('相对 base 目录的绝对路径（曾丢失 base 前缀的回归）', () {
      expect(webdavResolve('/song.mp3', 'http://h:5005/media'),
          'http://h:5005/media/song.mp3');
    });

    test('相对请求目录的文件名', () {
      expect(webdavResolve('song.mp3', 'http://h:5005/media/'),
          'http://h:5005/media/song.mp3');
    });

    test('子目录相对 href', () {
      expect(webdavResolve('song.mp3', 'http://h:5005/media/sub/'),
          'http://h:5005/media/sub/song.mp3');
      expect(webdavResolve('/song.mp3', 'http://h:5005/media/sub'),
          'http://h:5005/media/sub/song.mp3');
    });

    test('绝对 URL 原样返回', () {
      expect(webdavResolve('http://h:5005/media/song.mp3', 'http://h:5005/media'),
          'http://h:5005/media/song.mp3');
    });

    test('base 为根路径', () {
      expect(webdavResolve('/a.mp3', 'http://h:5005'), 'http://h:5005/a.mp3');
    });
  });

  group('ref 编解码与整链重建', () {
    test('encode/decode 往返无损', () {
      const ref = '/media/中国 歌手/歌.m4a';
      final enc = webdavEncodePath(ref);
      expect(enc, contains('%'));
      expect(webdavDecodePath(enc), ref);
    });

    test('webdavResolveRef 以编码路径重建完整 URL', () {
      expect(webdavResolveRef('/media/中国 歌手/歌.m4a', 'http://h:5005/media'),
          'http://h:5005/media/%E4%B8%AD%E5%9B%BD%20%E6%AD%8C%E6%89%8B/%E6%AD%8C.m4a');
    });

    test('历史 ENCODE 行：play 重建不双重编码', () {
      const encodedRef =
          '/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing%21.flac';
      expect(webdavResolveRefForPlay(encodedRef, 'http://h:5005/dav'),
          'http://h:5005/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing!.flac');
      expect(webdavResolveRefForPlay(encodedRef, 'http://h:5005/dav'), isNot(contains('%25')));
    });

    test('新行 Unicode ref：play 重建单层编码', () {
      expect(webdavResolveRefForPlay('/dav/佐藤しずく - Growing!.flac', 'http://h:5005/dav'),
          'http://h:5005/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing!.flac');
    });

    test('webdavCanonicalUrl 收敛 Unicode/编码/双重编码', () {
      const base =
          'http://h:5005/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing!.flac';
      expect(webdavCanonicalUrl('http://h:5005/dav/佐藤しずく - Growing!.flac'), base);
      expect(webdavCanonicalUrl(
              'http://h:5005/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing%21.flac'),
          base);
    });

    test('webdavRefVariants 覆盖新旧两种入库形态', () {
      const encoded =
          '/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing%21.flac';
      const decoded = '/dav/佐藤しずく - Growing!.flac';
      final fromEncoded = webdavRefVariants(encoded);
      expect(fromEncoded.first, encoded);
      expect(fromEncoded, contains(decoded));
      final fromDecoded = webdavRefVariants(decoded);
      expect(fromDecoded.first, decoded);
      // 历史行把 `!` 存成 `%21` 也能命中（严格编码形态）。
      expect(fromDecoded, contains(encoded));
      // 无需编码的纯 ASCII 路径只有一种形态。
      expect(webdavRefVariants('/dav/song.mp3'), ['/dav/song.mp3']);
    });
  });

  group('decodeUrlForDisplay', () {
    test('百分号编码 URL 解码为可读文本（展示用）', () {
      expect(
          decodeUrlForDisplay(
              'http://h:5005/dav/%E5%8F%A4%E5%85%B8/%E5%A4%9C%E6%9B%B2.flac'),
          'http://h:5005/dav/古典/夜曲.flac');
      expect(
          decodeUrlForDisplay(
              'http://h/dav/%E4%BD%90%E8%97%A4%20-%20Growing%21.flac'),
          'http://h/dav/佐藤 - Growing!.flac');
    });

    test('无编码/非 URL 原样返回，坏编码不抛错', () {
      expect(decodeUrlForDisplay('/local/path/歌曲.flac'), '/local/path/歌曲.flac');
      expect(decodeUrlForDisplay('http://h/dav/song.mp3'), 'http://h/dav/song.mp3');
      expect(decodeUrlForDisplay('http://h/dav/%E5%8F%A4'), 'http://h/dav/古');
      expect(decodeUrlForDisplay('http://h/dav/%E5%8F%A4%ZZ'),
          'http://h/dav/%E5%8F%A4%ZZ');
    });
  });
}