import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/sources/music_source.dart';
import '../../../data/sources/sftp_common.dart';
import '../../../data/sources/sftp_direct_source.dart';
import '../../../data/sources/smb_common.dart';
import '../../../data/sources/smb_direct_source.dart';
import '../../../data/sources/webdav_direct_source.dart';
import '../../../providers/direct_source_manager.dart';
import '../../../services/api_client.dart';
import '../../../utils/url_input.dart';
import '../../../widgets/app_dialog_actions.dart';
import '../../../widgets/app_toast.dart';

import 'source_form_fields.dart';
import 'source_form_model.dart';

// ---------------------------------------------------------------------------
// 校验
// ---------------------------------------------------------------------------

/// 校验结果：通过时带落库用的原始 Map，失败时带出错字段与文案。
sealed class SourceValidation {
  const SourceValidation();
}

class SourceValid extends SourceValidation {
  final Map<String, dynamic> raw;
  const SourceValid(this.raw);
}

class SourceInvalid extends SourceValidation {
  /// 出错的字段；跨字段/落库类错误为 null（渲染在弹窗底部）。
  final SourceFieldId? field;
  final String message;
  const SourceInvalid(this.message, {this.field});
}

/// 显式 `http://` 需要用户先打开「允许不安全 HTTP」。
///
/// 校验函数保持纯函数（可单测），这里只把「需要弹确认框」这件事作为结果
/// 返回；弹窗层弹框并开启后重跑校验。
class SourceNeedsHttpConsent extends SourceValidation {
  final String url;
  const SourceNeedsHttpConsent(this.url);
}

/// 统一校验入口：按类型校验 [model]，返回落库用 Map 或结构化错误。
///
/// 替代原先主源/备用源各一套的 `_readWebdavUrl` / `_readSftpForm` /
/// `_readSmbForm` / `_readFbSftpForm` / `_readFbSmbForm`。
SourceValidation validateSource(
  SourceFormModel model, {
  required bool allowInsecureHttp,
}) {
  // 先把协议自身的字段校验完，最后才校验名称：名称是四种协议共同的字段，
  // 放前面会把更具体的错误（端口越界、缺地址…）全盖住，用户要多试几轮。
  final result = _validateFields(model, allowInsecureHttp: allowInsecureHttp);
  if (result is! SourceValid) return result;
  // 名称：备用源没有名称字段（名称继承主源），只在字段存在时校验。
  if (model.has(SourceFieldId.name) && model.text(SourceFieldId.name).isEmpty) {
    return const SourceInvalid('请填写名称', field: SourceFieldId.name);
  }
  return result;
}

SourceValidation _validateFields(
  SourceFormModel model, {
  required bool allowInsecureHttp,
}) {
  switch (model.kind) {
    case SourceKind.local:
      if (model.localFiles.isEmpty && model.text(SourceFieldId.path).isEmpty) {
        return const SourceInvalid('请选择或填写本地目录',
            field: SourceFieldId.path);
      }
      return SourceValid(model.toRawMap());

    case SourceKind.webdav:
      return _validateWebdav(model, allowInsecureHttp: allowInsecureHttp);

    case SourceKind.smb:
      final host = model.text(SourceFieldId.host);
      if (host.isEmpty) {
        return const SourceInvalid('请填写 SMB 主机（IP 或主机名）',
            field: SourceFieldId.host);
      }
      final parsed = smbParseInputPath(model.text(SourceFieldId.share));
      if (parsed.share.isEmpty) {
        return const SourceInvalid('请填写路径（共享名或 共享名/子目录，如 music/flac）',
            field: SourceFieldId.share);
      }
      return SourceValid(model.toRawMap());

    case SourceKind.sftp:
      final host = model.text(SourceFieldId.host);
      if (host.isEmpty) {
        return const SourceInvalid('请填写 SSH 主机', field: SourceFieldId.host);
      }
      final portRaw = model.text(SourceFieldId.port);
      final port = portRaw.isEmpty ? 22 : int.tryParse(portRaw);
      if (port == null || port < 1 || port > 65535) {
        return const SourceInvalid('端口须为 1–65535 的数字（默认 22）',
            field: SourceFieldId.port);
      }
      if (model.text(SourceFieldId.username).isEmpty) {
        return const SourceInvalid('请填写用户名',
            field: SourceFieldId.username);
      }
      if (model.authMethod == SftpAuthMethod.password) {
        if (model.raw(SourceFieldId.password).isEmpty) {
          return const SourceInvalid('请填写密码',
              field: SourceFieldId.password);
        }
      } else {
        if (!model.raw(SourceFieldId.keyPem).contains('PRIVATE KEY')) {
          return const SourceInvalid('请粘贴 PEM 私钥文本（含 BEGIN/END 行）',
              field: SourceFieldId.keyPem);
        }
      }
      return SourceValid(model.toRawMap());
  }
}

SourceValidation _validateWebdav(
  SourceFormModel model, {
  required bool allowInsecureHttp,
}) {
  // 校验前可视化补 https://（原 _readWebdavUrl 的行为）。
  applyHttpsPrefixToController(model[SourceFieldId.baseUrl]);
  final url = model.text(SourceFieldId.baseUrl);
  if (url.isEmpty) {
    return const SourceInvalid('请填写 WebDAV 地址',
        field: SourceFieldId.baseUrl);
  }
  final err = ApiClient.validateEndpointUrl(url, allowHttp: allowInsecureHttp);
  if (err == null) return SourceValid(model.toRawMap());
  // 显式 http:// 且未开启放行 → 交给弹窗层弹「去开启」确认。
  if (urlIsExplicitHttp(url)) return SourceNeedsHttpConsent(url);
  return SourceInvalid(err, field: SourceFieldId.baseUrl);
}

