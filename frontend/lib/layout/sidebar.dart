import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';

/// 侧边导航栏：主要承载设置分区 + 底部明暗切换/退出。
class Sidebar extends StatelessWidget {
  final VoidCallback? onClose;
  const Sidebar({super.key, this.onClose});

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final theme = context.watch<ThemeProvider>();

    return Container(
      width: 260,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _Header(onClose: onClose),
          const Divider(height: 1),
          Expanded(child: _SettingsList(nav: nav)),
          const Divider(height: 1),
          _BottomBar(theme: theme, nav: nav),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback? onClose;
  const _Header({this.onClose});

  @override
  Widget build(BuildContext context) {
    final title = Text(
      'SelfMusic',
      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(Icons.graphic_eq, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 10),
          // 展开时不显示标题？这里始终显示；onClose 为移动端抽屉提供收起按钮
          title,
          if (onClose != null) ...[
            const Spacer(),
            IconButton(icon: const Icon(Icons.close), onPressed: onClose),
          ],
        ],
      ),
    );
  }
}

class _SettingsList extends StatelessWidget {
  final NavigationProvider nav;
  const _SettingsList({required this.nav});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            '设置',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (final item in SettingsItem.values)
          ListTile(
            dense: true,
            leading: Icon(item.icon),
            title: Text(item.label),
            selected: nav.settings == item,
            selectedTileColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            onTap: () {
              nav.openSettings(item);
              // 移动端选中后收起抽屉
              if (NavigationProviderHelper.isNarrow(context)) {
                Navigator.of(context).maybePop();
              }
            },
          ),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  final ThemeProvider theme;
  final NavigationProvider nav;
  const _BottomBar({required this.theme, required this.nav});

  @override
  Widget build(BuildContext context) {
    final isDark = theme.isDark;
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
          title: Text(isDark ? '切换亮色' : '切换暗色'),
          onTap: theme.toggleMode,
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.logout),
          title: const Text('退出'),
          onTap: _exitApp,
        ),
      ],
    );
  }

  /// 退出软件：不留后台，直接终止进程。
  void _exitApp() {
    exit(0);
  }
}

/// 便于 Sidebar 判断是否处于移动端抽屉（窄屏）。
class NavigationProviderHelper {
  static bool isNarrow(BuildContext context) => MediaQuery.of(context).size.width < 900;
  const NavigationProviderHelper._();
}
