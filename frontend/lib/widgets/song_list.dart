import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/local_index.dart';
import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../utils/collection_sort.dart';
import '../utils/duration_format.dart';
import '../utils/song_search.dart';
import '../utils/song_title_format.dart';
import 'add_to_playlist.dart';
import 'count_header.dart';
import 'list_selection.dart';
import 'row_list.dart';
import 'selection_badge.dart';
import 'selection_bar.dart';
import 'sort_menu_button.dart';
import 'app_toast.dart';

/// 通用歌曲列表：封面缩略图 + 标题 + 歌手/专辑/专辑歌手 + 时长时间器。
///
/// 收藏/不喜欢/缓存等操作统一收进右侧三点菜单（列表保持清爽，方便多选）。
/// 收藏（喜欢）对所有歌曲生效（统一收口到 play_meta）；缓存仅直连歌曲。
///
/// 多选模式：当 [selectionMode] 为 true 时，leading 变为选择框，
/// 点击列表切换勾选，[onSelect] 负责切换 [selected]。
class SongTile extends StatelessWidget {
  final Song song;

  /// 该歌对应的本机播放源；null=本机未配置对应源（如同步快照行，仅可查看/收藏）。
  final MusicSource? source;
  final VoidCallback onPlay;

  /// 多选模式：true 时显示勾选框并以选中态渲染。
  final bool selectionMode;

  /// 当前条目是否被选中（多选模式下）。
  final bool selected;

  /// 多选模式下切换本条目选中状态；非多选时为空。
  final VoidCallback? onSelect;

  /// 是否正在播放（标题后显示播放指示）。
  ///
  /// 指示**不再占用封面位**（改进.txt）：封面位置恒为封面，指示跟在标题后面。
  final bool playing;

  /// 长按进入多选模式并选中本条目（非多选模式下生效）。
  final VoidCallback? onStartSelect;

  /// 追加到内置菜单末尾的自定义项（歌单详情的上移/下移/移除）。
  ///
  /// 内置项的 value 为 `favorite`/`dislike`/`cache`/`playlist`，自定义项请用自己的
  /// 前缀（如 `row:up`），避免撞名；回调统一落到 [onExtraMenu]。
  final List<PopupMenuEntry<String>>? extraMenuItems;

  /// [extraMenuItems] 中被选中项的回调（值即该项的 value）。
  final ValueChanged<String>? onExtraMenu;

  const SongTile({
    super.key,
    required this.song,
    required this.source,
    required this.onPlay,
    this.selectionMode = false,
    this.selected = false,
    this.onSelect,
    this.onStartSelect,
    this.playing = false,
    this.extraMenuItems,
    this.onExtraMenu,
  });

  /// 副标题：歌手 · 专辑（· 专辑歌手，仅当与歌手不同时展示，避免冗余）。
  String get _subtitle {
    final artist = song.artist ?? 'Unknown';
    final parts = <String>[artist];
    final album = song.albumName;
    if (album != null && album.isNotEmpty) parts.add(album);
    final albumArtist = song.albumArtist;
    if (albumArtist != null && albumArtist.isNotEmpty && albumArtist != artist) {
      parts.add('专辑歌手：$albumArtist');
    }
    return parts.join(' · ');
  }

  Future<void> _cacheSong(BuildContext context, DirectSourceManager direct) async {
    final src = source;
    if (src == null) return;
    try {
      await direct.cacheSong(src, song);
      if (context.mounted) {
        AppToast.show('已缓存，可离线播放', isError: false);
      }
    } catch (e) {
      AppToast.error(e, '缓存失败');
    }
  }

