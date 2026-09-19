import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_theme.dart';

/// 顶栏：上层 = 汉堡 + 搜索框；下层 = 导航（播放列表/喜欢/播放源/歌曲/专辑/歌手）。
class TopBar extends StatelessWidget {
  final VoidCallback onSidebarToggle;
  const TopBar({
    super.key,
    required this.onSidebarToggle,
  });

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();

    final Widget bar = nav.inSettings
        ? _SettingsTopBar(nav: nav, onSidebarToggle: onSidebarToggle)
        : Column(
            children: [
              _UpperRow(nav: nav, onSidebarToggle: onSidebarToggle),
              _NavBar(nav: nav),
              const Divider(height: 1),
            ],
          );
    // 适配手机状态栏：无 AppBar 时顶栏会顶到状态栏，这里让出顶部安全区。
    return SafeArea(bottom: false, child: bar);
  }
}

class _UpperRow extends StatelessWidget {
  final NavigationProvider nav;
  final VoidCallback onSidebarToggle;
  const _UpperRow({required this.nav, required this.onSidebarToggle});

  @override
  Widget build(BuildContext context) {
    final searchCtrl = TextEditingController(text: nav.search);
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
        ],
      ),
    );
  }
}

class _NavBar extends StatefulWidget {
  final NavigationProvider nav;
  const _NavBar({required this.nav});

  @override
  State<_NavBar> createState() => _NavBarState();
}

class _NavBarState extends State<_NavBar> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 窄屏下导航项横排可横向滑动；宽屏下居中分布。
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 48,
      child: ValueListenableBuilder<double>(
        valueListenable: widget.nav.pageOffset,
        builder: (c, page, _) {
          // 条带跟随：按拖拽页码比例滚动（jumpTo 不触发 ValueNotifier，无重建循环）。
          if (_scroll.hasClients) {
            final max = _scroll.position.maxScrollExtent;
            if (max > 0) {
              final target =
                  max * (page.clamp(0.0, NavSection.values.length - 1.0) /
                      (NavSection.values.length - 1));
              if ((_scroll.offset - target).abs() > 0.5) {
                _scroll.jumpTo(target);
              }
            }
          }
          return ListView.separated(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: NavSection.values.length,
            separatorBuilder: (_, __) => const SizedBox(width: 4),
            itemBuilder: (c, i) {
              final s = NavSection.values[i];
              // 跟手高亮：按与实时页码的距离在相邻两项间插值。
              final w =
                  (1 - (page - i).abs()).clamp(0.0, 1.0);
              final selected = widget.nav.section == s && w > 0.5;
              final color = Color.lerp(
                  colorScheme.onSurface.withValues(alpha: 0.75),
                  colorScheme.primary,
                  w)!;
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => widget.nav.select(s),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? colorScheme.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(s.icon,
                          size: 18,
                          color: Color.lerp(
                              colorScheme.onSurface.withValues(alpha: 0.6),
                              colorScheme.primary,
                              w)),
                      const SizedBox(width: 6),
                      Text(
                        s.label,
                        style: TextStyle(
                          color: color,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
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
