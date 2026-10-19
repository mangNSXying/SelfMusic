import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../data/local/local_index.dart';
import '../data/local/song_weight_store.dart';
import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../utils/collection_sort.dart';
import '../utils/cover_thumb.dart';
import '../utils/duration_format.dart';
import '../utils/playlist_group.dart';
import '../utils/song_search.dart';
import '../utils/source_folders.dart';
import '../utils/song_title_format.dart';
import 'add_to_playlist.dart';
import 'count_header.dart';
import 'edit_song_meta_dialog.dart';
import 'list_selection.dart';
import 'row_list.dart';
import 'selection_badge.dart';
import 'selection_bar.dart';
import 'song_info_dialog.dart';
import 'song_row_view.dart';
import 'sort_menu_button.dart';
import 'app_toast.dart';

/// SongTile 行宽达到该值时，在时长左侧补充技术信息（格式 · 码率 · 大小）。
///
/// 阈值按行实际宽度判定（LayoutBuilder）：桌面/平板整宽列表满足；队列面板
/// （固定 360）等窄容器自动不显示。
const double kSongTileWideInfoWidth = 800;

/// 通用歌曲列表：封面缩略图 + 标题 + 歌手/专辑/专辑歌手 + 时长时间器。
///
/// 收藏/不喜欢/缓存等操作统一收进右侧三点菜单（列表保持清爽，方便多选）。
/// 收藏（喜欢）对所有歌曲生效（统一收口到 play_meta）；缓存仅直连歌曲。
/// 宽行（≥ [kSongTileWideInfoWidth]）额外在时长左侧显示格式/码率/大小。
///
/// 多选模式：当 [selectionMode] 为 true 时，leading 变为选择框，
/// 点击列表切换勾选，[onSelect] 负责切换 [selected]。
class SongTile extends StatelessWidget {
  final Song song;