  /// 三点菜单：喜欢 / 不喜欢 / 缓存（仅直连）/ 加入歌单。
  ///
  /// 歌单详情等需要「追加」自定义项时传 [extraMenuItems]，其回调走 [onExtraMenu]。
  Widget _menu(BuildContext context, DirectSourceManager direct,
      bool favorite, bool disliked) {
    final extra = extraMenuItems;
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        switch (v) {
          case 'favorite':
            direct.setFavorite(song, !favorite);
            if (favorite && context.mounted) {
              unawaited(context
                  .read<PlayerProvider>()
                  .onAnchorSongRemoved(PlayerProvider.anchorForLiked(), song));
            }
            AppToast.show(!favorite ? '已加入喜欢' : '已取消喜欢',
                isError: false);
          case 'dislike':
            direct.setDisliked(song, !disliked);
            AppToast.show(
                !disliked ? '已标记不喜欢，权重降到最低' : '已取消不喜欢',
                isError: false);
          case 'cache':
            unawaited(_cacheSong(context, direct));
          case 'playlist':
            showAddToPlaylistSheet(context, song);
          default:
            onExtraMenu?.call(v);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'favorite',
          child: Row(
            children: [
              Icon(
                favorite ? Icons.favorite : Icons.favorite_border,
                color: favorite ? Colors.pink : null,
              ),
              const SizedBox(width: 12),
              Text(favorite ? '取消喜欢' : '喜欢'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'dislike',
          child: Row(
            children: [
              Icon(
                disliked ? Icons.thumb_down : Icons.thumb_down_outlined,
                color: disliked ? Colors.orange : null,
              ),
              const SizedBox(width: 12),
              Text(disliked ? '取消不喜欢' : '不喜欢'),
            ],
          ),
        ),
        if (song.isDirect && source != null)
          const PopupMenuItem(
            value: 'cache',
            child: Row(
              children: [
                Icon(Icons.download),
                SizedBox(width: 12),
                Text('缓存'),
              ],
            ),
          ),
        const PopupMenuItem(
          value: 'playlist',
          child: Row(
            children: [
              Icon(Icons.playlist_add),
              SizedBox(width: 12),
              Text('加入歌单'),
            ],
          ),
        ),
        if (extra != null && extra.isNotEmpty) ...[
          const PopupMenuDivider(),
          ...extra,
        ],
      ],
    );
  }

  /// 行首：普通态/紧凑态是封面或图标，多选态把勾选框**叠在封面左上角**。
  ///
  /// 不再像以前那样用勾选框顶替封面——封面位置恒为封面（改进.txt），多选时
  /// 仍能靠封面认出是哪首（与歌单卡片的封面勾选一致）。
  Widget _leading() {
    final cover = CoverThumb(coverPath: song.coverPath);
    if (!selectionMode) return cover;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        cover,
        Positioned(
          left: -4,
          top: -4,
          child: SelectionBadge(selected: selected, onTap: onSelect),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    // 收藏/不喜欢合并为一次 play_meta 查询（列表滑动期每行尽量减少查询）。
    final meta = direct.weight.metaOf(song);
    final favorite = meta.favorite;
    final disliked = meta.frozen;
    return ListTile(
      selected: selectionMode && selected,
      // 封面恒为封面（改进.txt）：多选态勾选框叠在封面左上角。
      leading: _leading(),
      // 标题 + 播放指示：指示在标题后（封面位留给封面）。
      title: Row(
        children: [
          Expanded(
            child: Text(
              formatSongTitle(song, direct.settings.songTitleFormat),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              // 标题常驻加粗；播放中/选中只再叠主色区分，不靠字重。
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: (selectionMode && selected) || playing
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
            ),
          ),
          if (playing) ...[
            const SizedBox(width: 4),
            Icon(Icons.graphic_eq,
                size: 15, color: Theme.of(context).colorScheme.primary),
          ],
        ],
      ),
      subtitle: Text(
        _subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // 尾部：多选态保留时长（信息）但隐藏单曲菜单（防误触）；
      // 普通态是时长 + 三点菜单。
      trailing: selectionMode
          ? Text(formatDuration(song.duration))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatDuration(song.duration)),
                _menu(context, direct, favorite, disliked),
              ],
            ),
      onTap: selectionMode ? onSelect : onPlay,
      onLongPress: selectionMode ? onSelect : onStartSelect,
    );
  }
}

