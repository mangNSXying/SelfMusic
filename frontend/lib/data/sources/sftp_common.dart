import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'music_source.dart';

/// 真机 PoC 诊断开关：`--dart-define=SFTP_WORKER_TRACE=true`。
/// 只在明确排查 worker 生命周期/读流/测试连接时打开，正常构建无日志。
const bool sftpTraceEnabled = bool.fromEnvironment('SFTP_WORKER_TRACE');

void sftpTrace(String message) {
  if (sftpTraceEnabled) debugPrint('[sftp-worker] $message');
}

/// SFTP 认证方式：密码 / 粘贴的 PEM 私钥文本（含 passphrase 的加密私钥另填）。
enum SftpAuthMethod { password, key }

/// 解析持久化/同步来的认证方式；缺失或非法回落密码（旧配置兼容）。
SftpAuthMethod parseSftpAuthMethod(Object? v) =>
    SftpAuthMethod.values.firstWhere(
      (e) => e.name == v,
      orElse: () => SftpAuthMethod.password,
    );

/// `host:port` 钉键（host 小写；与 `normalizeSftpAddress` 的主机段同口径）。
String sftpHostPort(String host, int port) =>
    '${host.trim().toLowerCase()}:$port';

/// 代理 origin（`sftp://host:port/逐段编码路径`，无 userinfo；凭据走信封）。
/// 纯函数，可单测。IPv6 主机自动加方括号。
String sftpOriginUrl({
  required String host,
  required int port,
  required String ref,
}) {
  var h = host.trim();
  if (h.contains(':') && !(h.startsWith('[') && h.endsWith(']'))) {
    h = '[$h]';
  }
  final enc = ref
      .split('/')
      .where((s) => s.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');
  return 'sftp://$h:$port/$enc';
}

/// SFTP 写路径守卫（与 WebDAV 同口径）：禁分隔符与 `..`。纯函数，可单测。
void sftpGuardWriteName(String name) {
  if (name.isEmpty || name.contains('/') || name.contains('\\')) {
    throw StateError('文件名非法：$name');
  }
  if (name == '.' || name == '..' || name.contains('..')) {
    throw StateError('文件名非法（路径穿越）：$name');
  }
}

/// 写父目录守卫（与 WebDAV 同口径）：各段禁 `.`/`..`。纯函数，可单测。
void sftpGuardWriteParent(String parentRef) {
  final parts = parentRef.split('/').where((s) => s.isNotEmpty);
  if (parts.any((s) => s == '.' || s == '..')) {
    throw StateError('目录非法（路径穿越）：$parentRef');
  }
}

/// SFTP 非 2xx 语义外的连接/协议错误：toString 面向用户直接展示。
///
/// [code] 为远端 SFTP 状态码（`SftpStatusCode`）；连接类异常没有状态码，
/// 由传输层自行决定是否重连。保留 code 是为了让上传/删除等写链路仍能按
/// `permissionDenied` / `noSuchFile` 给出中文提示（旧实现直接 catch
/// `SftpStatusError`，worker 化后跨 isolate 不能再传异常对象）。
class SftpStatusException implements Exception {
  final String message;
  final int? code;
  const SftpStatusException(this.message, {this.code});

  @override
  String toString() => message;
}

/// 扫描 isolate 内主机指纹失配：携带实际指纹供主 isolate 转抛展示。
class SshHostKeyMismatch implements Exception {
  final String actual;
  const SshHostKeyMismatch(this.actual);

  @override
  String toString() => 'SSH 主机指纹与已确认的不一致（实际 $actual）：'
      '可能是中间人或服务器重装，请核对后重新确认';
}

/// 打开 SFTP 文件后的流式结果（主 isolate 侧只拿到已解密字节）。
class SftpOpenResult {
  /// 本次读取区间的字节数（范围读取时 = 区间长度，不等于文件总大小）。
  final int contentLength;

  /// 文件真实总长度；未知为 null。
  final int? totalLength;

  /// 已解密字节流；结束/出错/取消都会关闭远端句柄。
  final Stream<List<int>> stream;

  const SftpOpenResult({
    required this.contentLength,
    required this.totalLength,
    required this.stream,
  });
}

/// SFTP 传输抽象：直连（旧路径，UI isolate 内解密）与 worker isolate
/// （推荐路径，解密在后台 isolate）实现同一组操作。
abstract class SftpTransport {
  Future<void> probe(String path);

  Future<SftpOpenResult> open(
    String path, {
    int? start,
    int? length,
    int fallbackTotal = 0,
  });

  Future<void> upload(String path, Stream<List<int>> bytes, int length);

  Future<void> remove(String path);

  Future<void> mkdir(String path);

  Future<bool> isDirectory(String path);

  Future<void> close();
}

/// 连接句柄（扫描 isolate 与 worker isolate 共用）。
typedef OpenedSftpConnection = ({SSHClient client, SftpClient sftp});

/// 错误信息截断：短错误原样展示，长错误用 [what] 兜底（与旧实现同口径）。
String shortSftpError(Object e, String what) {
  final s =
      e.toString().replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '');
  return s.length > 160 ? what : '$what：$s';
}

