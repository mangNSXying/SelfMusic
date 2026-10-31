import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../utils/cover_thumb.dart';
import '../utils/duration_format.dart';
import '../utils/song_title_format.dart';
import 'add_to_playlist.dart';
import 'app_dialog_actions.dart';
import 'app_toast.dart';
import 'context_menu.dart';
import 'edit_song_meta_dialog.dart';
import 'selection_badge.dart';
import 'song_info_dialog.dart';
import 'song_row_view.dart';
import 'song_table.dart';

/// SongTile 行宽达到该值时，在时长左侧补充技术信息（播放源 · 格式 · 码率 · 大小）。
///
/// 阈值按行实际宽度判定（LayoutBuilder）：桌面/平板整宽列表满足；队列面板
/// （固定 360）等窄容器自动不显示。表格模式使用同一阈值。
const double kSongTileWideInfoWidth = kSongTableMinWidth;

/// 通用歌曲列表：封面缩略图 + 标题 + 歌手/专辑/专辑歌手 + 时长时间器。
///
/// 收藏/不喜欢/缓存等操作统一收进右侧三点菜单（列表保持清爽，方便多选）。
/// 收藏（喜欢）对所有歌曲生效（统一收口到 play_meta）；缓存仅直连歌曲。
/// 宽行（≥ [kSongTileWideInfoWidth]）额外在时长左侧显示播放源/格式/码率/大小。
///
/// 多选模式：当 [selectionMode] 为 true 时，leading 变为选择框，
/// 点击列表切换勾选，[onSelect] 负责切换 [selected]。
class SongTile extends StatelessWidget {
  final Song song;

  /// 行级不可变视图数据（R-1）：非空时走**纯参数渲染**——不订阅
  /// [DirectSourceManager]、不做逐行 LayoutBuilder、派生文本已算好；
  /// 为空时为兼容路径（旧调用方/单测），行为与改动前一致。
  final SongRowView? row;

  /// 表格模式；非空时用 9 列布局渲染（需 [row] 带 tableCells）。
  final SongTableLayout? table;

  /// 表格模式标题缩进像素（源页递归层级；普通行不使用）。
  final double titleIndent;

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
    this.table,
    this.titleIndent = 0,
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