/// 列表行封面形状：圆角方形（歌曲/专辑/播放源）与圆形（歌手头像）。
enum CoverShape { rounded, circle }

/// 封面缩略图（直连模式本地缓存封面）；无封面时回退等尺寸容器 + 图标，
/// 与有封面的 44×44 尺寸一致，保证列表文字缩进统一。
///
/// 列表与卡片共用（卡片走 [SquareCard] 自己的大尺寸实现）。
class CoverThumb extends StatelessWidget {
  final String? coverPath;

  /// 无封面时的占位图标（默认音符；专辑/歌手/歌单可各传自己的）。
  final IconData fallbackIcon;

  final CoverShape shape;

  const CoverThumb({
    super.key,
    this.coverPath,
    this.fallbackIcon = Icons.music_note,
    this.shape = CoverShape.rounded,
  });

  static const double _size = 44;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final circle = shape == CoverShape.circle;
    final placeholder = Container(
      width: _size,
      height: _size,
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.10),
        shape: circle
            ? const CircleBorder()
            : RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6)),
      ),
      child: Icon(fallbackIcon, color: color, size: circle ? 24 : 22),
    );
    if (coverPath == null) return placeholder;
    final image = Image.file(
      File(coverPath!),
      width: _size,
      height: _size,
      fit: BoxFit.cover,
      // 按显示尺寸 ×2 降采样解码，避免整首歌单列表每行全分辨率解码的内存/CPU 尖峰。
      cacheWidth: 88,
      cacheHeight: 88,
      errorBuilder: (_, __, ___) => placeholder,
    );
    return circle
        ? ClipOval(child: image)
        : ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: image,
          );
  }
}

/// 统一歌单歌曲列表（歌曲列表的标准化实现）。
///
/// 内容区歌单详情与播放器带的「歌单页」共用这一份代码路径，保证：
/// 同源（同一持久化歌单 [playlists_provider]）、同一行形态（[SongTile] 完整行）、
/// 同一增删写回语义（[PlaylistsProvider.removeItemRow] / [moveItemRow]，并联动
/// 播放器 [PlayerProvider.onPlaylistSongRemoved]）、同一排序键
/// （[DirectSourceManager.settings.sortPlaylistDetail]）。
///
/// 差异点收敛为参数：
/// - [onBack]：非空时头部左侧显示返回按钮（内容区详情返回内容层）；歌单页
///   传 null，不显示任何箭头/关闭（横向滑动即返回播放页）。
/// - [globalSearch]：true 时跟随全局搜索框（`NavigationProvider.search`，内容区）；
///   false 时列表自带搜索框（歌单页）。
class SongList extends StatefulWidget {
  final int playlistId;

  /// 头部左侧返回按钮；null 表示不显示（歌单页无左上箭头/右上关闭）。
  final VoidCallback? onBack;

  /// true：搜索跟随全局搜索框；false：页内自带搜索框。
  final bool globalSearch;

  const SongList({
    super.key,
    required this.playlistId,
    this.onBack,
    this.globalSearch = false,
  });

  @override
  State<SongList> createState() => _SongListState();
}

class _SongListState extends State<SongList> {
  final Selection<String> _sel = Selection<String>();

  /// 页内自带搜索（[widget.globalSearch] 为 false 时使用）。
  final TextEditingController _searchCtrl = TextEditingController();
  String _localQuery = '';

  /// 歌单内歌曲滚动定位（打开时定位到当前播放歌曲）。
  ///
  /// 行高恒定为 72（双行 ListTile）+ 1 分隔线。追焦参考播放队列：进入时
  /// 直接用 initialScrollOffset 落在追焦处（首帧即渲染目标行，无可见扫描），
  /// 不再依赖逐行 GlobalKey 估算或首帧后再 jumpTo（曾因行高估算偏差导致
  /// 定位失败 + 触发两波封面解码尖峰，详见性能排查）。
  late final ScrollController _scroll;

  /// 已就位（首帧 initialScrollOffset 或顶部）；true 后不再触发兜底追焦。
  bool _located = false;

