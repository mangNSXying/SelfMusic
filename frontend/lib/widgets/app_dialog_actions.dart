import 'package:flutter/material.dart';

/// 对话框动作按钮组：用 [Wrap] 承载 [actions]，保持全局按钮主题样式不变。
///
/// `AlertDialog.actions` 默认走 `OverflowBar`：一行放不下时整体切换成竖排，
/// 每枚按钮各占一行（窄屏上很突兀）。这里统一包一层 [Wrap]，空间不足时
/// 按行折返成两行；单行/两枚按钮的常规弹窗视觉不变。
///
/// 返回 `List<Widget>` 是为了兼容既有 `actions: appDialogActions(...)` 与
/// `...appDialogActions(...)` 两种用法。
List<Widget> appDialogActionGroup(List<Widget> actions) {
  if (actions.isEmpty) return const [];
  return [
    Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: actions,
    ),
  ];
}

/// 标准确认弹窗按钮组：左侧取消（TextButton）、右侧确认（FilledButton）。
///
/// 全 App 的 `AlertDialog.actions` 统一走这里，避免出现「两个 TextButton」
/// 或确认/取消顺序相反的写法。危险操作传 [destructive]：确认键使用
/// `colorScheme.error` 背景 + `onError` 前景，不再用红字叠在强调色底上。
///
/// [leading] 为取消键之前的补充动作（如「+ 添加区间」），与取消/确认同处
/// 一个 [Wrap]，窄屏时一起折返，不再单独占行。
List<Widget> appDialogActions(
  BuildContext context, {
  required VoidCallback onCancel,
  required VoidCallback onConfirm,
  String cancelLabel = '取消',
  required String confirmLabel,
  bool destructive = false,
  bool cancelEnabled = true,
  bool confirmEnabled = true,
  List<Widget> leading = const [],
}) {
  final cs = Theme.of(context).colorScheme;
  return appDialogActionGroup([
    ...leading,
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
  ]);
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
