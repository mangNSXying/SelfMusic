import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/settings/shortcut_scope_screen.dart';
import '../screens/settings/settings_focus.dart';
import '../shortcuts/shortcut_models.dart';
import '../shortcuts/shortcut_settings.dart';
import '../theme/app_theme.dart';
import 'settings_layout.dart';
import 'settings_section_header.dart';
import 'settings_tile.dart';

class ShortcutSettingsPanel extends StatelessWidget {
  const ShortcutSettingsPanel({super.key, this.footer});

  /// 追加在快捷键列表后的内容（系统页用于承载桌面和后台/诊断）。
  final Widget? footer;

  Widget _anchor(String label, Widget child) => SettingsFocusAnchor(
        id: settingsAnchorId(SettingsItem.system, label),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ShortcutSettings>();
    final windowCount =
        settings.windowBindings.values.where((b) => b != null).length;
    final globalCount =
        settings.globalBindings.values.where((b) => b != null).length;
    return SettingsPage(
      children: [
        const SettingsSectionHeader('快捷键'),
        const SettingsGroupNote('窗口内与全局快捷键分别设置，点击进入对应列表。'),
        _anchor(
          '窗口内',
          SettingsTile.action(
            title: '窗口内',
            description: '应用窗口聚焦时生效 · 已设置 $windowCount 项',
            label: '设置',
            onTap: () => _openScope(context, ShortcutScope.window),
          ),
        ),
        _anchor(
          '全局',
          SettingsTile.action(
            title: '全局',
            description: '应用在后台时也可触发 · 已设置 $globalCount 项',
            label: '设置',
            onTap: () => _openScope(context, ShortcutScope.global),
          ),
        ),
        if (footer != null) ...[
          const SettingsGroupDivider(),
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
