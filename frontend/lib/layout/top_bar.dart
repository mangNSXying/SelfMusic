import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_theme.dart';

/// 顶栏：上层 = 汉堡 + 搜索框；下层 = 导航（播放列表/喜欢/播放源/歌曲/专辑/歌手）。
class TopBar extends StatelessWidget {
  final VoidCallback onSidebarToggle;
  final VoidCallback onQueueToggle;
  final bool queueActive;
  const TopBar({
    super.key,
    required this.onSidebarToggle,
    required this.onQueueToggle,
    this.queueActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();

    if (nav.inSettings) {
      return _SettingsTopBar(nav: nav, onSidebarToggle: onSidebarToggle);
    }

    return Column(
      children: [
        _UpperRow(nav: nav, onSidebarToggle: onSidebarToggle, onQueueToggle: onQueueToggle, queueActive: queueActive),
        _NavBar(nav: nav),
        const Divider(height: 1),
      ],
    );
  }
}

class _UpperRow extends StatelessWidget {
  final NavigationProvider nav;
  final VoidCallback onSidebarToggle;
  final VoidCallback onQueueToggle;
  final bool queueActive;
  const _UpperRow({required this.nav, required this.onSidebarToggle, required this.onQueueToggle, required this.queueActive});

  @override
  Widget build(BuildContext context) {
    final searchCtrl = TextEditingController(text: nav.search);
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(icon: const Icon(Icons.menu), tooltip: '伸缩侧边栏', onPressed: onSidebarToggle),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: searchCtrl,
              onChanged: (v) => nav.setSearch(v),
              onSubmitted: (v) => nav.setSearch(v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜索标题 / 艺术家',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          searchCtrl.clear();
                          nav.clearSearch();
                          FocusScope.of(context).unfocus();
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(queueActive ? Icons.queue_music : Icons.playlist_play),
            tooltip: '播放队列',
            onPressed: onQueueToggle,
            color: queueActive ? colorScheme.primary : null,
          ),
        ],
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  final NavigationProvider nav;
  const _NavBar({required this.nav});

  @override
  Widget build(BuildContext context) {
    // 窄屏下导航项横排可横向滑动；宽屏下居中分布。
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: NavSection.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (c, i) {
          final s = NavSection.values[i];
          final selected = nav.section == s;
          return InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => nav.select(s),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? colorScheme.primary.withValues(alpha: 0.12) : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(s.icon, size: 18, color: selected ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.6)),
                  const SizedBox(width: 6),
                  Text(
                    s.label,
                    style: TextStyle(
                      color: selected ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.75),
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SettingsTopBar extends StatelessWidget {
  final NavigationProvider nav;
  final VoidCallback onSidebarToggle;
  const _SettingsTopBar({required this.nav, required this.onSidebarToggle});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              IconButton(icon: const Icon(Icons.menu), tooltip: '伸缩侧边栏', onPressed: onSidebarToggle),
              const SizedBox(width: 4),
              IconButton(icon: const Icon(Icons.arrow_back), tooltip: '返回', onPressed: nav.closeSettings),
              const SizedBox(width: 8),
              Text(nav.settings?.label ?? '设置', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