  /// 行级不可变视图数据（R-1）：非空时走**纯参数渲染**——不订阅
  /// [DirectSourceManager]、不做逐行 LayoutBuilder、派生文本已算好；
  /// 为空时为兼容路径（旧调用方/单测），行为与改动前一致。
  final SongRowView? row;

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
    this.row,
    this.selectionMode = false,
    this.selected = false,
    this.onSelect,
    this.onStartSelect,
    this.playing = false,
    this.extraMenuItems,
    this.onExtraMenu,
  });

  /// 副标题：歌手 · 专辑（· 专辑歌手，仅当与歌手不同时展示，避免冗余）。
  String get _subtitle => SongRowView.subtitleOf(song);

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

  /// 删除歌曲（阶段6：二次确认 + 全删索引/权重/歌词/歌单/缓存）。
  Future<void> _deleteSong(BuildContext context, DirectSourceManager direct) async {
    final src = source;
    if (src == null || !src.supportsWrite) return;
    final ok1 = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除歌曲文件？'),
        content: Text('将从「${src.name}」永久删除「${song.title}」，\n'
            '并清除本地索引、收藏权重、歌词、歌单条目与离线缓存。\n此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('继续删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok1 != true || !context.mounted) return;
    // 二次确认：输入防误删（点按确认即执行，避免再输文字的繁琐）。
    final ok2 = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('再次确认删除'),
        content: Text('确认永久删除「${song.title}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('确认删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok2 != true || !context.mounted) return;
    try {
      await direct.deleteSong(song);
      if (!context.mounted) return;
      // 若当前播放的正是被删歌曲，切下一首避免播放器持有死引用。
      try {
        await context.read<PlayerProvider>().onAnchorSongRemoved(
            PlayerProvider.anchorForSource(song.sourceKey), song);
      } catch (_) {}
      if (context.mounted) AppToast.show('已删除', isError: false);
    } catch (e) {
      AppToast.error(e, '删除失败');
    }
  }

  /// 三点菜单：下一首播放 / 喜欢 / 不喜欢 / 缓存（仅直连）/ 加入歌单 / 歌曲信息。
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
          case 'play_next':
            final added = context.read<PlayerProvider>().playNext(song);
            AppToast.show(
                added ? '已加入下一首播放' : '已在下一首播放队列中',
                isError: false);
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
                !disliked ? '已标记不喜欢，权重降到 0.1' : '已取消不喜欢',
                isError: false);
          case 'cache':
            unawaited(_cacheSong(context, direct));
          case 'delete':
            unawaited(_deleteSong(context, direct));
          case 'playlist':
            showAddToPlaylistSheet(context, song);
          case 'info':
            showDialog<void>(
              context: context,
              builder: (_) => SongInfoDialog(song: song),
            );
          case 'edit':
            showDialog<void>(
              context: context,
              builder: (_) => EditSongMetaDialog(song: song),
            );
          default:
            onExtraMenu?.call(v);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'play_next',
          child: Row(
            children: [
              Icon(Icons.playlist_play),
              SizedBox(width: 12),
              Text('下一首播放'),
            ],
          ),
        ),
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
        if (song.isDirect && source != null && source!.supportsWrite)
          const PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete_outline, color: Colors.red),
                SizedBox(width: 12),
                Text('删除', style: TextStyle(color: Colors.red)),
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
        const PopupMenuItem(
          value: 'info',
          child: Row(
            children: [
              Icon(Icons.info_outline),
              SizedBox(width: 12),
              Text('歌曲信息'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'edit',
          child: Row(
            children: [
              Icon(Icons.edit_outlined),
              SizedBox(width: 12),
              Text('修改信息'),
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
  Widget _leading(String? coverPath) {
    final cover = CoverThumb(coverPath: coverPath);
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

  /// 宽行技术信息：`格式 · 码率 · 大小`，置于时长左侧。
  ///
  /// 计算口径收敛到 [SongRowView.wideInfoOf]，避免与行级数据两处漂移。
  Widget? _wideInfo(BuildContext context) {
    final text = SongRowView.wideInfoOf(song);
    if (text == null) return null;
    return Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }

  @override
  Widget build(BuildContext context) {
    final view = row;
    if (view != null) return _buildFromRow(context, view);
    return _buildLegacy(context);
  }

  /// 纯参数渲染（R-1）：只读 [row]，订阅收敛为零（除动作时一次性 `read`），
  /// 无逐行 LayoutBuilder，派生文本/收藏态均为值。
  Widget _buildFromRow(BuildContext context, SongRowView view) {
    final direct = context.read<DirectSourceManager>();
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      selected: selectionMode && selected,
      leading: _leading(view.coverPath),
      title: Row(
        children: [
          Expanded(
            child: Text(
              view.titleText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: (selectionMode && selected) || playing
                    ? cs.primary
                    : null,
              ),
            ),
          ),
          if (playing) ...[
            const SizedBox(width: 4),
            Icon(Icons.graphic_eq, size: 15, color: cs.primary),
          ],
        ],
      ),
      subtitle: Text(
        view.subtitleText,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (view.wideInfoText != null) ...[
            Text(
              view.wideInfoText!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
          ],
          Text(formatDuration(song.duration)),
          if (!selectionMode) _menu(context, direct, view.favorite, view.disliked),
        ],
      ),
      onTap: selectionMode ? onSelect : onPlay,
      onLongPress: selectionMode ? onSelect : onStartSelect,
    );
  }

  /// 兼容路径：未提供行级数据时保留旧行为（订阅管理器 + 逐行 LayoutBuilder）。
  Widget _buildLegacy(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    // 收藏/不喜欢合并为一次 play_meta 查询（列表滑动期每行尽量减少查询）。
    final meta = direct.weight.metaOf(song);
    final favorite = meta.favorite;
    final disliked = meta.frozen;
    // 行宽按实际约束判定：宽行在时长左侧补充技术信息。
    return LayoutBuilder(builder: (context, constraints) {
      final info =
          constraints.maxWidth >= kSongTileWideInfoWidth ? _wideInfo(context) : null;
      return ListTile(
        selected: selectionMode && selected,
        // 封面恒为封面（改进.txt）：多选态勾选框叠在封面左上角。
        leading: _leading(song.coverPath),
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
        // 普通态是 [宽行信息] + 时长 + 三点菜单。
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (info != null) ...[info, const SizedBox(width: 12)],
            Text(formatDuration(song.duration)),
            if (!selectionMode) _menu(context, direct, favorite, disliked),
          ],
        ),
        onTap: selectionMode ? onSelect : onPlay,
        onLongPress: selectionMode ? onSelect : onStartSelect,
      );
    });
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
    // 列表行优先用落盘缩略图（原图可能上千像素），并按实际显示尺寸 ×DPR 降解码，
    // 多分辨率变体由 ImageCache 分别保留。
    final px = (_size * MediaQuery.devicePixelRatioOf(context)).round();
    final image = Image.file(
      File(coverDisplayPath(coverPath!)),
      width: _size,
      height: _size,
      fit: BoxFit.cover,
      cacheWidth: px,
      cacheHeight: px,
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

  /// 重进歌单页的追焦信号（每进一次 +1）：歌单页被 PageView 预热保活后重进
  /// 不重挂载，仅靠挂载追焦不够，tick 时重新定位当前播放歌曲。
  final ValueListenable<int>? focusTick;

  const SongList({
    super.key,
    required this.playlistId,
    this.onBack,
    this.globalSearch = false,
    this.focusTick,
  });

  @override
  State<SongList> createState() => _SongListState();
}

class _SongListState extends State<SongList> {
  final Selection<String> _sel = Selection<String>();

  /// 行级视图数据缓存（R-1）：签名不变时复用，避免每次 build 重算整表派生文本/查询。
  final SongRowCache _rowCache = SongRowCache();

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

  /// 分组折叠状态（组名集合；默认全展开）与所属歌单。
  /// 换歌单时按新 playlistId 从设置重载（见 [_ensureCollapsed]）。
  int _collapsedPid = -1;
  Set<String> _collapsed = {};

  /// 追焦目标 offset：队列同款固定上边距（目标行置于距顶 96px 处），
  /// 无需等 viewport；超出列表范围的值交由滚动位置钳位。
  double _focusOffset(int index) =>
      (index * kRowExtent - 96).clamp(0.0, double.infinity);

  @override
  void dispose() {
    widget.focusTick?.removeListener(_onFocusTick);
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant SongList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换歌单后强制重取数据，并对新歌单重新追焦当前播放歌曲。
    if (widget.playlistId != oldWidget.playlistId) {
      _songsRevision = -1;
      _located = false;
    }
    if (widget.focusTick != oldWidget.focusTick) {
      oldWidget.focusTick?.removeListener(_onFocusTick);
      widget.focusTick?.addListener(_onFocusTick);
    }
  }

  /// 按数据版本拉取歌单条目；数据未变且排序未变时直接复用缓存（0 次 SQLite）。
  void _syncSongs(
      PlaylistsProvider provider, CollectionSort sort, SongWeightStore weight) {
    final rev = provider.dataRevision;
    if (rev == _songsRevision && sort == _sort) return;
    _songsRevision = rev;
    _sort = sort;
    final items = provider.itemsOf(widget.playlistId);
    // 与歌曲页/喜欢页同源：条目快照优先解析为本机索引实时行
    // （封面、标题显示格式、歌手·专辑元数据即时可用）；源不在本机时保留快照。
    // 批量按源分组 IN 查询解析（resolveLiveSongs），代替逐行 songByRef 的
    // N+1 逐条 SELECT——整单首装曾把横滑进歌单页的帧拖到 300ms+。
    final songs = provider.store.index
        .resolveLiveSongs([for (final r in items) provider.songOf(r)]);
    if (sort == CollectionSort.defaultOrder) {
      _items = items;
      _songs = List.unmodifiable(songs);
      return;
    }
    // 权重/播放统计排序批量预取（一次分片查询），不再逐首同步查库。
    final keys = weight.sortKeysOf(songs,
        factors: sort.isWeight, playSecs: sort.isPlayStat);
    final order = songSortOrder(songs, sort,
        factorOf: keys.factorOf, playSecOf: keys.playSecOf);
    _items = [for (final i in order) items[i]];
    _songs = List.unmodifiable([for (final i in order) songs[i]]);
  }

  /// 换歌单时重载折叠状态（build 内调用，不调 setState，只做幂等同步；
  /// 与 [_syncSongs] 同模式）。
  void _ensureCollapsed(AppSettings settings) {
    if (_collapsedPid == widget.playlistId) return;
    _collapsedPid = widget.playlistId;
    _collapsed = settings.playlistGroupCollapsed(widget.playlistId);
  }

  /// 分组（视图层稳定分区；搜索中或分类为「无」时返回空，即平铺）。
  /// 输入 [_songs] 已按「排列方式」排好，分组只分区不重排——组内顺序即
  /// 排列结果，默认排序时即歌单原序。
  List<PlaylistSongGroup> _computeGroups(
      DirectSourceManager direct, bool searching) {
    if (searching) return const [];
    final mode = direct.settings.groupPlaylistDetail;
    if (mode == PlaylistGroup.none) return const [];
    return groupPlaylistSongs(_songs, mode, (s) {
      final src = direct.sourceByKey(s.sourceKey);
      return src == null ? '' : stripPrefixForSource(src);
    });
  }

  void _persistCollapsed(AppSettings settings, List<PlaylistSongGroup> groups) {
    final names = {for (final g in groups) g.name};
    settings.setPlaylistGroupCollapsed(
        widget.playlistId, _collapsed.intersection(names));
  }

  void _toggleCollapse(
      AppSettings settings, List<PlaylistSongGroup> groups, String name) {
    setState(() {
      if (!_collapsed.remove(name)) _collapsed.add(name);
      _persistCollapsed(settings, groups);
    });
  }

  /// 长按任意标题行：有展开组则全折叠，否则全展开。
  void _toggleAllCollapse(
      AppSettings settings, List<PlaylistSongGroup> groups) {
    final anyExpanded = groups.any((g) => !_collapsed.contains(g.name));
    setState(() {
      if (anyExpanded) {
        _collapsed = {for (final g in groups) g.name};
      } else {
        _collapsed = {};
      }
      _persistCollapsed(settings, groups);
    });
  }

  /// 播放本组歌曲（播完即止），锚点与整单播放一致。
  Future<void> _playGroup(BuildContext c, List<Song> list) async {
    if (list.isEmpty) return;
    final provider = c.read<PlaylistsProvider>();
    final uuid =
        await provider.store.index.ensurePlaylistUuid(widget.playlistId);
    if (!c.mounted) return;
    final player = c.read<PlayerProvider>();
    player.playQueue(list,
        index: 0,
        playlistUuid: uuid,
        contextKey: PlayerProvider.anchorForPlaylist(uuid),
        resetAnchor: true,
        resumeFromBreakpoint: false);
    c.read<NavigationProvider>().openPlayer();
  }

  /// 兜底/重进定位到第 [index] 行（展示行序，含组头偏移）：
  /// 一次精确 jumpTo（固定行高保证落点必在视口内）。
  void _scrollToCurrent(int index) {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_focusOffset(index)
        .clamp(0.0, _scroll.position.maxScrollExtent));
  }

  /// 当前播放歌曲在展示行序列里的位置（含组头行/搜索/排序偏移；
  /// -1 = 未加载或不在本歌单）。口径与 build 内 currentPos 一致，
  /// 供 tick 追焦在 build 之外复用。
  int _currentDisplayPos() {
    final provider = context.read<PlaylistsProvider>();
    if (!provider.loaded) return -1;
    final direct = context.read<DirectSourceManager>();
    final player = context.read<PlayerProvider>();
    _syncSongs(provider, direct.settings.sortPlaylistDetail, direct.weight);
    _ensureCollapsed(direct.settings);
    final query = (widget.globalSearch
            ? context.read<NavigationProvider>().search
            : _localQuery)
        .trim()
        .toLowerCase();
    final visible = <int>[
      for (var i = 0; i < _songs.length; i++)
        if (songMatchesQuery(_songs[i], query)) i,
    ];
    final groups = _computeGroups(direct, query.isNotEmpty);
    final rows = buildPlaylistDisplayRows(
        groups: groups, visible: visible, collapsed: _collapsed);
    final songIdx = _songs.indexWhere((s) => player.isCurrent(s));
    if (songIdx < 0) return -1;
    return rows.indexWhere((r) => r.full == songIdx);
  }

  /// 重进歌单页：下一帧再跳（回调可能发生在滚动/通知分发期间）。
  void _onFocusTick() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pos = _currentDisplayPos();
      if (pos >= 0) _scrollToCurrent(pos);
    });
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
      _syncSongs(provider, direct.settings.sortPlaylistDetail, direct.weight);
      _ensureCollapsed(direct.settings);
      final groups = _computeGroups(direct, false);
      final rows = buildPlaylistDisplayRows(
        groups: groups,
        visible: [for (var i = 0; i < _songs.length; i++) i],
        collapsed: _collapsed,
      );
      final songIdx = _songs.indexWhere(player.isCurrent);
      if (songIdx >= 0) {
        firstIdx = rows.indexWhere((r) => r.full == songIdx);
      }
    }
    if (firstIdx >= 0) {
      _scroll = ScrollController(initialScrollOffset: _focusOffset(firstIdx));
      _located = true;
    } else {
      _scroll = ScrollController();
    }
    widget.focusTick?.addListener(_onFocusTick);
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
    // 订阅收窄（T012）：仅在"全局搜索"场景（内容区歌单详情）订阅全局搜索词；
    // 播放器带的歌单页（globalSearch=false）选择恒定的 '' 值、不订阅搜索词，
    // 全局搜索变化不重建。区段索引变更两种场景都不重建。
    final search = context.select<NavigationProvider, String>(
        (n) => widget.globalSearch ? n.search : '');
    final provider = context.watch<PlaylistsProvider>();
    final player = context.watch<PlayerProvider>();
    final direct = context.watch<DirectSourceManager>();

    PlaylistRow? playlist;
    for (final p in provider.playlists) {
      if (p.id == widget.playlistId) playlist = p;
    }
    // 数据版本不变时复用缓存的歌单条目（避免每帧/每次通知重查 SQLite）。
    _syncSongs(provider, direct.settings.sortPlaylistDetail, direct.weight);
    // 搜索：全局搜索框（内容区）或页内自带搜索框（歌单页）过滤；visible 为原始下标映射。
    final query = (widget.globalSearch ? search.trim() : _localQuery.trim())
        .toLowerCase();
    final searching = query.isNotEmpty;
    final visible = <int>[
      for (var i = 0; i < _songs.length; i++)
        if (songMatchesQuery(_songs[i], query)) i,
    ];
    final currentIdx = _songs.indexWhere((s) => player.isCurrent(s));
    // 多选键：与行渲染同源的 _songs 实时行（visible 为下标映射）。
    final visibleKeys = [for (final i in visible) songKey(_songs[i])];
    // 分组（视图层稳定分区；搜索中/分类「无」时为空，即平铺）。
    _ensureCollapsed(direct.settings);
    final groupMode = direct.settings.groupPlaylistDetail;
    final groups = _computeGroups(direct, searching);
    final grouped = groups.isNotEmpty;
    final rows = buildPlaylistDisplayRows(
      groups: groups,
      visible: visible,
      collapsed: _collapsed,
    );
    final currentPos = currentIdx < 0
        ? -1
        : rows.indexWhere((r) => r.full == currentIdx);
    final groupByName = {for (final g in groups) g.name: g};

    // 行级视图数据（R-1）：一次性算好派生文本/收藏/播放/选中等低频数据，
    // 签名不变时复用整表；行组件由此以值参数渲染，不再逐行订阅管理器。
    final wide = MediaQuery.sizeOf(context).width >= kSongTileWideInfoWidth;
    _rowCache.begin(
      (
        identityHashCode(_songs),
        provider.dataRevision,
        _sort,
        direct.favoriteVersion,
        direct.metaVersion,
        direct.settingsVersion,
        direct.settings.songTitleFormat,
        wide,
        currentIdx,
        _sel.active,
        Object.hashAll(_sel.selected),
      ),
      _songs.length,
      onWarm: () => direct.weight.warmMetaOf(_songs),
    );

    // 打开歌单后自动定位到当前播放歌曲（仅一次；按展示行位置，含组头行偏移）。
    if (!_located && currentPos >= 0) {
      _located = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCurrent(currentPos);
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
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PlaylistGroupButton(
                  value: groupMode,
                  onChanged: (v) => setState(
                      () => direct.settings.groupPlaylistDetail = v),
                ),
                SortMenuButton(
                  value: direct.settings.sortPlaylistDetail,
                  onChanged: (v) => setState(
                      () => direct.settings.sortPlaylistDetail = v),
                ),
              ],
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
                      count: rows.length,
                      itemBuilder: (c, i) {
                        final row = rows[i];
                        // 分组标题行（72 高，与歌曲行同高，RowList 固定行高不受影响）。
                        if (row.header != null) {
                          final name = row.header!;
                          final g = groupByName[name]!;
                          final collapsed = _collapsed.contains(name);
                          final scheme = Theme.of(c).colorScheme;
                          return ListTile(
                            leading: Container(
                              width: 44,
                              height: 44,
                              decoration: ShapeDecoration(
                                color: scheme.primary.withValues(alpha: 0.10),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(6)),
                              ),
                              child: Icon(
                                  groupMode == PlaylistGroup.folder
                                      ? Icons.folder
                                      : Icons.album,
                                  color: scheme.primary,
                                  size: 24),
                            ),
                            title: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text('${g.count} 首',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.play_arrow),
                                  tooltip: '播放该分组',
                                  onPressed: () => _playGroup(c, [
                                    for (final fi in g.songIndices) _songs[fi],
                                  ]),
                                ),
                                Icon(collapsed
                                    ? Icons.expand_more
                                    : Icons.expand_less),
                              ],
                            ),
                            onTap: () => _toggleCollapse(
                                direct.settings, groups, name),
                            // 长按任意标题行：有展开组则全折叠，否则全展开。
                            onLongPress: () => _toggleAllCollapse(
                                direct.settings, groups),
                          );
                        }
                        final full = row.full!;
                        final itemRow = _items[full];
                        final s = _songs[full];
                        final isFirst = i == 0;
                        final isLast = i == rows.length - 1;
                        final key = songKey(s);
                        return SongTile(
                          song: s,
                          // 歌单详情取自本地索引，不提供直连源（不显示「缓存」项）。
                          source: null,
                          // 行级视图数据（R-1）：行组件纯参数渲染、不订阅管理器。
                          // 按需懒派生：访问到的行才算（首帧只算可见行）。
                          row: _rowCache.rowAt(full, () {
                            final meta = direct.weight.metaOf(s);
                            return SongRowView.of(
                              song: s,
                              titleFormat: direct.settings.songTitleFormat,
                              playing: full == currentIdx,
                              selected: _sel.contains(key),
                              favorite: meta.favorite,
                              disliked: meta.frozen,
                              isFirst: full == 0,
                              isLast: full == _songs.length - 1,
                              wide: wide,
                            );
                          }),
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
                          // 分组视图是重排展示，手动调序只在平铺下有意义：
                          // 分组时隐藏上移/下移，仅保留移除。
                          extraMenuItems: grouped
                              ? const [
                                  PopupMenuItem(
                                    value: 'row:remove',
                                    child: Text('移除'),
                                  ),
                                ]
                              : [
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
                                      widget.playlistId, itemRow, -1);
                                }
                              case 'row:down':
                                if (!isLast) {
                                  provider.moveItemRow(
                                      widget.playlistId, itemRow, 1);
                                }
                              case 'row:remove':
                                provider.removeItemRow(
                                    widget.playlistId, itemRow);
                                _notifyPlayerRemoved(
                                    provider, [provider.songOf(itemRow)]);
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

