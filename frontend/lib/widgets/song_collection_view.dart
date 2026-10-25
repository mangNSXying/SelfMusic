import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../utils/collection_sort.dart';
import '../utils/song_groups.dart';
import '../utils/source_folders.dart';
import 'count_header.dart';
import 'list_selection.dart';
import 'row_action_button.dart';
import 'row_list.dart';
import 'selection_badge.dart';
import 'selection_bar.dart';
import 'song_row_view.dart';
import 'song_tile.dart';
import 'sort_menu_button.dart';
import 'toolbar_icon_button.dart';

/// 文件夹模式下的导航方式：
/// - [flat]：按「直接父级文件夹」平铺分组（歌单详情 / 喜欢 / 歌曲）；
/// - [recursive]：逐级钻取（播放源页，保留旧深目录导航与面包屑）。
enum FolderNavigation { flat, recursive }

/// 四个歌曲列表页（歌单详情 / 喜欢 / 歌曲 / 播放源详情）的统一实现。
///
/// 负责：分类方式（无 / 文件夹 / 专辑）、折叠持久化、分组缓存、多选、
/// 计数/排序栏、行渲染；分页语义（播放队列/锚点/菜单项）由调用方以回调注入。
class SongCollectionView extends StatefulWidget {
  /// 展示/选择/播放的歌曲列表（已按排列方式排序、已按搜索词过滤）。
  final List<Song> songs;

  /// 搜索中：强制平铺（不分组、不钻取），与各页现状一致。
  final bool searching;

  /// 折叠状态的持久化 key（`playlist:12` / `favorites` / `songs` / `source:xxx`）。
  final String collectionKey;

  final SongGroupMode groupMode;
  final ValueChanged<SongGroupMode> onGroupModeChanged;

  final CollectionSort sort;
  final ValueChanged<CollectionSort> onSortChanged;
  final SortScope sortScope;

  /// 是否显示排列按钮（所有接入页均显示）。
  final bool showSort;

  /// 文件夹选项的显式文案（播放源页传「文件夹（逐级）」）。
  final String? folderLabel;

  /// 点歌：`list` 为当前层级展示列表，`index` 为其中下标。
  final void Function(List<Song> list, int index) onPlay;

  /// 组播/文件夹递归播：传入该组（或该文件夹下递归）歌曲。
  final void Function(List<Song> list) onPlayGroup;

  /// 行内歌曲的源（缓存/删除菜单）；为 null 时不提供直连源操作。
  final MusicSource? Function(Song song)? sourceOf;

  /// 追加到行菜单末尾的自定义项（歌单上移/下移/移除）。
  final List<PopupMenuEntry<String>> Function(Song song, int index)?
      extraMenuItems;
  final void Function(Song song, String value)? onExtraMenu;

  /// 多选栏动作（selected 为当前选择集内的歌曲；clear 用于动作完成后退出多选）。
  final List<SelectionAction> Function(List<Song> selected, VoidCallback clear)
      selectionActions;

  /// 空状态文案。
  final String emptyText;

  /// 自定义空状态（如歌曲页带「刷新」按钮）；为空时用 [emptyText]。
  final Widget? emptyPlaceholder;

  /// 计数行文案（参数：展示歌曲数、组/文件夹数）。
  final String Function(int songs, int folders)? countLabel;

  final Future<void> Function()? onRefresh;

  /// 打开时追焦到当前播放歌曲（播放器带的歌单页）。
  final bool focusCurrent;

  /// 重进页面时重新追焦的信号（歌单页由 PageView 保活后重进）。
  final ValueListenable<int>? focusTick;

  /// 文件夹导航方式；仅 [FolderNavigation.recursive] 使用 [folderPaths]/[dir]。
  final FolderNavigation folderNavigation;

  /// 递归模式：与 [songs] 等长的「源内相对路径」列表。
  final List<String>? folderPaths;

  /// 递归模式：应用内新建过、可能还没有歌曲的空文件夹（源内相对路径）。
  final Set<String> extraFolders;

