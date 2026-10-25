import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../shortcuts/shortcut_models.dart';
import '../shortcuts/shortcut_settings.dart';
import 'app_dialog_actions.dart';

Future<void> showShortcutHelpDialog(BuildContext context) {
  final settings = context.read<ShortcutSettings>();
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('快捷键'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section(
                c,
                '窗口内',
                ShortcutAction.values,
                settings,
                ShortcutScope.window,
              ),
              const SizedBox(height: 16),
              _section(
                c,
                '全局',
                ShortcutAction.values.where((e) => e.supportsGlobal).toList(),
                settings,
                ShortcutScope.global,
              ),
            ],
          ),
        ),
      ),
      actions: [appDialogCloseAction(c)],
    ),
  );
}

Widget _section(
  BuildContext context,
  String title,
  List<ShortcutAction> actions,
  ShortcutSettings settings,
  ShortcutScope scope,
) {
  final isMac = settings.primaryIsMeta;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title,
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w600,
          )),
      const SizedBox(height: 4),
      for (final action in actions)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Expanded(child: Text(action.label)),
              Text(
                settings.bindingFor(action, scope)?.describe(isMac: isMac) ??
                    '未设置',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
    ],
  );
}