  /// 歌单数据按 [PlaylistsProvider.dataRevision] 缓存，避免每次重建重查 SQLite；
  /// 排序偏好变化时同样重排（平行数组按同一顺序重排，行与歌不拆散）。
  int _songsRevision = -1;
  CollectionSort _sort = CollectionSort.defaultOrder;
  List<Song> _songs = const [];
  List<PlaylistItemRow> _items = const [];

  /// 追焦目标 offset：队列同款固定上边距（目标行置于距顶 96px 处），
  /// 无需等 viewport；超出列表范围的值交由滚动位置钳位。
  double _focusOffset(int index) =>
      (index * kRowExtent - 96).clamp(0.0, double.infinity);

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SongList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换歌单后强制重取数据。
    if (widget.playlistId != oldWidget.playlistId) _songsRevision = -1;
  }

  /// 按数据版本拉取歌单条目；数据未变且排序未变时直接复用缓存（0 次 SQLite）。
  void _syncSongs(PlaylistsProvider provider, CollectionSort sort,
      double Function(Song) factorOf, int Function(Song) playSecOf) {
    final rev = provider.dataRevision;
    if (rev == _songsRevision && sort == _sort) return;
    _songsRevision = rev;
    _sort = sort;
    final items = provider.itemsOf(widget.playlistId);
    // 与歌曲页/喜欢页同源：条目快照优先解析为本机索引实时行
    // （封面、标题显示格式、歌手·专辑元数据即时可用）；源不在本机时保留快照。
    final songs = [
      for (final r in items)
        provider.store.index.songByRef(
                provider.songOf(r).sourceKey, r.songRef) ??
            provider.songOf(r),
    ];
    if (sort == CollectionSort.defaultOrder) {
      _items = items;
      _songs = List.unmodifiable(songs);
      return;
    }
    final order =
        songSortOrder(songs, sort, factorOf: factorOf, playSecOf: playSecOf);
    _items = [for (final i in order) items[i]];
    _songs = List.unmodifiable([for (final i in order) songs[i]]);
  }

  /// 兜底定位到第 [index] 行（首次数据未加载时的边缘情况）：
  /// 一次精确 jumpTo（固定行高保证落点必在视口内）。
  void _scrollToCurrent(int index) {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_focusOffset(index)
        .clamp(0.0, _scroll.position.maxScrollExtent));
  }

  @override
  void initState() {
    super.initState();
    // 打开即落在当前播放歌曲处：进 state 时同步读取已加载数据算出目标，
    // 用 initialScrollOffset 让首帧直接渲染追焦处（无可见扫描）。数据
    // 未加载时置 0，交给 build 里的兜底追焦逻辑。
    final provider = context.read<PlaylistsProvider>();
    final player = context.read<PlayerProvider>();
    final direct = context.read<DirectSourceManager>();
    var firstIdx = -1;
    if (provider.loaded && !_located) {
      _syncSongs(provider, direct.settings.sortPlaylistDetail,
          direct.weight.factorOf, direct.weight.playSecOf);
      firstIdx = _songs.indexWhere(player.isCurrent);
    }
    if (firstIdx >= 0) {
      _scroll = ScrollController(initialScrollOffset: _focusOffset(firstIdx));
      _located = true;
    } else {
      _scroll = ScrollController();
    }
    // 首帧后再刷新，避免 refresh() 的 notifyListeners 在 build 期间触发断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final p = context.read<PlaylistsProvider>();
      if (!p.loaded) p.refresh();
    });
  }

  void _toggle(String key) => setState(() {
        _sel.active = true;
        _sel.toggle(key);
      });

  /// 批量「从歌单移除」。
  ///
  /// 选择键一律取自行渲染用的 [_songs]（索引实时行，`id` 为真实 rowid）：此前
  /// 这里读 `provider.songsOf` 的条目快照（`id` 恒 0），与行 key 不同源，导致
  /// 「已选」计数恒为 0、点全选后计数变整单大小、移除也删不掉。
  Future<void> _removeSelected(PlaylistsProvider provider) async {
    // 计数含搜索范围外已勾选项（动作作用于整个选择集）。
    final count = _sel.of(_songs.map(songKey)).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('从歌单移除'),
        content: Text('确定从歌单中移除选中的 $count 首歌曲？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('移除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // 从后往前移除，避免 store 序号移位问题（_items 与 _songs 按同序平行）。
    final removed = <Song>[];
    for (var i = _items.length - 1; i >= 0; i--) {
      if (_sel.contains(songKey(_songs[i]))) {
        provider.removeItemRow(widget.playlistId, _items[i]);
        removed.add(_songs[i]);
      }
    }
    setState(_sel.cancel);
    _notifyPlayerRemoved(provider, removed);
  }

  /// 歌单删歌后联动当前播放（删到当前曲则播新末尾；深层列表移除引用）。
  void _notifyPlayerRemoved(PlaylistsProvider provider, List<Song> removed) {
    if (removed.isEmpty) return;
    final uuid = provider.store.index.playlistUuidOf(widget.playlistId);
    if (uuid == null) return;
    final player = context.read<PlayerProvider>();
    final count = provider.countOf(widget.playlistId);
    for (final s in removed) {
      unawaited(player.onPlaylistSongRemoved(uuid, s, newPlaylistCount: count));
    }
  }

  /// 「播放 / 从头播放」。[startWithOrder] 为 true 时起始曲按当前播放顺序
  /// 算法决定（加权=权重抽样、列表循环=接续当前曲、顺序/单曲=首曲），
  /// 否则固定首曲。
  Future<void> _playAll({required bool startWithOrder}) async {
    final provider = context.read<PlaylistsProvider>();
    final uuid = await provider.store.index
        .ensurePlaylistUuid(widget.playlistId);
    if (!mounted) return;
    final player = context.read<PlayerProvider>();
    player.playQueue(_songs,
        index: startWithOrder ? player.startIndexForPlaylist(_songs) : 0,
        playlistUuid: uuid,
        contextKey: PlayerProvider.anchorForPlaylist(uuid),
        resetAnchor: true,
        resumeFromBreakpoint: startWithOrder);
    context.read<NavigationProvider>().openPlayer();
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final provider = context.watch<PlaylistsProvider>();
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();

    PlaylistRow? playlist;
    for (final p in provider.playlists) {
      if (p.id == widget.playlistId) playlist = p;
    }
    // 数据版本不变时复用缓存的歌单条目（避免每帧/每次通知重查 SQLite）。
    _syncSongs(provider, direct.settings.sortPlaylistDetail,
        direct.weight.factorOf, direct.weight.playSecOf);
    // 搜索：全局搜索框（内容区）或页内自带搜索框（歌单页）过滤；visible 为原始下标映射。
    final query = (widget.globalSearch ? nav.search.trim() : _localQuery.trim())
        .toLowerCase();
    final searching = query.isNotEmpty;
    final visible = <int>[
      for (var i = 0; i < _songs.length; i++)
        if (songMatchesQuery(_songs[i], query)) i,
    ];
    final currentIdx = _songs.indexWhere((s) => player.isCurrent(s));
    final visibleCurrent = currentIdx < 0 ? -1 : visible.indexOf(currentIdx);
    // 多选键：与行渲染同源的 _songs 实时行（visible 为下标映射）。
    final visibleKeys = [for (final i in visible) songKey(_songs[i])];

    // 打开歌单后自动定位到当前播放歌曲（仅一次；按可见下标）。
    if (!_located && visibleCurrent >= 0) {
      _located = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent(visibleCurrent);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              if (widget.onBack != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回',
                  onPressed: widget.onBack,
                ),
              Expanded(
                child: Text(
                  playlist?.name ?? '歌单',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              if (_songs.isNotEmpty) ...[
                TextButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('播放'),
                  onPressed: () => _playAll(startWithOrder: true),
                ),
                IconButton(
                  tooltip: '从头播放',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () => _playAll(startWithOrder: false),
                ),
              ],
            ],
          ),
        ),
        // 歌单页自带搜索框（内容区详情跟随全局搜索框，不重复渲染）。
        if (!widget.globalSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _localQuery = v),
              decoration: InputDecoration(
                hintText: '搜索当前歌单',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _localQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清除',
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _localQuery = '');
                        },
                      ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
        // 多选栏与计数栏共用同一位置（与歌单列表页/喜欢页/歌曲页一致）：
        // 进入多选显示「已选」，退出恢复「共 xx 首歌曲」。
        if (_sel.active)
          SelectionBar(
            // 范围 = 当前搜索结果（visible 与 _songs 同下标，键与行渲染一致）。
            total: visible.length,
            selectedCount: _sel.of(visibleKeys).length,
            onToggleAll: () => setState(() {
              _sel.active = true;
              _sel.setAll(visibleKeys);
            }),
            onCancel: () => setState(_sel.cancel),
            actions: [
              SelectionAction(
                icon: Icons.playlist_remove,
                label: '从歌单移除',
                onPressed:
                    _sel.selected.isEmpty ? null : () => _removeSelected(provider),
              ),
            ],
          )
        else
          CountHeader(
            count: searching ? visible.length : _songs.length,
            trailing: SortMenuButton(
              value: direct.settings.sortPlaylistDetail,
              onChanged: (v) => setState(
                  () => direct.settings.sortPlaylistDetail = v),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: _songs.isEmpty
              ? const Center(child: Text('歌单为空'))
              : visible.isEmpty
                  ? const Center(child: Text('无匹配歌曲'))
                  // itemExtent 固定行高（含 1px 分隔线）：深位置（首帧定位/跳转）
                  // 只构建可见行，否则 Sliver 会从第 0 行逐行排到目标行——千首歌单
                  // 一帧构建 700+ 行与封面，进入必卡（实测 712 项 vs 16 项）。
                  : RowList(
                      controller: _scroll,
                      count: visible.length,
                      itemBuilder: (c, i) {
                        final full = visible[i];
                        final row = _items[full];
                        final s = _songs[full];
                        final isFirst = i == 0;
                        final isLast = i == visible.length - 1;
                        final key = songKey(s);
                        return SongTile(
                          song: s,
                          // 歌单详情取自本地索引，不提供直连源（不显示「缓存」项）。
                          source: null,
                          playing: full == currentIdx,
                          selectionMode: _sel.active,
                          selected: _sel.contains(key),
                          onSelect: () => _toggle(key),
                          onStartSelect: () =>
                              setState(() => _sel.startWith(key)),
                          onPlay: () async {
                            final uuid = await provider.store.index
                                .ensurePlaylistUuid(widget.playlistId);
                            if (!context.mounted) return;
                            player.playQueue(_songs,
                                index: full,
                                playlistUuid: uuid,
                                contextKey: PlayerProvider
                                    .anchorForPlaylist(uuid));
                            context.read<NavigationProvider>().openPlayer();
                          },
                          // 歌单顺序相关操作：上移/下移/移除，追加在内置项之后。
                          extraMenuItems: [
                            PopupMenuItem(
                              value: 'row:up',
                              enabled: !isFirst,
                              child: const Text('上移'),
                            ),
                            PopupMenuItem(
                              value: 'row:down',
                              enabled: !isLast,
                              child: const Text('下移'),
                            ),
                            const PopupMenuItem(
                              value: 'row:remove',
                              child: Text('移除'),
                            ),
                          ],
                          onExtraMenu: (v) {
                            switch (v) {
                              case 'row:up':
                                if (!isFirst) {
                                  provider.moveItemRow(
                                      widget.playlistId, row, -1);
                                }
                              case 'row:down':
                                if (!isLast) {
                                  provider.moveItemRow(
                                      widget.playlistId, row, 1);
                                }
                              case 'row:remove':
                                provider.removeItemRow(widget.playlistId, row);
                                _notifyPlayerRemoved(
                                    provider, [provider.songOf(row)]);
                            }
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
