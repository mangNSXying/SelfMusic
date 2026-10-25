import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../shortcuts/shortcut_models.dart';
import '../shortcuts/shortcut_settings.dart';
import 'app_toast.dart';
import 'shortcut_recorder_dialog.dart';

class ShortcutSettingsPanel extends StatelessWidget {
  const ShortcutSettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ShortcutSettings>();
    final cs = Theme.of(context).colorScheme;
    final isMac = settings.primaryIsMeta;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        _header(context, '窗口内快捷键', ShortcutScope.window, settings),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '应用窗口聚焦时生效；输入框聚焦时仅 Esc 可用。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        for (final group in ShortcutGroup.values) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            child: Text(
              group.label,
              style: TextStyle(
                color: cs.primary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final action in ShortcutAction.values)
            if (action.group == group)
              _tile(context, settings, action, ShortcutScope.window, isMac),
        ],
        const Divider(height: 32),
        _header(context, '全局快捷键', ShortcutScope.global, settings),
        Card(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '系统级生效，应用在后台时也可控制播放。全局键至少需要 Ctrl、Alt 或 Meta 修饰键；'
              '若与其他软件冲突，系统可能拒绝注册，请更换组合。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        for (final action in ShortcutAction.values)
          if (action.supportsGlobal)
            _tile(context, settings, action, ShortcutScope.global, isMac),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            onPressed: settings.resetAll,
            icon: const Icon(Icons.restart_alt),
            label: const Text('恢复全部默认'),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    String title,
    ShortcutScope scope,
    ShortcutSettings settings,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              final error = settings.resetScope(scope);
              if (error != null) AppToast.show(error);
            },
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    ShortcutSettings settings,
    ShortcutAction action,
    ShortcutScope scope,
    bool isMac,
  ) {
    final binding = settings.bindingFor(action, scope);
    final defaultBinding = settings.defaultsForScope(scope)[action];
    return ListTile(
      dense: true,
      title: Text(action.label),
      subtitle: Text(binding?.describe(isMac: isMac) ?? '未设置'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20),
            tooltip: '设置快捷键',
            visualDensity: VisualDensity.compact,
            onPressed: () => _edit(context, settings, action, scope),
          ),
          IconButton(
            icon: const Icon(Icons.backspace_outlined, size: 20),
            tooltip: '清除快捷键',
            visualDensity: VisualDensity.compact,
            onPressed: binding == null
                ? null
                : () {
                    final error = settings.setBinding(action, scope, null);
                    if (error != null) AppToast.show(error);
                  },
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt, size: 20),
            tooltip: '恢复默认',
            visualDensity: VisualDensity.compact,
            onPressed: binding == defaultBinding
                ? null
                : () {
                    final error = settings.resetAction(action, scope);
                    if (error != null) AppToast.show(error);
                  },
          ),
        ],
      ),
      onTap: () => _edit(context, settings, action, scope),
    );
  }

  Future<void> _edit(
    BuildContext context,
    ShortcutSettings settings,
    ShortcutAction action,
    ShortcutScope scope,
  ) async {
    final binding = await showDialog<ShortcutBinding>(
      context: context,
      builder: (_) => ShortcutRecorderDialog(
        action: action,
        scope: scope,
        initial: settings.bindingFor(action, scope),
      ),
    );
    if (binding == null || !context.mounted) return;
    final error = settings.setBinding(action, scope, binding);
    if (error != null) AppToast.show(error);
  }
}