/// SSH/SFTP 建连与主机指纹（无 UI 依赖，可在任意 isolate 调用）。
class SftpConnection {
  /// 建连（调用方传已钉指纹做校验；`pinnedFp` 为空=未知主机，直接抛错引导
  /// 用户走弹窗测试连接流程，绝不静默信任）。密钥文本非法抛
  /// [SourceAuthException]（指回密钥/口令）；指纹失配抛
  /// [SshHostKeyMismatch]（带实际指纹）；鉴权失败抛 [SourceAuthException]；
  /// 其余连通性问题抛 [SftpStatusException]。
  static Future<OpenedSftpConnection> open({
    required String host,
    required int port,
    required String username,
    required SftpAuthMethod authMethod,
    required String password,
    required String keyPem,
    required String keyPassphrase,
    required String? pinnedFp,
  }) async {
    if (pinnedFp == null || pinnedFp.isEmpty) {
      throw StateError('未知 SSH 主机，请先测试连接并确认主机指纹');
    }
    List<SSHIdentity>? identities;
    if (authMethod == SftpAuthMethod.key) {
      try {
        identities = SSHKeyPair.fromPem(
            keyPem, keyPassphrase.isEmpty ? null : keyPassphrase);
      } catch (e) {
        throw const SourceAuthException('SFTP 密钥无法解析：请检查密钥文本与 passphrase');
      }
    }
    late final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port,
          timeout: const Duration(seconds: 15));
    } catch (e) {
      throw SftpStatusException(shortSftpError(e, 'SFTP 连接失败（$host:$port）'));
    }
    String? presented;
    final client = SSHClient(
      socket,
      username: username,
      onVerifyHostKey: (type, fp) async {
        presented = utf8.decode(fp);
        return presented == pinnedFp;
      },
      identities: identities,
      onPasswordRequest:
          authMethod == SftpAuthMethod.password ? () => password : null,
    );
    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      // 指纹优先：verifier 拒收后的错误可能被包装变形，一律以实际指纹为准。
      final got = presented;
      if (got != null && got != pinnedFp) throw SshHostKeyMismatch(got);
      if (e is SSHAuthError) {
        throw const SourceAuthException('SFTP 鉴权失败：用户名或密码/密钥可能已更改，'
            '请编辑该源重输');
      }
      throw SftpStatusException(shortSftpError(e, 'SFTP 建连失败'));
    }
    try {
      final sftp = await client.sftp();
      return (client: client, sftp: sftp);
    } catch (e) {
      client.close();
      throw SftpStatusException(shortSftpError(e, 'SFTP 子系统失败'));
    }
  }

  /// 仅取主机指纹（测试连接流程用）：接受任意主机密钥，**调用方必须随后向
  /// 用户展示并钉住**，不得用于播放/扫描。鉴权失败抛
  /// [SourceAuthException]，其余连通性问题抛 [SftpStatusException]。
  static Future<String> fetchFingerprint({
    required String host,
    required int port,
    required String username,
    required SftpAuthMethod authMethod,
    required String password,
    required String keyPem,
    required String keyPassphrase,
  }) async {
    List<SSHIdentity>? identities;
    if (authMethod == SftpAuthMethod.key) {
      try {
        identities = SSHKeyPair.fromPem(
            keyPem, keyPassphrase.isEmpty ? null : keyPassphrase);
      } catch (e) {
        throw const SourceAuthException('SFTP 密钥无法解析：请检查密钥文本与 passphrase');
      }
    }
    late final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port,
          timeout: const Duration(seconds: 15));
    } catch (e) {
      throw SftpStatusException(shortSftpError(e, 'SFTP 连接失败（$host:$port）'));
    }
    String? fp;
    final client = SSHClient(
      socket,
      username: username,
      onVerifyHostKey: (type, f) async {
        fp = utf8.decode(f);
        return true;
      },
      identities: identities,
      onPasswordRequest:
          authMethod == SftpAuthMethod.password ? () => password : null,
    );
    try {
      await client.authenticated;
      final got = fp;
      if (got == null || got.isEmpty) throw StateError('未能获取主机指纹');
      return got;
    } on SSHAuthError {
      throw const SourceAuthException('SFTP 鉴权失败：用户名或密码/密钥可能不正确');
    } catch (e) {
      throw SftpStatusException(shortSftpError(e, 'SFTP 建连失败'));
    } finally {
      client.close();
    }
  }

  /// 测试连接用：在一次性 isolate 里取指纹。SSH KEX/验签/解密不在 UI
  /// isolate 执行，弹窗「测试连接」期间界面不再被同步密码学计算卡住。
  /// 异常用结构化载荷跨 isolate 还原，类型与 [fetchFingerprint] 一致。
  static Future<String> fetchFingerprintInIsolate({
    required String host,
    required int port,
    required String username,
    required SftpAuthMethod authMethod,
    required String password,
    required String keyPem,
    required String keyPassphrase,
  }) async {
    final started = Stopwatch()..start();
    sftpTrace('fingerprint $host:$port start');
    final result = await Isolate.run<Map<String, Object?>>(() async {
      try {
        final fp = await fetchFingerprint(
          host: host,
          port: port,
          username: username,
          authMethod: authMethod,
          password: password,
          keyPem: keyPem,
          keyPassphrase: keyPassphrase,
        );
        return <String, Object?>{'ok': true, 'fp': fp};
      } catch (e) {
        return <String, Object?>{
          'ok': false,
          'error': _fingerprintErrorPayload(e)
        };
      }
    });
    if (result['ok'] == true) {
      sftpTrace(
          'fingerprint $host:$port done in ${started.elapsedMilliseconds}ms');
      return result['fp'] as String;
    }
    sftpTrace(
        'fingerprint $host:$port failed in ${started.elapsedMilliseconds}ms');
    final payload =
        (result['error'] as Map?)?.cast<String, Object?>() ?? result;
    throw _fingerprintErrorFromPayload(payload);
  }
}

