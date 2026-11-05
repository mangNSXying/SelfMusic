import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_dialog_actions.dart';

/// 单值文本输入弹窗（设置项 / 歌单名 / 设备名 / 新建文件夹共用）。
///
/// 返回去除首尾空白后的文本；取消或（[allowEmpty] = false 时）空串返回 null。
Future<String?> showTextInputDialog({
  required BuildContext context,
  required String title,
  String initial = '',
  String? hintText,
  String? labelText,
  String? description,
  String? helperText,
  String? footer,
  String confirmLabel = '确定',
  bool numeric = false,
  bool decimal = false,
  bool allowEmpty = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (description != null) ...[
            Text(description, style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
          TextField(
            controller: controller,
            autofocus: true,
            keyboardType: numeric
                ? TextInputType.number
                : decimal
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : null,
            inputFormatters: numeric
                ? [FilteringTextInputFormatter.digitsOnly]
                : decimal
                    ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
                    : null,
            decoration: InputDecoration(
              hintText: hintText,
              labelText: labelText,
              helperText: helperText,
            ),
          ),
          if (footer != null) ...[
            const SizedBox(height: 8),
            Text(footer, style: Theme.of(c).textTheme.bodySmall),
          ],
        ],
      ),
      actions: appDialogActions(
        c,
        confirmLabel: confirmLabel,
        onCancel: () => Navigator.of(c).pop(),
        onConfirm: () => Navigator.of(c).pop(controller.text.trim()),
      ),
    ),
  );
  controller.dispose();
  if (!allowEmpty && (result == null || result.isEmpty)) return null;
  return result;
}
