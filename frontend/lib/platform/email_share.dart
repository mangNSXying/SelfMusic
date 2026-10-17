import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import 'harmonyos/ohos_bootstrap.dart' show isOhos;

/// 带附件调起系统邮件应用起草反馈邮件（mailto 协议不支持附件，
/// 各平台分别走原生能力）。
///
/// 返回 true 表示已成功把草稿交给邮件应用（或系统分享面板）；
/// 返回 false 时由调用方回退 mailto 流程（正文注明日志路径，手动附加）。
///
/// 平台实现：
/// - Android：`ACTION_SEND` + FileProvider content URI，优先直达默认邮件
///   应用，解析不到退系统选择器（MainActivity 的 share 通道）。
/// - 鸿蒙：systemShare 系统分享面板携带日志文件（EmailShareBridge 桥）。
/// - Linux：xdg-email --attach（xdg-utils，主流桌面发行版自带）。
/// - Windows：依次探测 Thunderbird（-compose attachment）与经典 Outlook
///   （PowerShell COM 起草窗口），都不可用返回 false。
Future<bool> sendEmailWithAttachment({
  required String to,
  required String subject,
  required String body,
  required String attachmentPath,
}) async {
  try {
    if (Platform.isAndroid) {
      const channel = MethodChannel('com.shamiko.selfmusic/share');
      final ok = await channel.invokeMethod<bool>('sendEmailWithAttachment', {
        'to': to,
        'subject': subject,
        'body': body,
        'attachmentPath': attachmentPath,
      });
      return ok == true;
    }
    if (isOhos) {
      const channel = MethodChannel('selfmusic/email');
      final ok = await channel.invokeMethod<bool>('sendEmailWithAttachment', {
        'to': to,
        'subject': subject,
        'body': body,
        'attachmentPath': attachmentPath,
      });
      return ok == true;
    }
    if (Platform.isLinux) {
      return await _sendOnLinux(
        to: to,
        subject: subject,
        body: body,
        attachmentPath: attachmentPath,
      );
    }
    if (Platform.isWindows) {
      return await _sendOnWindows(
        to: to,
        subject: subject,
        body: body,
        attachmentPath: attachmentPath,
      );
    }
  } catch (e) {
    // 通道缺失 / 命令不存在 / 权限异常：交给调用方回退 mailto。
    debugPrint('sendEmailWithAttachment 失败：$e');
  }
  return false;
}

/// Linux：xdg-email（xdg-utils）带 --attach 拉起默认邮件客户端起草。
Future<bool> _sendOnLinux({
  required String to,
  required String subject,
  required String body,
  required String attachmentPath,
}) async {
  try {
    final result = await Process.run('xdg-email', [
      '--subject', subject,
      '--body', body,
      '--attach', attachmentPath,
      to,
    ]);
    return result.exitCode == 0;
  } catch (e) {
    debugPrint('xdg-email 调用失败：$e');
    return false;
  }
}

/// Windows：无通用「带附件起草」标准，依次探测已知客户端。
Future<bool> _sendOnWindows({
  required String to,
  required String subject,
  required String body,
  required String attachmentPath,
}) async {
  if (await _sendWithThunderbird(
      to: to, subject: subject, body: body, attachmentPath: attachmentPath)) {
    return true;
  }
  if (await _sendWithOutlook(
      to: to, subject: subject, body: body, attachmentPath: attachmentPath)) {
    return true;
  }
  return false;
}

/// Thunderbird：`-compose "to=...,subject=...,body=...,attachment=file:///..."`
/// （值用单引号包裹，逗号/换行安全；附件 URI 做百分号编码）。
Future<bool> _sendWithThunderbird({
  required String to,
  required String subject,
  required String body,
  required String attachmentPath,
}) async {
  final exe = await _findThunderbird();
  if (exe == null) return false;
  try {
    final attachmentUri = Uri.file(attachmentPath).toString();
    final compose =
        "to='$to',subject='$subject',body='$body',attachment='$attachmentUri'";
    final result = await Process.run(exe, ['-compose', compose]);
    return result.exitCode == 0;
  } catch (e) {
    debugPrint('Thunderbird 调用失败：$e');
    return false;
  }
}

