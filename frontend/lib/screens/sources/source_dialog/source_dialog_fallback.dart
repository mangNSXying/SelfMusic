import 'package:flutter/material.dart';

import '../../../data/sources/music_source.dart';
import '../../../data/sources/sftp_direct_source.dart';
import '../../../data/sources/smb_common.dart';

/// 备用源表单数据（本地不可做备用，故 kind 仅 webdav/sftp/smb）。
class SourceFallbackData {
  SourceKind kind;
  SourceRoute route = SourceRoute.direct;
  SftpAuthMethod authMethod = SftpAuthMethod.password;
  late TextEditingController baseUrl;
  late TextEditingController host;
  late TextEditingController port;
  late TextEditingController smbPath;
  late TextEditingController username;
  late TextEditingController password;
  late TextEditingController path;
  late TextEditingController keyPem;
  late TextEditingController keyPassphrase;
  String? keyFileName;

  SourceFallbackData({
    this.kind = SourceKind.webdav,
    Map<String, dynamic>? from,
  }) {
    final m = from ?? const {};
    baseUrl = TextEditingController(text: m['baseUrl'] as String? ?? '');
    host = TextEditingController(text: m['host'] as String? ?? '');
    port = TextEditingController(text: (m['port'] as num?)?.toString() ?? '');
    smbPath = TextEditingController(
        text: kind == SourceKind.smb
            ? smbJoinInputPath(
                share: m['share'] as String? ?? '',
                rootPath: m['path'] as String? ?? '')
            : '');
    username = TextEditingController(text: m['username'] as String? ?? '');
    password = TextEditingController(text: m['password'] as String? ?? '');
    path = TextEditingController(text: m['path'] as String? ?? '');
    keyPem = TextEditingController(text: m['keyPem'] as String? ?? '');
    keyPassphrase =
        TextEditingController(text: m['passphrase'] as String? ?? '');
    route = parseSourceRoute(m['route']);
    authMethod = parseSftpAuthMethod(m['authMethod']);
    if (kind == SourceKind.webdav && from != null) {
      // editableConfig 回填的 password 已在上。
    }
  }

  Map<String, dynamic> toRawMap() {
    // SMB 弹窗只填一个「路径」：落库前拆回 share/path 两键（存储结构不变）。
    var shareOut = '';
    var pathOut = path.text.trim();
    if (kind == SourceKind.smb) {
      final parsed = smbParseInputPath(smbPath.text);
      shareOut = parsed.share;
      pathOut = parsed.rootPath;
    }
    final m = <String, dynamic>{
      'kind': kind.name,
      'baseUrl': baseUrl.text.trim(),
      'host': host.text.trim(),
      'port': int.tryParse(port.text.trim()) ?? 22,
      'share': shareOut,
      'username': username.text.trim(),
      'password': password.text,
      'keyPem': keyPem.text,
      'passphrase': keyPassphrase.text,
      'authMethod': authMethod.name,
      'path': pathOut,
      'route': route.name,
    };
    return m;
  }

  void dispose() {
    baseUrl.dispose();
    host.dispose();
    port.dispose();
    smbPath.dispose();
    username.dispose();
    password.dispose();
    path.dispose();
    keyPem.dispose();
    keyPassphrase.dispose();
  }
}
