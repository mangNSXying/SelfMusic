import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/webdav_direct_source.dart';

/// DNS 诊断辅助的回归：
///
/// IPv6-only 域名 + 只查 IPv4 的代理 DNS → 应用拿到 fake-ip 后一路黑洞，
/// 日志里只表现为超时。这里锁定 fake-ip 网段判定，保证日志能直接给出定性。
void main() {
  test('Clash fake-ip v4 网段 198.18.0.0/15', () {
    expect(isFakeIpAddress(InternetAddress('198.18.0.1')), isTrue);
    expect(isFakeIpAddress(InternetAddress('198.19.255.254')), isTrue);
    expect(isFakeIpAddress(InternetAddress('198.20.0.1')), isFalse);
    expect(isFakeIpAddress(InternetAddress('8.8.8.8')), isFalse);
  });

  test('Clash fake-ip v6 网段 fc00::/18', () {
    expect(isFakeIpAddress(InternetAddress('fc00::1')), isTrue);
    expect(isFakeIpAddress(InternetAddress('fc3f::1')), isTrue);
    expect(isFakeIpAddress(InternetAddress('fc40::1')), isFalse);
    expect(isFakeIpAddress(InternetAddress('fd00::1')), isFalse);
  });

  test('真实公网 IPv6 不算 fake-ip', () {
    expect(
      isFakeIpAddress(
          InternetAddress('2409:8a55:2632:67e1:4816:6598:ba68:fe7d')),
      isFalse,
    );
  });
}