/// 歌单详情展示行：组头行（header 非空、full 为空）或歌曲行
/// （full 为歌曲在已排序歌单中的下标）。
///
/// 分组只是视图层稳定分区，不改变底层歌曲顺序：点歌/多选/移除一律按 full
/// 下标回到底层，点歌仍播整单。搜索中或分类为「无」时退化为平铺。
typedef PlaylistDisplayRow = ({String? header, int? full});

List<PlaylistDisplayRow> buildPlaylistDisplayRows({
  required List<PlaylistSongGroup> groups,
  required List<int> visible,
  required Set<String> collapsed,
}) {
  if (groups.isEmpty) {
    return [for (final i in visible) (header: null, full: i)];
  }
  final rows = <PlaylistDisplayRow>[];
  for (final g in groups) {
    rows.add((header: g.name, full: null));
    if (collapsed.contains(g.name)) continue;
    for (final i in g.songIndices) {
      rows.add((header: null, full: i));
    }
  }
  return rows;
}

/// 歌单详情「分类方式」按钮（挂在计数栏右侧、排列按钮左边）：
/// 无 / 文件夹（直接父级）/ 专辑，当前项打勾。
class PlaylistGroupButton extends StatelessWidget {
  final PlaylistGroup value;
  final ValueChanged<PlaylistGroup> onChanged;

  const PlaylistGroupButton({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<PlaylistGroup>(
      tooltip: '分类方式',
      icon: Icon(
        switch (value) {
          PlaylistGroup.folder => Icons.folder_outlined,
          PlaylistGroup.album => Icons.album_outlined,
          PlaylistGroup.none => Icons.category_outlined,
        },
        size: 20,
      ),
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final m in PlaylistGroup.values)
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
                Text(m.label),
              ],
            ),
          ),
      ],
    );
  }
}
