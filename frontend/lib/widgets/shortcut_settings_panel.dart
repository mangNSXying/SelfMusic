import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/settings/shortcut_scope_screen.dart';
import '../shortcuts/shortcut_models.dart';
import '../shortcuts/shortcut_settings.dart';
import 'settings_section_header.dart';

class ShortcutSettingsPanel extends StatelessWidget {
  const ShortcutSettingsPanel({super.key, this.footer});

  /// 追加在快捷键列表后的内容（常规页用于承载「备份与迁移」入口）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ShortcutSettings>();
    final windowCount =
        settings.windowBindings.values.where((b) => b != null).length;
    final globalCount =
        settings.globalBindings.values.where((b) => b != null).length;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        const SettingsSectionHeader('快捷键'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '窗口内与全局快捷键分别设置，点击进入对应列表。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.keyboard_outlined),
          title: const Text('窗口内快捷键'),
          subtitle: Text('应用窗口聚焦时生效 · 已设置 $windowCount 项'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openScope(context, ShortcutScope.window),
        ),
        ListTile(
          leading: const Icon(Icons.public),
          title: const Text('全局快捷键'),
          subtitle: Text('应用在后台时也可触发 · 已设置 $globalCount 项'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _openScope(context, ShortcutScope.global),
        ),
        if (footer != null) ...[
          const Divider(height: 32),
          footer!,
        ],
      ],
    );
  }

  void _openScope(BuildContext context, ShortcutScope scope) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ShortcutScopeScreen(scope: scope),
      ),
    );
  }
}