/// 查找 Thunderbird 可执行文件：PATH（where）→ 常见安装目录 → 注册表
/// App Paths（含 HKCU，覆盖按用户安装）。
Future<String?> _findThunderbird() async {
  // 1) PATH
  try {
    final r = await Process.run('where', ['thunderbird.exe']);
    if (r.exitCode == 0) {
      final first = (r.stdout as String)
          .split(RegExp(r'\r?\n'))
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => '');
      if (first.isNotEmpty && File(first).existsSync()) return first;
    }
  } catch (_) {}

  // 2) 常见安装目录（系统级 + 用户级）
  final env = Platform.environment;
  final roots = <String?>[
    env['ProgramFiles'],
    env['ProgramFiles(x86)'],
    env['ProgramW6432'],
    env['LOCALAPPDATA'] == null
        ? null
        : '${env['LOCALAPPDATA']}\\Programs',
  ];
  for (final root in roots) {
    if (root == null || root.isEmpty) continue;
    final p = '$root\\Mozilla Thunderbird\\thunderbird.exe';
    if (File(p).existsSync()) return p;
  }

  // 3) 注册表 App Paths（reg query；HKLM + HKCU）
  for (final hive in ['HKLM', 'HKCU']) {
    try {
      final r = await Process.run('reg', [
        'query',
        '$hive\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\thunderbird.exe',
        '/ve',
      ]);
      if (r.exitCode != 0) continue;
      final m = RegExp(r'REG_SZ\s+(.+)$', multiLine: true)
          .firstMatch(r.stdout as String);
      final path = m?.group(1)?.trim().replaceAll('"', '');
      if (path != null && path.isNotEmpty && File(path).existsSync()) {
        return path;
      }
    } catch (_) {}
  }
  return null;
}

/// 经典 Outlook：PowerShell COM 起草窗口（CreateItem(0) + Attachments.Add +
/// Display，只打草稿不发送）。仅覆盖已安装经典 Outlook 的环境，
/// 新版 Outlook（olk）不支持 COM 时自然失败回退。
Future<bool> _sendWithOutlook({
  required String to,
  required String subject,
  required String body,
  required String attachmentPath,
}) async {
  Directory? tmpDir;
  try {
    tmpDir = await Directory.systemTemp.createTemp('selfmusic_mail_');
    final script = File('${tmpDir.path}\\send_feedback.ps1');
    await script.writeAsString(_kOutlookScript, flush: true);
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', script.path,
      '-To', to,
      '-Subject', subject,
      '-Body', body,
      '-Attachment', attachmentPath,
    ]);
    return result.exitCode == 0;
  } catch (e) {
    debugPrint('Outlook 调用失败：$e');
    return false;
  } finally {
    // 清理临时脚本（Outlook 起草窗口已独立于脚本存活）。
    try {
      await tmpDir?.delete(recursive: true);
    } catch (_) {}
  }
}

/// Outlook COM 起草脚本（参数经命令行传入，无引号拼接风险；纯 ASCII）。
const String _kOutlookScript = r'''
param(
  [Parameter(Mandatory=$true)][string]$To,
  [Parameter(Mandatory=$true)][string]$Subject,
  [Parameter(Mandatory=$true)][string]$Body,
  [Parameter(Mandatory=$true)][string]$Attachment
)
$ErrorActionPreference = 'Stop'
try {
  $outlook = New-Object -ComObject Outlook.Application
  $mail = $outlook.CreateItem(0)
  $mail.To = $To
  $mail.Subject = $Subject
  $mail.Body = $Body
  [void]$mail.Attachments.Add($Attachment)
  $mail.Display()
  exit 0
} catch {
  exit 1
}
''';