Map<String, Object?> _fingerprintErrorPayload(Object e) {
  if (e is SourceAuthException) {
    return <String, Object?>{'kind': 'auth', 'message': e.message};
  }
  if (e is SshHostKeyMismatch) {
    return <String, Object?>{
      'kind': 'hostKey',
      'message': e.toString(),
      'actual': e.actual,
    };
  }
  if (e is SftpStatusException) {
    return <String, Object?>{
      'kind': 'status',
      'message': e.message,
      'code': e.code,
    };
  }
  if (e is StateError) {
    return <String, Object?>{'kind': 'state', 'message': e.message.toString()};
  }
  return <String, Object?>{'kind': 'unknown', 'message': e.toString()};
}

Object _fingerprintErrorFromPayload(Map<String, Object?> m) {
  switch (m['kind']) {
    case 'auth':
      return SourceAuthException((m['message'] as String?) ?? 'SFTP 鉴权失败');
    case 'hostKey':
      return SshHostKeyMismatch((m['actual'] as String?) ?? '');
    case 'status':
      return SftpStatusException(
        (m['message'] as String?) ?? 'SFTP 请求失败',
        code: (m['code'] as num?)?.toInt(),
      );
    case 'state':
      return StateError((m['message'] as String?) ?? 'SFTP 状态错误');
    default:
      return SftpStatusException((m['message'] as String?) ?? 'SFTP 请求失败');
  }
}
