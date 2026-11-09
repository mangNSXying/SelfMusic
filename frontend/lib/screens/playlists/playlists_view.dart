import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../data/local/local_index.dart';
import '../../navigation/detail_target.dart';
import '../../layout/screen_metrics.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlists_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/collection_sort.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/corner_add_button.dart';
import '../../widgets/count_header.dart';
import '../../widgets/detail_presentation.dart';
import '../../widgets/list_detail_split.dart';
import '../../widgets/row_list.dart';
import '../../widgets/selection_badge.dart';
import '../../widgets/square_card.dart';
import '../../widgets/list_selection.dart';
import '../../widgets/selection_bar.dart';
import '../../widgets/sort_menu_button.dart';
import '../../widgets/view_mode_toggle.dart';

import 'playlist_detail_view.dart';
import 'playlist_dialogs.dart';

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
        actions: appDialogActions(
          c,
          confirmLabel: '删除',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
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
        countOf: (p) => provider.countOf(p.id),
        zhAware: false);
    final card = isCard;
    // 大横屏 + 列表模式：左列表 / 右详情（歌单详情不再整页替换，左栏保活）。
    // 按自身分组判定：离屏缓存期间重建时全局分组可能已是别的页。
    final split = splitDetailActive(context, section: NavSection.playlists);
    final selectedId = context.select<NavigationProvider, int?>(
        (n) => split ? n.browsingPlaylistId : null);

    final listPane = CornerFabLayer(
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_sel.active)
            SelectionBar(
              total: playlists.length,
              // 「已选 N」只数可见项；批量动作也只作用于可见项。
              selectedCount: _sel.of(playlists.map((p) => p.id)).length,
              onSelectAll: () =>
                  setState(() => _sel.addAll(playlists.map((p) => p.id))),
              onSelectNone: () => setState(_sel.clearAll),
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
          if (!_sel.active)
            CountHeader(
              count: playlists.length,
              unit: '个歌单',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  viewModeToggle(),
                  SortMenuButton(
                    value: direct.settings.sortPlaylists,
                    scope: SortScope.collections,
                    onChanged: (v) =>
                        setState(() => direct.settings.sortPlaylists = v),
                  ),
                ],
              ),
            ),
          Expanded(
            child: playlists.isEmpty
                ? Center(child: Text(all.isEmpty ? '暂无歌单，点右下角「+」创建' : '无匹配歌单'))
                : card
                    ? SquareCardGrid(
                        itemCount: playlists.length,
                        titleMaxLines: 2,
                        itemBuilder: (c, i) =>
                            _playlistCard(provider, playlists[i]),
                      )
                    : RowList(
                        // 分栏↔整页切换会重建列表：靠 PageStorage 记住滚动位置。
                        key: const PageStorageKey<String>('playlists-list'),
                        count: playlists.length,
                        itemBuilder: (c, i) => _playlistTile(
                          provider,
                          playlists[i],
                          active: split && selectedId == playlists[i].id,
                        ),
                      ),
          ),
        ],
      ),
      fab: CornerAddButton(
        tooltip: '新建歌单',
        onPressed: () => showCreatePlaylistDialog(context, provider),
      ),
    );

    return ListDetailSplit(
      enabled: split,
      listWidth: ScreenMetrics.of(context).listPaneWidth,
      list: listPane,
      detail: DetailPane(
        // 歌单详情复用同一份实现（pane：栏内不包 SectionSwipe——横滑属于
        // 外层分组 Pager，栏内再套一层会抢手势）。
        detail: selectedId == null
            ? null
            : PlaylistDetailView(
                playlistId: selectedId,
                presentation: DetailPresentation.pane,
              ),
        detailKey: selectedId,
        emptyIcon: Icons.queue_music,
        emptyText: '从左侧选择歌单查看歌曲',
        duration: direct.settings.playerTransition == PlayerTransition.none
            ? Duration.zero
            : kDetailPaneMotion,
      ),
    );
  }

  /// 打开歌单（宽屏右栏/整页分流；重复点同一行不再触发区域切换）。
  void _openPlaylist(BuildContext context, int id) {
    openDetail(context, PlaylistTarget(id));
  }

  Widget _playlistTile(PlaylistsProvider provider, PlaylistRow p,
      {bool active = false}) {
    return GestureDetector(
      // 桌面右键：在指针处弹出与三点按钮相同的菜单；多选态不响应（与隐藏按钮一致）。
      onSecondaryTapDown: _sel.active
          ? null
          : (d) => _openPlaylistMenuAt(provider, p, d.globalPosition),
      child: ListTile(
        selected: _sel.active && _sel.contains(p.id),
        // 分栏时高亮右栏当前歌单（多选态优先用 selected 的既有配色）。
        tileColor: active && !_sel.active
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
            : null,
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
            : () => _openPlaylist(context, p.id),
        onLongPress: _sel.active
            ? () => _toggleSelect(p.id)
            : () => setState(() => _sel.startWith(p.id)),
      ),
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
          : () => _openPlaylist(context, p.id),
      onLongPress: _sel.active
          ? () => _toggleSelect(p.id)
          : () => setState(() => _sel.startWith(p.id)),
      cornerAction: _playlistMenu(provider, p),
      selectionMode: _sel.active,
      selected: _sel.contains(p.id),
      onToggleSelect: () => _toggleSelect(p.id),
      onSecondaryTapDown: _sel.active
          ? null
          : (d) => _openPlaylistMenuAt(provider, p, d.globalPosition),
    );
  }

  /// 歌单菜单项（三点按钮与右键菜单共用）。
  static const List<PopupMenuEntry<String>> _playlistMenuItems = [
    PopupMenuItem(value: 'rename', child: Text('重命名')),
    PopupMenuItem(value: 'delete', child: Text('删除')),
  ];

  Widget _playlistMenu(PlaylistsProvider provider, PlaylistRow p) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      onSelected: (v) => _handlePlaylistMenu(provider, p, v),
      itemBuilder: (_) => _playlistMenuItems,
    );
  }

  /// 歌单菜单选中回调（三点按钮与右键菜单共用）。
  void _handlePlaylistMenu(
      PlaylistsProvider provider, PlaylistRow p, String v) {
    switch (v) {
      case 'rename':
        showRenamePlaylistDialog(context, provider, p);
      case 'delete':
        confirmDeletePlaylist(context, provider, p);
    }
  }

  /// 右键：在指针位置弹出与三点按钮相同的菜单。
  Future<void> _openPlaylistMenuAt(
      PlaylistsProvider provider, PlaylistRow p, Offset globalPosition) async {
    final picked = await showContextMenuAt<String>(
      context,
      globalPosition,
      items: _playlistMenuItems,
    );
    if (picked != null && mounted) _handlePlaylistMenu(provider, p, picked);
  }
}
