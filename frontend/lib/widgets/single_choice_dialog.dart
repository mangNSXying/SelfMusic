import 'package:flutter/material.dart';

/// 单选列表弹窗（设置页各选项共用）。
///
/// [asRadio] = true 使用 `RadioListTile`（选中即关闭）；false 使用
/// `SimpleDialogOption` + 尾部对勾。[hintOf] / [subtitleOf] 为可选的副文案。
Future<T?> showSingleChoiceDialog<T>({
  required BuildContext context,
  required String title,
  required List<T> values,
  required T current,
  required String Function(T) labelOf,
  String Function(T)? hintOf,
  String Function(T)? subtitleOf,
  bool asRadio = false,
}) {
  return showDialog<T>(
    context: context,
    builder: (c) {
      if (asRadio) {
        return SimpleDialog(
          title: Text(title),
          children: [
            RadioGroup<T>(
              groupValue: current,
              onChanged: (v) {
                if (v != null) Navigator.of(c).pop(v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final v in values)
                    RadioListTile<T>(
                      title: Text(labelOf(v)),
                      subtitle: subtitleOf == null ? null : Text(subtitleOf(v)),
                      value: v,
                    ),
                ],
              ),
            ),
          ],
        );
      }
      return SimpleDialog(
        title: Text(title),
        children: [
          for (final v in values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(c).pop(v),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Expanded(child: _label(c, v, labelOf, hintOf, subtitleOf)),
                    if (v == current)
                      Icon(Icons.check, color: Theme.of(c).colorScheme.primary),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

Widget _label<T>(
  BuildContext c,
  T value,
  String Function(T) labelOf,
  String Function(T)? hintOf,
  String Function(T)? subtitleOf,
) {
  final label = Text(labelOf(value));
  final hint = hintOf?.call(value);
  final subtitle = subtitleOf?.call(value);
  if (hint == null && subtitle == null) return label;
  final muted = Theme.of(c).textTheme.bodySmall?.copyWith(
        color: Theme.of(c).colorScheme.onSurface.withValues(alpha: 0.6),
      );
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      label,
      if (hint != null) ...[
        const SizedBox(height: 2),
        Text(hint, style: Theme.of(c).textTheme.bodySmall),
      ],
      if (subtitle != null) Text(subtitle, style: muted),
    ],
  );
}
