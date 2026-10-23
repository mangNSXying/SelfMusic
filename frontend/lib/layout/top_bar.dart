import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../theme/app_theme.dart';

/// 顶栏：上层 = 汉堡 + 搜索框（提示语随当前区域变化）；下层 = 导航（歌单/喜欢/播放源/歌曲/专辑/歌手）。
class TopBar extends StatelessWidget {
  final VoidCallback onSidebarToggle;
  const TopBar({
    super.key,
    required this.onSidebarToggle,
  });

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T004）：TopBar 仅关注"是否设置页 + 具体设置分区"（改设置分区时
    // 设置标题需刷新，故用 record 而非单独 inSettings）。
    // 高亮由 [_NavBar] 自行订阅 `section`；搜索框由 [_UpperRow] 自持监听。
    final nav = context.read<NavigationProvider>();
    final (inSettings, _) =
        context.select<NavigationProvider, (bool, SettingsItem?)>(
            (n) => (n.inSettings, n.settings));

    final Widget bar = inSettings
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

class _UpperRow extends StatefulWidget {
  final NavigationProvider nav;
  final VoidCallback onSidebarToggle;
  const _UpperRow({required this.nav, required this.onSidebarToggle});

  @override
  State<_UpperRow> createState() => _UpperRowState();
}

class _UpperRowState extends State<_UpperRow> {
  /// 输入状态由 State 持有：build 中新建 controller 会让输入法每次按键
  /// 收到非法 selection/composing（-1），表现为"输入后失焦、键盘收起"。
  late final TextEditingController _searchCtrl;
  late final FocusNode _searchFocus;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: widget.nav.search);
    _searchFocus = FocusNode();
    widget.nav.addListener(_syncFromNav);
    _searchCtrl.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.nav.removeListener(_syncFromNav);
    _searchCtrl.removeListener(_onTextChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 外部清空（clearSearch）时同步文本；只改文本、给合法光标位，保留焦点。
  void _syncFromNav() {
    if (widget.nav.search == _searchCtrl.text) return;
    _searchCtrl.value = TextEditingValue(
      text: widget.nav.search,
      selection: TextSelection.collapsed(offset: widget.nav.search.length),
    );
  }

  /// clear 图标随文本自更新（不再依赖整树重建）。
  void _onTextChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final nav = widget.nav;
    // 提示语随区域变化（源名/源内歌曲/歌单歌曲……）；输入期间不变，
    // 故不会因每次按键重建输入行。
    final hint =
        context.select<NavigationProvider, String>((n) => n.searchHint);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
              icon: const Icon(Icons.menu),
              tooltip: '伸缩侧边栏',
              onPressed: widget.onSidebarToggle),
          const SizedBox(width: 4),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              focusNode: _searchFocus,
              onChanged: (v) => nav.setSearch(v),
              onSubmitted: (v) {
                nav.setSearch(v);
                // 键盘「搜索/完成」视为手动收起输入框 → 失焦（焦点保持仅限搜索期）。
                _searchFocus.unfocus();
              },
              onTapOutside: (_) => _searchFocus.unfocus(),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: hint,
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: '清空搜索',
                        onPressed: () {
                          // 仅清空并保持焦点（手动去焦用键盘收起/点击别处）。
                          _searchCtrl.clear();
                          nav.clearSearch();
                          _searchFocus.requestFocus();
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
    // 订阅收窄（T004）：高亮只依赖 `section`；拖拽期跟手条带/高亮由
    // pageOffset（ValueNotifier）独立逐帧驱动，避免每次区段变更牵连整树。
    final section =
        context.select<NavigationProvider, NavSection>((n) => n.section);
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
              final target = max *
                  (page.clamp(0.0, NavSection.values.length - 1.0) /
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
              final w = (1 - (page - i).abs()).clamp(0.0, 1.0);
              final selected = section == s && w > 0.5;
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
              IconButton(
                  icon: const Icon(Icons.menu),
                  tooltip: '伸缩侧边栏',
                  onPressed: onSidebarToggle),
              const SizedBox(width: 4),
              IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回',
                  onPressed: nav.closeSettings),
              const SizedBox(width: 8),
              Text(nav.settings?.label ?? '设置',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
        ),
        const Divider(height: 1),
      ],
    );
  }
}
