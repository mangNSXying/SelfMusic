import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../shortcuts/shortcut_models.dart';
import '../shortcuts/shortcut_settings.dart';
import '../widgets/app_toast.dart';
import '../widgets/shortcut_recorder_dialog.dart';

class ShortcutScopeScreen extends StatelessWidget {
  const ShortcutScopeScreen({super.key, required this.scope});

  final ShortcutScope scope;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<ShortcutSettings>();
    final isMac = settings.primaryIsMeta;
    final isOhos = Platform.operatingSystem == 'ohos';
    const actions = ShortcutAction.values;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).maybePop();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: Text('${scope.label}快捷键'),
            actions: [
              TextButton(
                onPressed: () {
                  final error = settings.resetScope(scope);
                  if (error != null) AppToast.show(error);
                },
                child: const Text('恢复默认'),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  scope == ShortcutScope.window
                      ? '应用窗口聚焦时生效；输入框聚焦时仅 Esc 可用。'
                      : '系统级生效，应用在后台时也可触发；'
                          '打开设置/播放页等界面类动作会自动恢复窗口。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (scope == ShortcutScope.global)
                Card(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      isOhos
                          ? '所有动作都可设置全局键，留空表示不注册。鸿蒙端至少需要 '
                              'Ctrl 或 Alt 修饰键，不支持 Meta/Command 与单独触发的 '
                              'F1-F24 / 媒体键；若与其他软件冲突，系统可能拒绝注册。'
                          : '所有动作都可设置全局键，留空表示不注册。全局键至少需要 '
                              'Ctrl、Alt 或 Meta 修饰键；F1-F24 与媒体键可单独使用；'
                              '若与其他软件冲突，系统可能拒绝注册，请更换组合。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
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
                for (final action in actions)
                  if (action.group == group)
                    _tile(context, settings, action, isMac),
              ],
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    ShortcutSettings settings,
    ShortcutAction action,
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
            onPressed: () => _edit(context, settings, action),
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
      onTap: () => _edit(context, settings, action),
    );
  }

  Future<void> _edit(
    BuildContext context,
    ShortcutSettings settings,
    ShortcutAction action,
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
    // 录制对话框已明确展示冲突并让用户确认「覆盖保存」，这里直接清掉旧绑定。
    final error =
        settings.setBinding(action, scope, binding, replaceConflicts: true);
    if (error != null) AppToast.show(error);
  }
}
