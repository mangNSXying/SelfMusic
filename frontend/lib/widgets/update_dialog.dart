import 'package:flutter/material.dart';

import '../services/haptics.dart';
import '../services/update_service.dart';
import 'app_dialog_actions.dart';

/// 更新弹窗的用户选择。
enum UpdateDialogResult {
  /// 取消：不做任何记录，下次启动仍会提醒。
  dismiss,

  /// 之后提醒：随机延后若干天，期间启动检查保持静默。
  snooze,

  /// 不再提醒：忽略当前版本，出现更高版本时仍会提醒。
  skipVersion,

  /// 更新：跳转浏览器打开下载链接。
  openDownload,
}

/// 发现新版本弹窗：展示更新说明 + 取消 / 之后提醒 / 不再提醒 / 更新。
///
/// 关闭弹窗（返回/点遮罩）按「取消」处理，不写任何提醒状态。
Future<UpdateDialogResult> showUpdateDialog(
  BuildContext context, {
  required ReleaseInfo release,
  required String currentVersion,
  VoidCallback? onOpenDownload,
}) async {
  final result = await showDialog<UpdateDialogResult>(
    context: context,
    builder: (c) {
      final theme = Theme.of(c);
      final cs = theme.colorScheme;
      final body = release.body.trim();
      return AlertDialog(
        title: Text('发现新版本 ${release.versionLabel}'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '当前版本 $currentVersion',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 12),
            // 更新说明可能很长：限定高度并独立滚动，不把按钮挤出屏幕。
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: SelectableText(
                  body.isEmpty ? '该版本未提供更新说明。' : body,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
            ),
          ],
        ),
        // 四个按钮沿用全局主题样式（合计约 328dp），窄屏动作区放不下一行；
        // 统一经 appDialogActionGroup 的 Wrap 折返，而不是 OverflowBar 竖排。
        actions: appDialogActionGroup([
          TextButton(
            onPressed: () {
              Haptics.fire(HapticStrength.light);
              Navigator.of(c).pop(UpdateDialogResult.dismiss);
            },
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Haptics.fire(HapticStrength.light);
              Navigator.of(c).pop(UpdateDialogResult.snooze);
            },
            child: const Text('之后提醒'),
          ),
          TextButton(
            onPressed: () {
              Haptics.fire(HapticStrength.light);
              Navigator.of(c).pop(UpdateDialogResult.skipVersion);
            },
            child: const Text('不再提醒'),
          ),
          FilledButton(
            onPressed: () {
              Haptics.fire(HapticStrength.light);
              Navigator.of(c).pop(UpdateDialogResult.openDownload);
            },
            child: const Text('更新'),
          ),
        ]),
      );
    },
  );
  if (result == UpdateDialogResult.openDownload && context.mounted) {
    onOpenDownload?.call();
  }
  return result ?? UpdateDialogResult.dismiss;
}
