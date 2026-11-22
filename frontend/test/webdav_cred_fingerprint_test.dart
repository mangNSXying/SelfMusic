import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/webdav_direct_source.dart';

/// 临时诊断辅助函数的行为锁定：同一份账密必须产出同一指纹，
/// 任何一位差异都要改变指纹（用于对照扫描/探针/播放三条链路）。
void main() {
  test('凭据指纹：同账密同指纹，改一位即不同', () {
    final a = webdavCredFingerprint('user', 'pass');
    final b = webdavCredFingerprint('user', 'pass');
    expect(a, b);
    expect(a, contains('user=4'));
    expect(a, contains('pwd=4'));

    expect(webdavCredFingerprint('user', 'pasS'), isNot(a));
    expect(webdavCredFingerprint('useR', 'pass'), isNot(a));
    expect(webdavCredFingerprint('user', ''), isNot(a));
  });

  test('凭据指纹不含明文', () {
    final fp = webdavCredFingerprint('secretuser', 'secretpass');
    expect(fp, isNot(contains('secretuser')));
    expect(fp, isNot(contains('secretpass')));
  });
}
