// 鸿蒙 dart:io HTTPS 根证书注入（ohos_bootstrap._loadRootCerts）的回归测试。
//
// 资产三重断言：在位且多张、MB 依赖的 ISRG Root X1（Let's Encrypt）必须包含、
// 字节能被 SecurityContext 解析（PEM 语法有效）。Windows 安全：纯内存，无临时目录。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('CA bundle 资产在位、含 ISRG Root X1、可被 SecurityContext 解析', () async {
    final data = await rootBundle.load('assets/ca/ca-bundle.crt');
    final pem = utf8.decode(data.buffer.asUint8List());

    // 多张根证书（Mozilla bundle 规模下界：截断/损坏立刻暴露）。
    expect('-----BEGIN CERTIFICATE-----'.allMatches(pem).length,
        greaterThan(100),
        reason: '根证书张数异常，bundle 可能被截断');

    // musicbrainz.org 用 Let's Encrypt：缺 ISRG Root X1 则解析修复无效。
    expect(pem.contains('ISRG Root X1'), isTrue,
        reason: "缺 ISRG Root X1（Let's Encrypt 根），MB 解析仍会握手失败");

    // 与运行时同一入口：解析失败（PEM 语法坏）在此立刻抛。
    expect(
        () => SecurityContext.defaultContext
            .setTrustedCertificatesBytes(data.buffer.asUint8List()),
        returnsNormally);
  });
}
