import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/build_stamp.dart';
import '../widgets/app_toast.dart';

/// 反馈收信人。
const String kFeedbackEmail = 'kon@shamiko.site';

/// 应用版本：与 `pubspec.yaml` 的 `version` 保持一致（改版本时同步改这里）。
const String kAppVersion = '1.0.1+3';

/// 侧边栏「关于软件」页：展示软件图标与名字 + 反馈入口。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final versionLabel = kBuildStamp.isNotEmpty
        ? '版本 $kAppVersion（$kBuildStamp）'
        : '版本 $kAppVersion';
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
                Text(
                  versionLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
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
                IconButton(
                  icon: const Icon(Icons.copy_outlined, size: 20),
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
    final body =
        '\n\n---\nSelfMusic $kAppVersion${kBuildStamp.isNotEmpty ? '（$kBuildStamp）' : ''} · ${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    final uri = Uri(
      scheme: 'mailto',
      path: kFeedbackEmail,
      queryParameters: {'subject': 'SelfMusic 反馈', 'body': body},
    );
    try {
      if (await canLaunchUrl(uri)) {
        final ok =
            await launchUrl(uri, mode: LaunchMode.externalApplication);
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
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