  /// 递归模式当前目录（受控；`''` = 源根）。
  final String dir;
  final ValueChanged<String>? onDirChanged;

  const SongCollectionView({
    super.key,
    required this.songs,
    required this.searching,
    required this.collectionKey,
    required this.groupMode,
    required this.onGroupModeChanged,
    required this.sort,
    required this.onSortChanged,
    this.sortScope = SortScope.songs,
    this.showSort = true,
    this.folderLabel,
    required this.onPlay,
    required this.onPlayGroup,
    this.sourceOf,
    this.extraMenuItems,
    this.onExtraMenu,
    required this.selectionActions,
    required this.emptyText,
    this.emptyPlaceholder,
    this.countLabel,
    this.onRefresh,
    this.focusCurrent = false,
    this.focusTick,
    this.folderNavigation = FolderNavigation.flat,
    this.folderPaths,
    this.extraFolders = const {},
    this.dir = '',
    this.onDirChanged,
  }) : assert(folderPaths == null || folderPaths.length == songs.length,
            'folderPaths 必须与 songs 等长（逐级模式下按同一顺序取源内相对路径）');

  @override
  State<SongCollectionView> createState() => _SongCollectionViewState();
}

class _SongCollectionViewState extends State<SongCollectionView> {
  final Selection<String> _sel = Selection<String>();
  final SongRowCache _rowCache = SongRowCache();
  final SongGroupCache _groupCache = SongGroupCache();
  final SourceFolderCache _folderCache = SourceFolderCache();
  final ScrollController _scroll = ScrollController();

  String _collectionKey = '';
  Set<String> _collapsed = {};

  /// 最近一次 build 的展示行/追焦位置（供 [focusTick] 在 build 外复用）。
  List<SongListRow> _rows = const [];
  int _focusDisplay = -1;

  /// 逐级模式的展示列表缓存：文件夹结果与源歌曲列表不变时复用，避免每次
  /// build 新建列表导致行缓存整表失效。
  Object? _folderDataRef;
  Object? _folderSongsRef;
  List<Song> _folderDisplay = const [];

  /// songKey 列表缓存（按展示列表身份）。
  Object? _keysRef;
  List<String> _keys = const [];

  /// 平铺/逐级行列表缓存：分组结果与折叠版本不变时复用，避免每帧重建 O(n) 行。
  List<SongGroup>? _flatRowsGroups;
  int _flatRowsRev = -1;
  List<SongListRow> _flatRows = const [];
  Object? _noneRowsBase;
  List<SongListRow> _noneRows = const [];
  Object? _folderRowsData;
  List<SongListRow> _folderRows = const [];
  int _collapseRev = 0;

  /// 组名 → 组数据（组头行 O(1) 取计数，避免每个组头 firstWhere 扫全组）。
  Object? _groupsByNameRef;
  Map<String, SongGroup> _groupsByName = const {};

  /// 整个集合（`widget.songs`）的 songKey 列表：组/文件夹批量选择不能只取
  /// 当前展示层（折叠组、子文件夹里的歌也要能被选中）。
  Object? _collectionKeysRef;
  List<String> _collectionKeys = const [];

  /// 选择版本号：任何选择变更自增。选择汇总与歌曲行缓存都以它为准，
  /// 避免每次播放进度 tick 做 O(n) 的已选键哈希/计数。
  int _selEpoch = 0;
  Object? _selectionSummaryKey;
  _SelectionSummary _selectionSummary = _SelectionSummary.empty;

  /// 当前播放曲下标缓存（展示列表/当前曲不变时复用）。
  Object? _currentBaseRef;
  String? _currentKey;
  int _currentIdx = -1;

  /// 打开后只自动追焦一次（之后由 focusTick 显式触发）。
  bool _focusDone = false;