  List<Widget> _stateIcons(bool favorite, bool disliked) => [
        if (favorite)
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Icon(Icons.favorite, size: 15, color: Colors.pink),
          ),
        if (disliked)
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Icon(Icons.thumb_down, size: 15, color: Colors.orange),
          ),
      ];

  Future<void> _cacheSong(
      BuildContext context, DirectSourceManager direct) async {
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
  Future<void> _deleteSong(
      BuildContext context, DirectSourceManager direct) async {
    final src = source;
    if (src == null || !src.supportsWrite) return;
    final ok1 = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除歌曲文件？'),
        content: Text('将从「${src.name}」永久删除「${song.title}」，\n'
            '并清除本地索引、收藏权重、歌词、歌单条目与离线缓存。\n此操作不可恢复。'),
        actions: appDialogActions(
          c,
          confirmLabel: '继续删除',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok1 != true || !context.mounted) return;
    // 二次确认：输入防误删（点按确认即执行，避免再输文字的繁琐）。
    final ok2 = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('再次确认删除'),
        content: Text('确认永久删除「${song.title}」？'),
        actions: appDialogActions(
          c,
          confirmLabel: '确认删除',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
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
  Widget _menu(BuildContext context, DirectSourceManager direct, bool favorite,
      bool disliked) {
    return PopupMenuButton<String>(
      tooltip: '更多',
      icon: const Icon(Icons.more_vert),
      onSelected: (v) =>
          _handleMenuValue(context, direct, favorite, disliked, v),
      itemBuilder: (_) => _menuItems(favorite, disliked),
    );
  }

  /// 菜单项（三点按钮与右键菜单共用）。
  List<PopupMenuEntry<String>> _menuItems(bool favorite, bool disliked) {
    final extra = extraMenuItems;
    return [
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
    ];
  }

  /// 菜单选中回调（三点按钮与右键菜单共用）。
  void _handleMenuValue(BuildContext context, DirectSourceManager direct,
      bool favorite, bool disliked, String v) {
    switch (v) {
      case 'play_next':
        final added = context.read<PlayerProvider>().playNext(song);
        AppToast.show(added ? '已加入下一首播放' : '已在下一首播放队列中', isError: false);
      case 'favorite':
        direct.setFavorite(song, !favorite);
        if (favorite && context.mounted) {
          unawaited(context
              .read<PlayerProvider>()
              .onAnchorSongRemoved(PlayerProvider.anchorForLiked(), song));
        }
        AppToast.show(!favorite ? '已加入喜欢' : '已取消喜欢', isError: false);
      case 'dislike':
        direct.setDisliked(song, !disliked);
        AppToast.show(!disliked ? '已标记不喜欢，权重降到 0.1' : '已取消不喜欢',
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
  }

  /// 右键：在指针位置弹出与三点按钮相同的菜单（多选态由调用方禁用）。
  Future<void> _openContextMenu(BuildContext context,
      DirectSourceManager direct, bool favorite, bool disliked,
      TapDownDetails details) async {
    final picked = await showContextMenuAt<String>(
      context,
      details.globalPosition,
      items: _menuItems(favorite, disliked),
    );
    if (picked != null && context.mounted) {
      _handleMenuValue(context, direct, favorite, disliked, picked);
    }
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

  /// 宽行技术信息：`播放源 · 格式 · 码率 · 大小`，置于时长左侧。
  ///
  /// 计算口径收敛到 [SongRowView.wideInfoOf]，避免与行级数据两处漂移。
  Widget? _wideInfo(BuildContext context, {String? sourceName}) {
    final text = SongRowView.wideInfoOf(song, sourceName: sourceName);
    if (text == null) return null;
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
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
    final layout = table;
    final cells = view.tableCells;
    final tile = layout != null && cells != null
        ? _buildTableTile(context, direct, view, layout, cells)
        : _buildNormalTile(context, direct, view);
    return GestureDetector(
      // 桌面右键：在指针处弹出与三点按钮相同的菜单；多选态不响应（与隐藏按钮一致）。
      onSecondaryTapDown: selectionMode
          ? null
          : (d) => unawaited(_openContextMenu(
              context, direct, view.favorite, view.disliked, d)),
      child: tile,
    );
  }

  /// 普通行：封面 + 标题/副标题 + 时长与菜单。
  Widget _buildNormalTile(
      BuildContext context, DirectSourceManager direct, SongRowView view) {
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
                color:
                    (selectionMode && selected) || playing ? cs.primary : null,
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
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 12),
          ],
          ..._stateIcons(view.favorite, view.disliked),
          Text(formatDuration(song.duration)),
          if (!selectionMode)
            _menu(context, direct, view.favorite, view.disliked),
        ],
      ),
      onTap: selectionMode ? onSelect : onPlay,
      onLongPress: selectionMode ? onSelect : onStartSelect,
    );
  }

  /// 表格行：9 列与表头共用 [SongTableLayout.buildCells]。
  ///
  /// 多选态用 48px 空占位保留菜单列宽，避免标题区域变宽导致列与表头错位。
  Widget _buildTableTile(BuildContext context, DirectSourceManager direct,
      SongRowView view, SongTableLayout layout, SongTableCells cells) {
    final cs = Theme.of(context).colorScheme;
    final secondary = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: cs.onSurfaceVariant);
    final selectedPrimary = (selectionMode && selected) || playing;
    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: kSongTableRowPaddingH),
      horizontalTitleGap: kSongTableCoverGap,
      selected: selectionMode && selected,
      leading: _leading(view.coverPath),
      title: layout.buildCells(
        title: Row(
          children: [
            if (titleIndent > 0) SizedBox(width: titleIndent),
            Expanded(
              child: Text(
                cells.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: selectedPrimary ? cs.primary : null,
                ),
              ),
            ),
            if (playing) ...[
              const SizedBox(width: 4),
              Icon(Icons.graphic_eq, size: 15, color: cs.primary),
            ],
          ],
        ),
        artist: _tableText(cells.artist, secondary),
        album: _tableText(cells.album, secondary),
        source: _tableText(cells.source, secondary),
        format: _tableText(cells.format, secondary),
        bitrate: _tableText(cells.bitrate, secondary, align: TextAlign.right),
        size: _tableText(cells.size, secondary, align: TextAlign.right),
        state: _tableState(view, secondary),
        duration: _tableText(cells.duration, secondary, align: TextAlign.right),
      ),
      trailing: SizedBox(
        width: kSongTableMenuWidth,
        child: selectionMode
            ? null
            : _menu(context, direct, view.favorite, view.disliked),
      ),
      onTap: selectionMode ? onSelect : onPlay,
      onLongPress: selectionMode ? onSelect : onStartSelect,
    );
  }

  static Widget _tableText(String text, TextStyle? style,
      {TextAlign align = TextAlign.left}) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
      style: style?.copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  static Widget _tableState(SongRowView view, TextStyle? style) {
    if (!view.favorite && !view.disliked) {
      return Text(
        '—',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: style,
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (view.favorite)
          const Icon(Icons.favorite, size: 14, color: Colors.pink),
        if (view.favorite && view.disliked) const SizedBox(width: 4),
        if (view.disliked)
          const Icon(Icons.thumb_down, size: 14, color: Colors.orange),
      ],
    );
  }

  /// 兼容路径：未提供行级数据时保留旧行为（订阅管理器 + 逐行 LayoutBuilder）。
  Widget _buildLegacy(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    // 收藏/不喜欢合并为一次 play_meta 查询（列表滑动期每行尽量减少查询）。
    final meta = direct.weight.metaOf(song);
    final favorite = meta.favorite;
    final disliked = meta.frozen;
    // 播放源友好名：优先调用方传入的源，其次按 sourceKey 解析。
    final sourceName = source?.name ?? direct.sourceByKey(song.sourceKey)?.name;
    final layout = table;
    return LayoutBuilder(builder: (context, constraints) {
      if (layout != null) {
        final view = SongRowView.of(
          song: song,
          titleFormat: direct.settings.songTitleFormat,
          sourceName: sourceName,
          playing: playing,
          favorite: favorite,
          disliked: disliked,
          table: true,
        );
        return GestureDetector(
          onSecondaryTapDown: selectionMode
              ? null
              : (d) => unawaited(
                  _openContextMenu(context, direct, favorite, disliked, d)),
          child:
              _buildTableTile(context, direct, view, layout, view.tableCells!),
        );
      }
      // 行宽按实际约束判定：宽行在时长左侧补充技术信息。
      final info = constraints.maxWidth >= kSongTileWideInfoWidth
          ? _wideInfo(context, sourceName: sourceName)
          : null;
      final tile = ListTile(
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
            ..._stateIcons(favorite, disliked),
            Text(formatDuration(song.duration)),
            if (!selectionMode) _menu(context, direct, favorite, disliked),
          ],
        ),
        onTap: selectionMode ? onSelect : onPlay,
        onLongPress: selectionMode ? onSelect : onStartSelect,
      );
      return GestureDetector(
        // 桌面右键：在指针处弹出与三点按钮相同的菜单；多选态不响应（与隐藏按钮一致）。
        onSecondaryTapDown: selectionMode
            ? null
            : (d) => unawaited(
                _openContextMenu(context, direct, favorite, disliked, d)),
        child: tile,
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
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
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
