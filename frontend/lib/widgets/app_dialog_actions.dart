import 'package:flutter/material.dart';

/// 标准确认弹窗按钮组：左侧取消（TextButton）、右侧确认（FilledButton）。
///
/// 全 App 的 `AlertDialog.actions` 统一走这里，避免出现「两个 TextButton」
/// 或确认/取消顺序相反的写法。危险操作传 [destructive]：确认键使用
/// `colorScheme.error` 背景 + `onError` 前景，不再用红字叠在强调色底上。
List<Widget> appDialogActions(
  BuildContext context, {
  required VoidCallback onCancel,
  required VoidCallback onConfirm,
  String cancelLabel = '取消',
  required String confirmLabel,
  bool destructive = false,
  bool cancelEnabled = true,
  bool confirmEnabled = true,
}) {
  final cs = Theme.of(context).colorScheme;
  return [
    TextButton(
      onPressed: cancelEnabled ? onCancel : null,
      child: Text(cancelLabel),
    ),
    FilledButton(
      style: destructive
          ? FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
            )
          : null,
      onPressed: confirmEnabled ? onConfirm : null,
      child: Text(confirmLabel),
    ),
  ];
}

/// 单按钮信息弹窗的「关闭」动作。
Widget appDialogCloseAction(
  BuildContext context, {
  String label = '关闭',
}) {
  return TextButton(
    onPressed: () => Navigator.of(context).pop(),
    child: Text(label),
  );
}