  @override
  void initState() {
    super.initState();
    widget.focusTick?.addListener(_onFocusTick);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_collectionKey != widget.collectionKey) {
      _collectionKey = widget.collectionKey;
      _collapsed = context.read<DirectSourceManager>().settings.groupCollapsed(
            widget.collectionKey,
          );
    }
  }

  @override
  void didUpdateWidget(covariant SongCollectionView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusTick != oldWidget.focusTick) {
      oldWidget.focusTick?.removeListener(_onFocusTick);
      widget.focusTick?.addListener(_onFocusTick);
    }
    if (widget.collectionKey != oldWidget.collectionKey) {
      _focusDone = false;
      _sel.cancel();
      _selEpoch++;
      final s = context.read<DirectSourceManager>().settings;
      _collapsed = s.groupCollapsed(widget.collectionKey);
      _collapseRev++;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
    // 进入子文件夹 / 面包屑跳转不改变当前选择：递归选中的歌曲可跨目录继续
    // 累积或反选。切集合、切分类仍清空（歌单详情与源页各自独立）。
    if (widget.groupMode != oldWidget.groupMode) {
      _sel.cancel();
      _selEpoch++;
    }
  }

  @override
  void dispose() {
    widget.focusTick?.removeListener(_onFocusTick);
    _scroll.dispose();
    super.dispose();
  }

  /// 折叠集合按页面（collectionKey）保存，不按当前分类裁剪：切到专辑再切回
  /// 文件夹时，各分类此前的折叠状态都还在。
  void _persistCollapsed(AppSettings settings) {
    settings.setGroupCollapsed(widget.collectionKey, _collapsed);
  }

  void _toggleCollapse(AppSettings settings, String name) {
    setState(() {
      if (!_collapsed.remove(name)) _collapsed.add(name);
      _collapseRev++;
      _persistCollapsed(settings);
    });
  }

  /// A 模式分类菜单 / B 模式长按组头：当前分类有展开组则全折叠，否则全
  /// 展开（不影响其他分类已折叠的组名）。
  void _toggleAllCollapse(AppSettings settings, List<SongGroup> groups) {
    final anyExpanded = groups.any((g) => !_collapsed.contains(g.name));
    setState(() {
      final names = {for (final g in groups) g.name};
      if (anyExpanded) {
        _collapsed = {..._collapsed, ...names};
      } else {
        _collapsed = {..._collapsed}..removeAll(names);
      }
      _collapseRev++;
      _persistCollapsed(settings);
    });
  }

  /// 整个集合（按 `widget.songs` 顺序）的 songKey；按列表身份缓存。
  List<String> _collectionKeysOf(List<Song> songs) {
    if (!identical(_collectionKeysRef, songs)) {
      _collectionKeysRef = songs;
      _collectionKeys = [for (final s in songs) songKey(s)];
    }
    return _collectionKeys;
  }

  List<String> _keysForGroup(SongGroup g) {
    final all = _collectionKeysOf(widget.songs);
    return [for (final i in g.songIndices) all[i]];
  }

  List<String> _keysForFolder(SourceFolder f) {
    final all = _collectionKeysOf(widget.songs);
    final paths = widget.folderPaths ?? const <String>[];
    return [for (final i in indicesUnder(paths, f.path)) all[i]];
  }

  /// B 模式下从分类菜单进入多选（此时行点击切换选中，组头点击切整组）。
  void _startSelectionMode() {
    setState(() {
      _sel.cancel();
      _sel.active = true;
      _selEpoch++;
    });
  }

  void _startGroupSelection(SongGroup g) {
    final keys = _keysForGroup(g);
    if (keys.isEmpty) return;
    setState(() {
      _sel.startWithAll(keys);
      _selEpoch++;
    });
  }

  void _toggleGroupSelection(SongGroup g) {
    final keys = _keysForGroup(g);
    if (keys.isEmpty) return;
    setState(() {
      _sel.setAll(keys);
      _selEpoch++;
    });
  }

  void _startFolderSelection(SourceFolder f) {
    if (f.total == 0) return;
    final keys = _keysForFolder(f);
    if (keys.isEmpty) return;
    setState(() {
      _sel.startWithAll(keys);
      _selEpoch++;
    });
  }

  void _toggleFolderSelection(SourceFolder f) {
    if (f.total == 0) return;
    final keys = _keysForFolder(f);
    if (keys.isEmpty) return;
    setState(() {
      _sel.setAll(keys);
      _selEpoch++;
    });
  }

  /// 三态勾选：全选 / 半选 / 未选。
  static bool? _checkState(int selected, int total) {
    if (total <= 0 || selected <= 0) return false;
    if (selected >= total) return true;
    return null;
  }

  void _onFocusTick() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pos = _rows.indexWhere((r) => r.song == _focusDisplay);
      if (pos >= 0) _scrollToRow(pos);
    });
  }

  void _scrollToRow(int row) {
    if (!mounted || !_scroll.hasClients) return;
    // 目标行置于距顶 96px 处；越界位置由滚动范围钳位。
    final offset = (row * kRowExtent - 96).clamp(0.0, double.infinity);
    _scroll.jumpTo(offset.clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final player = context.watch<PlayerProvider>();
    final settings = direct.settings;

    final mode = widget.searching ? SongGroupMode.none : widget.groupMode;
    final recursive = !widget.searching &&
        widget.folderNavigation == FolderNavigation.recursive &&
        mode == SongGroupMode.folder;

    List<Song> displaySongs;
    List<SongListRow> rows;
    List<SongGroup> groups = const [];
    Object? folderData;
    int folderCount = 0;

    if (recursive) {
      final paths = widget.folderPaths ?? const <String>[];
      final data = _folderCache.resolve(
        relRefs: paths,
        dir: widget.dir,
        extraFolders: widget.extraFolders,
      );
      folderData = data;
      folderCount = data.folders.length;
      if (!identical(_folderDataRef, data) ||
          !identical(_folderSongsRef, widget.songs)) {
        _folderDataRef = data;
        _folderSongsRef = widget.songs;
        _folderDisplay = [for (final i in data.songIndices) widget.songs[i]];
      }
      displaySongs = _folderDisplay;
      if (!identical(_folderRowsData, data)) {
        _folderRowsData = data;
        _folderRows = buildFolderRows(
          folders: data.folders,
          songIndices: [for (var i = 0; i < displaySongs.length; i++) i],
        );
      }
      rows = _folderRows;
    } else {
      groups = _groupCache.resolve(
        songs: widget.songs,
        mode: mode,
        sourcesRev: direct.sourcesRevision,
        stripPrefixOf: (s) {
          final src = direct.sourceByKey(s.sourceKey);
          return src == null ? '' : stripPrefixForSource(src);
        },
      );
      displaySongs = widget.songs;
      folderCount = groups.length;
      if (groups.isNotEmpty && !identical(_groupsByNameRef, groups)) {
        _groupsByNameRef = groups;
        _groupsByName = {for (final g in groups) g.name: g};
      }
      if (groups.isEmpty) {
        if (!identical(_noneRowsBase, displaySongs)) {
          _noneRowsBase = displaySongs;
          _noneRows = [
            for (var i = 0; i < displaySongs.length; i++)
              (group: null, folder: null, song: i),
          ];
        }
        rows = _noneRows;
      } else {
        if (!identical(_flatRowsGroups, groups) ||
            _flatRowsRev != _collapseRev) {
          _flatRowsGroups = groups;
          _flatRowsRev = _collapseRev;
          _flatRows = buildFlatRows(groups, _collapsed);
        }
        rows = _flatRows;
      }
    }

    // 追焦：以当前播放歌曲在展示列表中的位置为准（递归层级不在本层则跳过）。
    if (!identical(_keysRef, displaySongs)) {
      _keysRef = displaySongs;
      _keys = [for (final s in displaySongs) songKey(s)];
    }
    final keys = _keys;
    final selection = _buildSelectionSummary(
      displayKeys: keys,
      groups: groups,
      folderData: folderData,
      dir: widget.dir,
      recursive: recursive,
    );
    final cur = player.current;
    final curKey = cur == null ? null : songKey(cur);
    if (!identical(_currentBaseRef, displaySongs) || _currentKey != curKey) {
      _currentBaseRef = displaySongs;
      _currentKey = curKey;
      _currentIdx = curKey == null ? -1 : keys.indexOf(curKey);
    }
    final currentIdx = _currentIdx;
    final focusDisplay = widget.focusCurrent ? currentIdx : -1;
    _rows = rows;
    _focusDisplay = focusDisplay;

    final wide = MediaQuery.sizeOf(context).width >= kSongTileWideInfoWidth;

    _rowCache.begin(
      (
        identityHashCode(displaySongs),
        direct.favoriteVersion,
        direct.metaVersion,
        direct.settingsVersion,
        direct.sourcesRevision,
        settings.songTitleFormat,
        wide,
        currentIdx,
        _sel.active,
        _selEpoch,
      ),
      displaySongs.length,
      onWarm: () => direct.weight.warmMetaOf(displaySongs),
    );

    // 打开后自动定位到当前播放歌曲（仅一次；含组头/文件夹行偏移）。
    if (!_focusDone && focusDisplay >= 0) {
      final pos = rows.indexWhere((r) => r.song == focusDisplay);
      if (pos >= 0) {
        _focusDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToRow(pos);
        });
      }
    }

    final selected = selection.songs;
    final trailing = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SongGroupButton(
          value: widget.groupMode,
          onChanged: widget.onGroupModeChanged,
          folderLabel: widget.folderLabel,
          // A（默认）：长按组头多选，全部展开/折叠收进分类菜单。
          onToggleAllCollapse: !settings.longPressCollapseGroups &&
                  groups.isNotEmpty
              ? () => _toggleAllCollapse(settings, groups)
              : null,
          allCollapsed: groups.isNotEmpty &&
              groups.every((g) => _collapsed.contains(g.name)),
          // B：长按组头展开/折叠，多选入口收进分类菜单（仅当有组/文件夹
          // 行可点选时；纯歌曲列表长按歌曲即可进入多选）。
          onStartSelection: settings.longPressCollapseGroups &&
                  (groups.isNotEmpty || folderCount > 0)
              ? _startSelectionMode
              : null,
        ),
        if (widget.showSort)
          SortMenuButton(
            value: widget.sort,
            scope: widget.sortScope,
            onChanged: widget.onSortChanged,
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_sel.active)
          SelectionBar(
            total: keys.length,
            selectedCount: selection.songs.length,
            allSelected: selection.allVisibleSelected,
            onToggleAll: keys.isEmpty
                ? null
                : () => setState(() {
                      _sel.active = true;
                      _sel.setAll(keys);
                      _selEpoch++;
                    }),
            onCancel: () => setState(() {
              _sel.cancel();
              _selEpoch++;
            }),
            actions: widget.selectionActions(
              selected,
              () => setState(() {
                _sel.cancel();
                _selEpoch++;
              }),
            ),
          )
        else
          CountHeader(
            count: displaySongs.length,
            label: widget.countLabel?.call(displaySongs.length, folderCount),
            trailing: trailing,
          ),
        const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? (widget.emptyPlaceholder ??
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child:
                          Text(widget.emptyText, textAlign: TextAlign.center),
                    ),
                  ))
              : RowList(
                  controller: _scroll,
                  count: rows.length,
                  onRefresh: widget.onRefresh,
                  itemBuilder: (c, i) {
                    final row = rows[i];
                    if (row.folder != null) {
                      final f = row.folder!;
                      return _folderRow(
                          c, f, selection.folderSelected[f.path] ?? 0);
                    }
                    if (row.group != null) {
                      final g = _groupsByName[row.group!];
                      return g == null
                          ? const SizedBox.shrink()
                          : _groupRow(c, direct, groups, g,
                              selection.groupSelected[g.name] ?? 0);
                    }
                    final si = row.song!;
                    final s = displaySongs[si];
                    final key = keys[si];
                    return _songRow(
                        direct, displaySongs, si, s, key, currentIdx, wide);
                  },
                ),
        ),
      ],
    );
  }

  /// 选择态汇总：仅选择版本、列表、分组/目录变化时重算。
  ///
  /// 批量操作与已选数基于整个集合 [SongCollectionView.songs]（源页递归时为
  /// 全源歌曲；搜索时为搜索结果），组/文件夹已选数则从组索引与目录前缀派生。
  _SelectionSummary _buildSelectionSummary({
    required List<String> displayKeys,
    required List<SongGroup> groups,
    required Object? folderData,
    required String dir,
    required bool recursive,
  }) {
    if (!_sel.active) return _SelectionSummary.empty;
    final key = (
      _selEpoch,
      widget.songs,
      displayKeys,
      groups,
      folderData,
      widget.folderPaths,
      dir,
      recursive,
    );
    if (_selectionSummaryKey == key) return _selectionSummary;

    final songs = widget.songs;
    final allKeys = _collectionKeysOf(songs);
    final selectedIndices = <int>[];
    for (var i = 0; i < songs.length; i++) {
      if (_sel.contains(allKeys[i])) selectedIndices.add(i);
    }
    final selectedSet = selectedIndices.toSet();
    final selected = [for (final i in selectedIndices) songs[i]];

    // 递归目录视图的「本层已选」只算当前展示的歌曲；平铺模式整个列表就是
    // 集合本身。
    var visibleSelected = 0;
    if (recursive) {
      for (final k in displayKeys) {
        if (_sel.contains(k)) visibleSelected++;
      }
    } else {
      visibleSelected = selectedIndices.length;
    }

    var groupSelected = const <String, int>{};
    if (groups.isNotEmpty) {
      final counts = <String, int>{};
      for (final g in groups) {
        var n = 0;
        for (final i in g.songIndices) {
          if (selectedSet.contains(i)) n++;
        }
        counts[g.name] = n;
      }
      groupSelected = counts;
    }

    var folderSelected = const <String, int>{};
    if (recursive && widget.folderPaths != null) {
      final paths = widget.folderPaths!;
      final counts = <String, int>{};
      final current = normalizeDir(dir);
      final prefix = current.isEmpty ? '' : '$current/';
      for (final i in selectedIndices) {
        final rel = normalizeDir(paths[i]);
        if (prefix.isNotEmpty && !rel.startsWith(prefix)) continue;
        final rest = prefix.isEmpty ? rel : rel.substring(prefix.length);
        final slash = rest.indexOf('/');
        if (slash <= 0) continue;
        final child = prefix.isEmpty
            ? rest.substring(0, slash)
            : '$prefix${rest.substring(0, slash)}';
        counts[child] = (counts[child] ?? 0) + 1;
      }
      folderSelected = counts;
    }

    final summary = _SelectionSummary(
      songs: selected,
      visibleSelected: visibleSelected,
      allVisibleSelected:
          displayKeys.isNotEmpty && visibleSelected == displayKeys.length,
      groupSelected: groupSelected,
      folderSelected: folderSelected,
    );
    _selectionSummaryKey = key;
    _selectionSummary = summary;
    return summary;
  }

  Widget _folderRow(BuildContext c, SourceFolder f, int selected) {
    final scheme = Theme.of(c).colorScheme;
    final selectable = f.total > 0;
    return ListTile(
      leading: _selectableLeading(
        _leadingIcon(Icons.folder, scheme),
        enabled: selectable,
        state: _checkState(selected, f.total),
        onTap: () => _toggleFolderSelection(f),
      ),
      title: Text(
        f.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        _sel.active && selectable
            ? '已选 $selected / ${f.total} 首'
            : '${f.total} 首',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_sel.active)
            RowActionIconButton(
              icon: Icons.play_arrow,
              tooltip: '播放该文件夹',
              onPressed: f.total == 0
                  ? null
                  : () {
                      final paths = widget.folderPaths ?? const <String>[];
                      final idx = indicesUnder(paths, f.path);
                      widget.onPlayGroup(
                          [for (final i in idx) widget.songs[i]]);
                    },
            ),
          RowActionIconButton(
            icon: Icons.chevron_right,
            tooltip: '进入文件夹',
            onPressed: () => widget.onDirChanged?.call(f.path),
          ),
        ],
      ),
      // 多选态点击整行 = 选中/取消整个子树；右侧箭头仍可进入文件夹。
      onTap: _sel.active
          ? (selectable ? () => _toggleFolderSelection(f) : null)
          : () => widget.onDirChanged?.call(f.path),
      // 源页逐级文件夹没有可折叠的组内容，长按始终直接多选整个子树（A/B
      // 只影响可折叠的组头）。
      onLongPress: selectable
          ? (_sel.active
              ? () => _toggleFolderSelection(f)
              : () => _startFolderSelection(f))
          : null,
    );
  }

  Widget _groupRow(BuildContext c, DirectSourceManager direct,
      List<SongGroup> groups, SongGroup g, int selected) {
    final scheme = Theme.of(c).colorScheme;
    final name = g.name;
    final collapsed = _collapsed.contains(name);
    final longPressCollapse = direct.settings.longPressCollapseGroups;
    return ListTile(
      leading: _selectableLeading(
        _leadingIcon(
          widget.groupMode == SongGroupMode.album ? Icons.album : Icons.folder,
          scheme,
        ),
        enabled: true,
        state: _checkState(selected, g.count),
        onTap: () => _toggleGroupSelection(g),
      ),
      title: Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        _sel.active ? '已选 $selected / ${g.count} 首' : '${g.count} 首',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_sel.active)
            RowActionIconButton(
              icon: Icons.play_arrow,
              tooltip: '播放该分组',
              onPressed: () => widget.onPlayGroup(
                  [for (final i in g.songIndices) widget.songs[i]]),
            ),
          RowActionIconButton(
            icon: collapsed ? Icons.expand_more : Icons.expand_less,
            tooltip: collapsed ? '展开分组' : '折叠分组',
            onPressed: () => _toggleCollapse(direct.settings, name),
          ),
        ],
      ),
      // 多选态点击组头 = 全选/取消整组；箭头单独负责折叠。
      onTap: _sel.active
          ? () => _toggleGroupSelection(g)
          : () => _toggleCollapse(direct.settings, name),
      onLongPress: () {
        if (_sel.active) {
          _toggleGroupSelection(g);
        } else if (longPressCollapse) {
          _toggleAllCollapse(direct.settings, groups);
        } else {
          _startGroupSelection(g);
        }
      },
    );
  }

  /// 多选态在行首图标左上角叠加三态勾选；非选择态/不可选（空文件夹）原样返回。
  Widget _selectableLeading(
    Widget leading, {
    required bool enabled,
    required bool? state,
    required VoidCallback onTap,
  }) {
    if (!_sel.active || !enabled) return leading;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        leading,
        Positioned(
          left: -4,
          top: -4,
          child: SelectionBadge(selected: state, onTap: onTap),
        ),
      ],
    );
  }

  Widget _songRow(
    DirectSourceManager direct,
    List<Song> displaySongs,
    int si,
    Song s,
    String key,
    int currentIdx,
    bool wide,
  ) {
    final src = widget.sourceOf?.call(s);
    return SongTile(
      song: s,
      source: src,
      row: _rowCache.rowAt(si, () {
        final meta = direct.weight.metaOf(s);
        return SongRowView.of(
          song: s,
          titleFormat: direct.settings.songTitleFormat,
          sourceName: src?.name ?? direct.sourceByKey(s.sourceKey)?.name,
          playing: si == currentIdx,
          selected: _sel.contains(key),
          favorite: meta.favorite,
          disliked: meta.frozen,
          isFirst: si == 0,
          isLast: si == displaySongs.length - 1,
          wide: wide,
        );
      }),
      playing: si == currentIdx,
      selectionMode: _sel.active,
      selected: _sel.contains(key),
      onSelect: () => setState(() {
        _sel.toggle(key);
        _selEpoch++;
      }),
      onStartSelect: () => setState(() {
        _sel.startWith(key);
        _selEpoch++;
      }),
      onPlay: () => widget.onPlay(displaySongs, si),
      extraMenuItems: widget.extraMenuItems?.call(s, si),
      onExtraMenu: (v) => widget.onExtraMenu?.call(s, v),
    );
  }

  static Widget _leadingIcon(IconData icon, ColorScheme scheme) => Container(
        width: 44,
        height: 44,
        decoration: ShapeDecoration(
          color: scheme.primary.withValues(alpha: 0.10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        child: Icon(icon, color: scheme.primary, size: 24),
      );
}

/// 分类方式按钮（挂在计数栏右侧、排列按钮左边）：无 / 文件夹 / 专辑。
class SongGroupButton extends StatelessWidget {
  final SongGroupMode value;
  final ValueChanged<SongGroupMode> onChanged;
  final String? folderLabel;

  /// A 模式：长按组头改为多选后，「全部展开/折叠」收进本菜单。
  final VoidCallback? onToggleAllCollapse;
  final bool allCollapsed;

  /// B 模式：长按组头改为展开/折叠后，「多选」入口收进本菜单。
  final VoidCallback? onStartSelection;

  const SongGroupButton({
    super.key,
    required this.value,
    required this.onChanged,
    this.folderLabel,
    this.onToggleAllCollapse,
    this.allCollapsed = false,
    this.onStartSelection,
  });

  @override
  Widget build(BuildContext context) {
    final active = value != SongGroupMode.none;
    return ToolbarPopupMenuButton<SongGroupMode>(
      tooltip: '分类方式：${value.labelFor(folderLabel: folderLabel)}',
      icon: switch (value) {
        SongGroupMode.folder => Icons.folder_outlined,
        SongGroupMode.album => Icons.album_outlined,
        SongGroupMode.none => Icons.category_outlined,
      },
      color: active ? Theme.of(context).colorScheme.primary : null,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final m in SongGroupMode.values)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: m == value
                      ? Icon(Icons.check,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary)
                      : null,
                ),
                Text(m.labelFor(folderLabel: folderLabel)),
              ],
            ),
          ),
        if (onToggleAllCollapse != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem<SongGroupMode>(
            onTap: onToggleAllCollapse,
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(
                    allCollapsed ? Icons.unfold_more : Icons.unfold_less,
                    size: 18,
                  ),
                ),
                Text(allCollapsed ? '全部展开' : '全部折叠'),
              ],
            ),
          ),
        ],
        if (onStartSelection != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem<SongGroupMode>(
            onTap: onStartSelection,
            child: const Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Icon(Icons.checklist, size: 18),
                ),
                Text('多选'),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// 一次多选构建的派生汇总（见 [_SongCollectionViewState._buildSelectionSummary]）。
class _SelectionSummary {
  /// 全集合中已选歌曲，按 [SongCollectionView.songs] 原顺序。
  final List<Song> songs;

  /// 当前展示层已选数（递归目录视图只算本层）。
  final int visibleSelected;
  final bool allVisibleSelected;

  /// 组名 / 文件夹路径 → 已选歌曲数（用于三态勾选与组头计数）。
  final Map<String, int> groupSelected;
  final Map<String, int> folderSelected;

  const _SelectionSummary({
    required this.songs,
    required this.visibleSelected,
    required this.allVisibleSelected,
    required this.groupSelected,
    required this.folderSelected,
  });

  static const empty = _SelectionSummary(
    songs: [],
    visibleSelected: 0,
    allVisibleSelected: false,
    groupSelected: {},
    folderSelected: {},
  );
}