// ---------------------------------------------------------------------------
// 测试连接
// ---------------------------------------------------------------------------

/// 测试连接结果：成功与否、耗时、失败原因、SFTP 主机指纹。
class SourceTestResult {
  final bool ok;
  final Duration elapsed;
  final String? message;
  final String? fingerprint;

  const SourceTestResult({
    required this.ok,
    required this.elapsed,
    this.message,
    this.fingerprint,
  });

  /// 状态芯片文案里的耗时（毫秒，取整）。
  int get elapsedMs => elapsed.inMilliseconds;
}

/// 归一化错误文案：剥掉 Dart 的 `Bad state:` / `StateError:` 前缀
/// （原弹窗 6 处测试连接与保存分支都在重复这一步）。
String normalizeSourceError(Object e) => e
    .toString()
    .replaceFirst(RegExp(r'^(Bad state: |StateError: )'), '');

/// 统一测试连接入口：只做探测，不保存源、不弹窗、不 toast。
///
/// 替代原先 6 个 `_test*` 方法（主源 3 个 + 备用源 3 个）。SFTP 的主机指纹
/// 确认是交互，由调用方拿 [SourceTestResult.fingerprint] 走
/// [confirmSshFingerprint]。
Future<SourceTestResult> testSource(
  SourceFormModel model, {
  required bool allowSelfSigned,
}) async {
  // 先按当前表单校验，避免拿半截配置去连网。
  final v = validateSource(model, allowInsecureHttp: true);
  if (v is SourceInvalid) {
    return SourceTestResult(
      ok: false,
      elapsed: Duration.zero,
      message: v.message,
    );
  }
  final sw = Stopwatch()..start();
  try {
    switch (model.kind) {
      case SourceKind.local:
        return SourceTestResult(ok: true, elapsed: sw.elapsed);

      case SourceKind.webdav:
        await WebdavDirectSource.testConnection(
          baseUrl: model.text(SourceFieldId.baseUrl),
          username: model.text(SourceFieldId.username),
          password: model.raw(SourceFieldId.password),
          allowSelfSigned: allowSelfSigned,
        );

      case SourceKind.smb:
        final parsed = smbParseInputPath(model.text(SourceFieldId.share));
        await SmbDirectSource.testConnection(
          host: model.text(SourceFieldId.host),
          share: parsed.share,
          rootPath: parsed.rootPath,
          username: model.text(SourceFieldId.username),
          password: model.raw(SourceFieldId.password),
          useSmbConnect: false,
        );

      case SourceKind.sftp:
        final fp = await SftpDirectSource.fetchSftpFingerprint(
          host: model.text(SourceFieldId.host),
          port: int.tryParse(model.text(SourceFieldId.port)) ?? 22,
          username: model.text(SourceFieldId.username),
          authMethod: model.authMethod,
          password: model.raw(SourceFieldId.password),
          keyPem: model.raw(SourceFieldId.keyPem),
          keyPassphrase: model.raw(SourceFieldId.keyPassphrase),
        );
        return SourceTestResult(
          ok: true,
          elapsed: sw.elapsed,
          fingerprint: fp,
        );
    }
    return SourceTestResult(ok: true, elapsed: sw.elapsed);
  } catch (e) {
    return SourceTestResult(
      ok: false,
      elapsed: sw.elapsed,
      message: normalizeSourceError(e),
    );
  }
}

// ---------------------------------------------------------------------------
// SFTP 主机指纹（TOFU）
// ---------------------------------------------------------------------------

/// 主机指纹核对：未知主机要求确认并钉住，失配要求核对后更新，匹配直接放行。
///
/// 原弹窗里主源与备用源各有一份逐字相同的实现（各 45 行），现在只此一份。
/// 返回 true 表示指纹已可信（含刚确认/刚更新）。
Future<bool> confirmSshFingerprint(
  BuildContext context, {
  required DirectSourceManager direct,
  required String host,
  required int port,
  required String fingerprint,
}) async {
  final hostPort = sftpHostPort(host, port);
  final pinned = direct.sshFingerprintOf(hostPort);

  if (pinned == null || pinned.isEmpty) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('确认主机指纹'),
        content: Text('首次连接该 SSH 主机，请确认指纹是你的服务器：\n\n$fingerprint\n\n'
            '确认后才会钉住并允许连接。'),
        actions: appDialogActions(
          c,
          confirmLabel: '确认并记住',
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok != true || !context.mounted) return false;
    await direct.pinSshHost(hostPort, fingerprint);
    if (context.mounted) AppToast.show('已确认并记住主机指纹', isError: false);
    return true;
  }

  if (pinned != fingerprint) {
    final update = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('主机指纹变更'),
        content: Text('已记住的指纹：\n$pinned\n\n实际指纹：\n$fingerprint\n\n'
            '可能是中间人或服务器重装，核对无误后再更新。'),
        actions: appDialogActions(
          c,
          confirmLabel: '确认更新',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (update != true || !context.mounted) return false;
    await direct.pinSshHost(hostPort, fingerprint);
    if (context.mounted) AppToast.show('主机指纹已更新', isError: false);
    return true;
  }

  AppToast.show('连接成功，指纹匹配', isError: false);
  return true;
}

/// 该主机是否已钉指纹（保存后据此提示「首次使用前请测试连接」）。
bool isSshPinned(DirectSourceManager direct, String host, int port) {
  final fp = direct.sshFingerprintOf(sftpHostPort(host, port));
  return fp != null && fp.isNotEmpty;
}
