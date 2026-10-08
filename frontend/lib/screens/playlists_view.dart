import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../data/local/local_index.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../utils/collection_sort.dart';
import '../widgets/corner_add_button.dart';
import '../widgets/count_header.dart';
import '../widgets/row_list.dart';
import '../widgets/selection_badge.dart';
import '../widgets/square_card.dart';
import '../widgets/list_selection.dart';
import '../widgets/section_swipe.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_list.dart';
import '../widgets/sort_menu_button.dart';
import '../widgets/view_mode_toggle.dart';

/// 歌单栏：列表页（新建 / 重命名 / 删除 / 长按多选删除）与详情原地子视图。
class PlaylistsView extends StatefulWidget {
  const PlaylistsView({super.key});

  @override
  State<PlaylistsView> createState() => _PlaylistsViewState();
}

class _PlaylistsViewState extends State<PlaylistsView>
    with AutomaticKeepAliveClientMixin, ViewModeState {
  final Selection<int> _sel = Selection<int>();

  /// 滑动档横滑时保持存活：离开可视区即销毁 State，重进会重跑 refresh +
  /// 每行 countOf 首次查询，KeepAlive 使来回滑动零开销。
  @override
  bool get wantKeepAlive => true;

  @override
  ViewModeSlot get viewModeSlot => ViewModeSlot.playlists;

  @override
  AppSettings Function() get appSettings =>
      () => context.read<DirectSourceManager>().settings;

  @override
  void initState() {
    super.initState();
    // 首帧后再刷新，避免 refresh() 的 notifyListeners 在 build 期间触发断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<PlaylistsProvider>();
      if (!p.loaded) p.refresh();
    });
  }

  void _toggleSelect(int id) => setState(() {
        _sel.active = true;
        _sel.toggle(id);
      });

  /// 只作用于当前筛选后可见的歌单（与「已选 N」口径一致）。
  Future<void> _deleteSelected(
      PlaylistsProvider provider, List<PlaylistRow> visible) async {
    final playlists = provider.playlists;
    final names = _sel
        .of(playlists.map((p) => p.id))
        .map((id) => playlists.firstWhere((p) => p.id == id).name)
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定删除选中的 ${names.length} 个歌单？'
            '（仅移除歌单，其中歌曲不会被删除。）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final nav = context.read<NavigationProvider>();
    final player = context.read<PlayerProvider>();
    for (final id in _sel.of(visible.map((p) => p.id)).toList()) {
      if (nav.browsingPlaylistId == id) nav.exitPlaylist();
      final uuid = provider.store.index.playlistUuidOf(id);
      provider.delete(id);
      if (uuid != null) player.onPlaylistDeleted(uuid);
    }
    setState(_sel.cancel);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final provider = context.watch<PlaylistsProvider>();
    // 订阅收窄（T012）：歌单列表只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);
    final direct = context.watch<DirectSourceManager>();
    final q = search.trim().toLowerCase();
    final all = provider.playlists;
    // 搜索内容是歌单中的具体歌曲（标题/歌手），歌单名同样可命中。
    final matchIds = q.isEmpty
        ? const <int>{}
        : provider.store.index.playlistIdsMatchingSong(q);
    final playlists = sortByCollection(
        q.isEmpty
            ? all
            : all
                .where((p) =>
                    p.name.toLowerCase().contains(q) || matchIds.contains(p.id))
                .toList(),
        direct.settings.sortPlaylists,
        (p) => p.name,
        countOf: (p) => provider.countOf(p.id));
    final card = isCard;

    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
              if (_sel.active)
                SelectionBar(
                  total: playlists.length,
                  // 「已选 N」只数可见项；批量动作也只作用于可见项。
                  selectedCount: _sel.of(playlists.map((p) => p.id)).length,
                  onToggleAll: () =>
                      setState(() => _sel.setAll(playlists.map((p) => p.id))),
                  onCancel: () => setState(_sel.cancel),
                  actions: [
                    SelectionAction(
                      icon: Icons.delete,
                      label: '删除选中',
                      onPressed: _sel.of(playlists.map((p) => p.id)).isEmpty
                          ? null
                          : () => _deleteSelected(provider, playlists),
                    ),
                  ],
                ),
              if (_sel.active) const Divider(height: 1),
              if (!_sel.active)
                CountHeader(
                  count: playlists.length,
                  unit: '个歌单',
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SortMenuButton(
                        value: direct.settings.sortPlaylists,
                        scope: SortScope.collections,
                        onChanged: (v) => setState(
                            () => direct.settings.sortPlaylists = v),
                      ),
                      viewModeToggle(),
                    ],
                  ),
                ),
              Expanded(
                child: playlists.isEmpty
                    ? Center(
                        child: Text(all.isEmpty
                            ? '暂无歌单，点右下角「+」创建'
                            : '无匹配歌单'))
                    : card
                        ? SquareCardGrid(
                            itemCount: playlists.length,
                            titleMaxLines: 2,
                            itemBuilder: (c, i) =>
                                _playlistCard(provider, playlists[i]),
                          )
                        : RowList(
                            count: playlists.length,
                            itemBuilder: (c, i) =>
                                _playlistTile(provider, playlists[i]),
                          ),
              ),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: CornerAddButton(
              tooltip: '新建歌单',
              onPressed: () => _createDialog(context, provider),
            ),
          ),
        ],
    );
  }

  Widget _playlistTile(PlaylistsProvider provider, PlaylistRow p) {
    return ListTile(
      selected: _sel.active && _sel.contains(p.id),
      // 歌单行无封面，勾选框顶替图标行首；有封面的行改为叠在封面左上角
      // （见 SongTile / SquareCard）。
      leading: _sel.active
          ? SelectionBadge(
              selected: _sel.contains(p.id),
              onTap: () => _toggleSelect(p.id),
            )
          : const Icon(Icons.queue_music),
      title: Text(p.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text('${provider.countOf(p.id)} 首'),
      trailing: _sel.active ? null : _playlistMenu(provider, p),
      onTap: _sel.active
          ? () => _toggleSelect(p.id)
          : () => context.read<NavigationProvider>().enterPlaylist(p.id),
      onLongPress: _sel.active
          ? () => _toggleSelect(p.id)
          : () => setState(() => _sel.startWith(p.id)),
    );
  }

  Widget _playlistCard(PlaylistsProvider provider, PlaylistRow p) {
    return SquareCard(
      title: p.name,
      titleMaxLines: 2,
      subtitle: '${provider.countOf(p.id)} 首',
      fallbackIcon: Icons.queue_music,
      onTap: _sel.active
          ? () => _toggleSelect(p.id)
          : () => context.read<NavigationProvider>().enterPlaylist(p.id),
      onLongPress: _sel.active
          ? () => _toggleSelect(p.id)
          : () => setState(() => _sel.startWith(p.id)),
      cornerAction: _playlistMenu(provider, p),
      selectionMode: _sel.active,
      selected: _sel.contains(p.id),
      onToggleSelect: () => _toggleSelect(p.id),
    );
  }

  Widget _playlistMenu(PlaylistsProvider provider, PlaylistRow p) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      onSelected: (v) {
        switch (v) {
          case 'rename':
            _renameDialog(context, provider, p);
          case 'delete':
            _confirmDelete(context, provider, p);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'rename', child: Text('重命名')),
        PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    );
  }

  static Future<void> _createDialog(
      BuildContext context, PlaylistsProvider provider) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isEmpty) return;
              Navigator.of(c).pop(t);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty && context.mounted) {
      provider.create(name);
    }
  }

  static Future<void> _renameDialog(
      BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
    final ctrl = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('重命名歌单'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isEmpty) return;
              Navigator.of(c).pop(t);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) provider.rename(p.id, name);
  }

  static Future<void> _confirmDelete(
      BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除歌单'),
        content: Text('确定删除「${p.name}」？其中歌曲不会被删除，仅移除歌单。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      final nav = context.read<NavigationProvider>();
      if (nav.browsingPlaylistId == p.id) nav.exitPlaylist();
      provider.delete(p.id);
    }
  }
}

/// 歌单详情（内容区原地子视图）：外壳（内容壳 + 跟随手势滑动）内嵌统一的
/// [SongList]（与播放器带「歌单页」同一份列表实现：同源、同行形态、同写回语义）。
/// 头部返回按钮返回内容层；搜索跟随全局搜索框。
class PlaylistDetailView extends StatelessWidget {
  final int playlistId;
  const PlaylistDetailView({super.key, required this.playlistId});

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T012）：歌单详情的目标 playlistId 由 widget 参数承载（父级路由
    // 变更会重建本组件），build 内不读取 NavigationProvider 字段；全局搜索由内层
    // [SongList] 自行订阅，故此处不订阅导航状态、区段变更零重建。
    final nav = context.read<NavigationProvider>();
    return SectionSwipe(
      child: SongList(
        playlistId: playlistId,
        onBack: () => nav.exitPlaylist(),
        globalSearch: true,
      ),
    );
  }
}
