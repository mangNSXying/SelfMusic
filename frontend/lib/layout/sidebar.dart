import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../screens/settings/settings_focus.dart';
import '../screens/settings/settings_search_index.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';
import '../utils/app_exit.dart';
import 'screen_metrics.dart';

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

class _SettingsList extends StatefulWidget {
  final NavigationProvider nav;
  final SettingsItem? selected;
  const _SettingsList({required this.nav, required this.selected});

  @override
  State<_SettingsList> createState() => _SettingsListState();
}

class _SettingsListState extends State<_SettingsList> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    setState(() => _query = value.trim());
  }

  void _clearSearch() {
    _searchCtrl.clear();
    setState(() => _query = '');
  }

  void _openSection(SettingsItem item) {
    widget.nav.openSettings(item);
    // 移动端选中后收起抽屉。
    if (!isWideWindow(MediaQuery.sizeOf(context))) {
      Scaffold.of(context).closeDrawer();
    }
  }

  void _openResult(SettingsSearchEntry entry) {
    // 先挂定位请求，再切分区：新分区首帧即可消费并滚动/高亮。
    SettingsFocusScope.read(context)?.request(entry.id);
    widget.nav.openSettings(entry.section);
    _clearSearch();
    if (!isWideWindow(MediaQuery.sizeOf(context))) {
      Scaffold.of(context).closeDrawer();
    }
  }

  @override
  Widget build(BuildContext context) {
    final results =
        _query.isEmpty ? const <SettingsSearchEntry>[] : searchSettings(_query);
    return Column(
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: TextField(
            controller: _searchCtrl,
            onChanged: _onQueryChanged,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: '搜索设置',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _clearSearch,
                    ),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _query.isEmpty
              ? ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final item in SettingsItem.values)
                      ListTile(
                        dense: true,
                        leading: Icon(item.icon),
                        title: Text(item.label),
                        selected: widget.selected == item,
                        selectedTileColor: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.12),
                        onTap: () => _openSection(item),
                      ),
                  ],
                )
              : _buildResults(context, results),
        ),
      ],
    );
  }

  Widget _buildResults(
      BuildContext context, List<SettingsSearchEntry> results) {
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(
          '没有匹配设置',
          style: TextStyle(
            fontSize: 12,
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        for (final entry in results)
          ListTile(
            dense: true,
            leading: Icon(entry.section.icon, size: 20),
            title: Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                entry.section.label,
                entry.group,
                if (entry.hint != null) entry.hint!,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            onTap: () => _openResult(entry),
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
            // 移动端先收起抽屉，再打开内容区工具页。
            if (!isWideWindow(MediaQuery.sizeOf(context))) {
              Scaffold.of(context).closeDrawer();
            }
            context
                .read<NavigationProvider>()
                .openLibraryInfo(LibraryInfoPage.overview);
          },
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.info_outline),
          title: const Text('关于软件'),
          subtitle: const Text('版本与反馈', style: TextStyle(fontSize: 11)),
          onTap: () {
            // 移动端先收起抽屉，再打开内容区工具页。
            if (!isWideWindow(MediaQuery.sizeOf(context))) {
              Scaffold.of(context).closeDrawer();
            }
            context.read<NavigationProvider>().openAbout();
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
