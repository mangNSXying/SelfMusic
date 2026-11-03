import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/webdav_direct_source.dart';

/// WebDAV 写链路的错误文案语义：401=凭据，403=服务器拒绝（鉴权已过）。
///
/// 回归背景：改完账密后写回文件仍 403，旧文案一律说「用户名或密码可能已更改，
/// 请重新输入密码」——用户被反复引导去改账密，而真正原因是该账号对目标位置
/// 没有写权限。403（写）必须与 401 分开表述。
void main() {
  test('写链路 403：鉴权已过、无写权限，不再引导改账密', () {
    const e = WebdavStatusException(403, 'https://h/dav/sub/a.flac', write: true);
    final s = e.toString();
    expect(s, contains('拒绝写入'));
    expect(s, contains('没有写权限'));
    expect(s, isNot(contains('用户名或密码')));
    expect(s, contains('https://h/dav/sub/a.flac'));
  });

  test('401：才是凭据问题，引导重新输入', () {
    const s = WebdavStatusException(401, 'https://h/dav');
    expect(s.toString(), contains('鉴权失败'));
    expect(s.toString(), contains('用户名或密码'));
  });

  test('读链路 403：判为无访问权限，而非凭据失效', () {
    const s = WebdavStatusException(403, 'https://h/dav');
    expect(s.toString(), contains('拒绝访问'));
    expect(s.toString(), isNot(contains('写入')));
    expect(s.toString(), isNot(contains('用户名或密码')));
  });
}
