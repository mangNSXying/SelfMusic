import 'package:flutter/material.dart';

import 'app_dialog_actions.dart';

/// 标准确认弹窗：返回 true 表示用户确认，false/null 表示取消或关闭。
///
/// 统一「取消在左、确认在右」与 destructive 配色，避免各页面重复拼装
/// `showDialog<bool> + AlertDialog + appDialogActions`。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  required String confirmLabel,
  String cancelLabel = '取消',
  bool destructive = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: appDialogActions(
        c,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
        destructive: destructive,
        onCancel: () => Navigator.of(c).pop(false),
        onConfirm: () => Navigator.of(c).pop(true),
      ),
    ),
  );
  return ok == true;
}
