import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import '../utils/duration_format.dart';
import '../utils/song_title_format.dart';
import 'add_to_playlist.dart';
import 'selection_badge.dart';
import 'app_toast.dart';

/// 通用歌曲条目：封面缩略图 + 标题 + 歌手/专辑/专辑歌手 + 时长时间器。
///
/// 收藏/不喜欢/缓存等操作统一收进右侧三点菜单（列表保持清爽，方便多选）。
/// 收藏（喜欢）对所有歌曲生效（统一收口到 play_meta）；缓存仅直连歌曲。
///
/// 多选模式：当 [selectionMode] 为 true 时，leading 变为选择框，
/// 点击条目切换勾选，[onSelect] 负责切换 [selected]。
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

  /// 紧凑形态（播放队列面板用）：不显示封面，副标题只留歌手，不带尾部菜单。
  ///
  /// 行高与分隔线仍与普通列表一致（`RowList`），保持滚动与定位手感统一。
  final bool compact;

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
    this.compact = false,
    this.extraMenuItems,
    this.onExtraMenu,
  });

  /// 副标题：歌手 · 专辑（· 专辑歌手，仅当与歌手不同时展示，避免冗余）。
  /// 紧凑形态（队列）只留歌手。
  String get _subtitle {
    final artist = song.artist ?? 'Unknown';
    final parts = <String>[artist];
    final album = compact ? null : song.albumName;
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
      // 多选态不再顶替封面：勾选框叠在封面左上角（无封面时才顶替 leading）。
      leading: compact ? const Icon(Icons.music_note) : _leading(),
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
      // 尾部：紧凑态无尾部；多选态保留时长（信息）但隐藏单曲菜单（防误触）；
      // 普通态是时长 + 三点菜单。
      trailing: compact
          ? null
          : selectionMode
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