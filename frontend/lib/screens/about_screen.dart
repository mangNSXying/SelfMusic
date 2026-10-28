import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/email_share.dart';
import '../platform/harmonyos/ohos_bootstrap.dart' show isOhos;
import '../platform/harmonyos/ohos_platform_bridge.dart';
import '../providers/direct_source_manager.dart';
import '../utils/app_version.dart';
import '../utils/build_stamp.dart';
import '../widgets/app_dialog_actions.dart';
import '../widgets/app_toast.dart';
import '../widgets/row_action_button.dart';
import '../services/log_buffer.dart';

/// 反馈收信人。
const String kFeedbackEmail = 'kon@shamiko.site';

/// 侧边栏「关于软件」页：展示软件图标与名字 + 反馈入口。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final logMinutes = context.select<DirectSourceManager, int>(
        (direct) => direct.settings.logExportMinutes);
    return Scaffold(
      appBar: AppBar(title: const Text('关于软件')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
        children: [
          Center(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.asset(
                    isDark
                        ? 'assets/selfmusic-black.png'
                        : 'assets/selfmusic.png',
                    width: 72,
                    height: 72,
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'SelfMusic',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                FutureBuilder<String>(
                  future: AppVersion.load(),
                  builder: (context, snapshot) {
                    final version = snapshot.data ?? '…';
                    // final versionlabel = '版本 $version';
                    final versionLabel = kBuildStamp.isNotEmpty
                        ? '版本 $version（$kBuildStamp）'
                        : '版本 $version';
                    return Text(
                      versionLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.6)),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.description_outlined),
            title: const Text('收集日志'),
            subtitle: Text('导出最近 $logMinutes 分钟内的应用日志',
                style: const TextStyle(fontSize: 11)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _collectLogs(context),
          ),
          const Divider(height: 1),
          ListTile(
            dense: true,
            leading: const Icon(Icons.mail_outline),
            title: const Text('反馈'),
            subtitle: const Text('$kFeedbackEmail · 调用系统邮件应用',
                style: TextStyle(fontSize: 11)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                RowActionIconButton(
                  icon: Icons.copy_outlined,
                  tooltip: '复制反馈邮箱',
                  onPressed: () => _copyEmail(context),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: () => _sendFeedback(context),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  void _copyEmail(BuildContext context) {
    Clipboard.setData(const ClipboardData(text: kFeedbackEmail));
    AppToast.show('已复制反馈邮箱', isError: false);
  }

  /// 跳转系统默认邮件软件；无可用客户端时复制邮箱并弹窗明示地址。
  Future<void> _sendFeedback(BuildContext context) async {
    if (!context.mounted) return;
    final logMinutes =
        context.read<DirectSourceManager>().settings.logExportMinutes;
    final includeLogs = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('反馈'),
        content: Text('是否携带最近 $logMinutes 分钟的应用日志？（有助于定位 Bug）'),
        actions: appDialogActions(
          c,
          cancelLabel: '不携带',
          confirmLabel: '携带并发送',
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (!context.mounted) return;

    final appVersion = await AppVersion.load();
    final meta =
        'SelfMusic $appVersion${kBuildStamp.isNotEmpty ? '（$kBuildStamp）' : ''} · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

    String extraBody = '';
    if (includeLogs == true) {
      final logPath = await _exportLogsToTemp(logMinutes);
      if (logPath != null) {
        // 优先走「自动带附件」的原生发送（Android 直达邮件应用 /
        // 鸿蒙分享面板 / Linux xdg-email / Windows Thunderbird·Outlook）。
        final attached = await sendEmailWithAttachment(
          to: kFeedbackEmail,
          subject: 'SelfMusic 反馈',
          body: '\n\n---\n$meta',
          attachmentPath: logPath,
        );
        if (attached) return;
        // 附件通道不可用：回退 mailto（正文注明路径，手动附加）。
        extraBody = '\n\n[日志文件：$logPath]\n请在邮件中附上该日志文件。';
      }
    }

    final body = '\n\n---\n$meta$extraBody';
    final uri = Uri(
      scheme: 'mailto',
      path: kFeedbackEmail,
      queryParameters: {'subject': 'SelfMusic 反馈', 'body': body},
    );
    try {
      if (await canLaunchUrl(uri)) {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (ok) return;
      }
    } catch (e) {
      debugPrint('打开邮件应用失败：$e');
    }
    if (!context.mounted) return;
    _showNoMailClient(context);
  }

  void _showNoMailClient(BuildContext context) {
    Clipboard.setData(const ClipboardData(text: kFeedbackEmail));
    AppToast.show('未找到邮件应用，已复制反馈邮箱', isError: false);
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('反馈'),
        content: const SelectableText(
          '未检测到可用的邮件应用，请手动发送邮件至：\n$kFeedbackEmail',
        ),
        actions: [appDialogCloseAction(c, label: '确定')],
      ),
    );
  }

  Future<void> _collectLogs(BuildContext context) async {
    if (!context.mounted) return;
    final logMinutes =
        context.read<DirectSourceManager>().settings.logExportMinutes;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('收集日志'),
        content: Text('将收集应用最近 $logMinutes 分钟内的日志。'
            '如有 Bug 请先复现问题，再点击“收集”。'),
        actions: appDialogActions(
          c,
          cancelLabel: '返回',
          confirmLabel: '收集',
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (proceed != true || !context.mounted) return;

    final now = DateTime.now();
    final fileName =
        'selfmusic_logs_${now.year}${_pad2(now.month)}${_pad2(now.day)}_${_pad2(now.hour)}${_pad2(now.minute)}${_pad2(now.second)}.txt';
    // file_selector 在 Android/iOS/OHOS 上未实现 getSaveLocation（抛
    // UnimplementedError），仅桌面端可用；移动端改用目录选择后自行拼接文件名。
    // 鸿蒙例外：file_selector_ohos 连 getDirectoryPath 都没实现（pigeon
    // 通道无处理器，必抛 channel-error），改走平台桥的保存选择器。
    try {
      if (isOhos) {
        final tempPath = await _exportLogsToTemp(logMinutes);
        if (tempPath == null) {
          throw StateError('临时日志写入失败');
        }
        final savedUri = await OhosPlatformBridge.saveFile(
          suggestedName: fileName,
          sourcePath: tempPath,
        );
        if (savedUri == null) return; // 用户取消。
        if (!context.mounted) return;
        AppToast.show('日志已导出：$savedUri', isError: false);
        return;
      }
      String targetPath;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        final saveLocation = await getSaveLocation(
          suggestedName: fileName,
          confirmButtonText: '保存',
        );
        if (saveLocation == null) return;
        targetPath = saveLocation.path;
      } else {
        final dir = await getDirectoryPath(confirmButtonText: '选择');
        if (dir == null) return;
        targetPath = '$dir/$fileName';
      }
      await LogBuffer.instance
          .exportToPath(targetPath, since: Duration(minutes: logMinutes));
      if (!context.mounted) return;
      AppToast.show('日志已导出：$targetPath', isError: false);
    } catch (e) {
      if (!context.mounted) return;
      AppToast.error(e, '日志导出失败');
    }
  }

  /// 导出日志到缓存子目录 `selfmusic_logs/`（Android FileProvider 按此目录
  /// 授权给邮件应用读取；顺带清理 7 天前的旧日志防堆积）。
  Future<String?> _exportLogsToTemp(int minutes) async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory('${base.path}/selfmusic_logs');
      await dir.create(recursive: true);
      final now = DateTime.now();
      final fileName =
          'selfmusic_logs_${now.year}${_pad2(now.month)}${_pad2(now.day)}_${_pad2(now.hour)}${_pad2(now.minute)}${_pad2(now.second)}.txt';
      final path = '${dir.path}/$fileName';
      await LogBuffer.instance
          .exportToPath(path, since: Duration(minutes: minutes));
      await _pruneOldLogs(dir);
      return path;
    } catch (e) {
      debugPrint('导出临时日志失败：$e');
      return null;
    }
  }

  /// 删除 7 天前导出的临时日志（失败忽略，不影响本次导出）。
  Future<void> _pruneOldLogs(Directory dir) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) await entity.delete();
      }
    } catch (e) {
      debugPrint('清理旧日志失败（忽略）：$e');
    }
  }

  String _pad2(int v) => v.toString().padLeft(2, '0');
}
