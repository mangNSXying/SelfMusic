import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../screens/about_screen.dart';
import '../screens/library_info_screen.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';
import '../utils/app_exit.dart';

/// 侧边导航栏：主要承载设置分区 + 底部明暗切换/退出。
class Sidebar extends StatelessWidget {
  const Sidebar({super.key});

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T007）：侧栏只关注当前设置分区（高亮）；区段/搜索/播放页变更
    // 不再重建侧栏。
    final nav = context.read<NavigationProvider>();
    final settings =
        context.select<NavigationProvider, SettingsItem?>((n) => n.settings);
    final theme = context.watch<ThemeProvider>();

    // 用 Material 承载底色：ListTile 的选中底色/墨迹画在最近的 Material 上，
    // 若外层是 ColoredBox 会被盖住（选中分区看不出高亮）。
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: 260,
        child: SafeArea(
          child: Column(
            children: [
              const _Header(),
              const Divider(height: 1),
              Expanded(child: _SettingsList(nav: nav, selected: settings)),
              const Divider(height: 1),
              _BottomBar(theme: theme),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final title = Text(
      'SelfMusic',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context)
          .textTheme
          .titleLarge
          ?.copyWith(fontWeight: FontWeight.bold),
    );
    // 浅色背景用 selfmusic.png，深色背景用 selfmusic-black.png。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final logo = Image.asset(
      isDark ? 'assets/selfmusic-black.png' : 'assets/selfmusic.png',
      width: 34,
      height: 34,
      fit: BoxFit.cover,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: logo),
          const SizedBox(width: 10),
          // 大字号下标题不撑破 260 宽的侧栏
          Expanded(child: title),
        ],
      ),
    );
  }
}

class _SettingsList extends StatelessWidget {
  final NavigationProvider nav;
  final SettingsItem? selected;
  const _SettingsList({required this.nav, required this.selected});

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
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.6),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (final item in SettingsItem.values)
          ListTile(
            dense: true,
            leading: Icon(item.icon),
            title: Text(item.label),
            selected: selected == item,
            selectedTileColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
            onTap: () {
              nav.openSettings(item);
              // 移动端选中后收起抽屉。
              if (NavigationProviderHelper.isNarrow(context)) {
                Scaffold.of(context).closeDrawer();
              }
            },
          ),
      ],
    );
  }
}

class _BottomBar extends StatelessWidget {
  final ThemeProvider theme;
  const _BottomBar({required this.theme});

  @override
  Widget build(BuildContext context) {
    final isDark = theme.isDark;
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: const Icon(Icons.bar_chart_outlined),
          title: const Text('歌曲信息'),
          subtitle: const Text('歌曲信息统计与分布', style: TextStyle(fontSize: 11)),
          onTap: () {
            // 移动端先收起抽屉，再压入信息页。
            if (NavigationProviderHelper.isNarrow(context)) {
              Scaffold.of(context).closeDrawer();
            }
            Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const LibraryInfoScreen()));
          },
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.info_outline),
          title: const Text('关于软件'),
          subtitle: const Text('版本与反馈', style: TextStyle(fontSize: 11)),
          onTap: () {
            // 移动端先收起抽屉，再压入关于页。
            if (NavigationProviderHelper.isNarrow(context)) {
              Scaffold.of(context).closeDrawer();
            }
            Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AboutScreen()));
          },
        ),
        ListTile(
          dense: true,
          leading: Icon(_iconFor(theme.mode)),
          title: Text(_labelFor(theme.mode, isDark)),
          onTap: theme.cycleMode,
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.logout),
          title: const Text('退出'),
          onTap: () => confirmExitApp(context),
        ),
      ],
    );
  }
}

IconData _iconFor(ThemeMode m) => switch (m) {
      ThemeMode.system => Icons.brightness_auto,
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
    };

String _labelFor(ThemeMode m, bool effectiveDark) {
  return switch (m) {
    ThemeMode.system => '跟随系统（当前${effectiveDark ? '深色' : '浅色'}）',
    ThemeMode.light => '切换深色',
    ThemeMode.dark => '切换浅色',
  };
}

/// 便于 Sidebar 判断是否处于移动端抽屉（窄屏）。
class NavigationProviderHelper {
  static bool isNarrow(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return !(size.width >= 900 || size.width > size.height);
  }

  const NavigationProviderHelper._();
}
