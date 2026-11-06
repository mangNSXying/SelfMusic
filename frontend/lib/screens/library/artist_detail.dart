import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../data/local/local_index.dart';
import '../../layout/screen_metrics.dart';
import '../../models/song.dart';
import '../../models/album.dart';
import '../../models/artist.dart';
import '../../services/artist_resolver.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/corner_add_button.dart';
import '../../widgets/detail_presentation.dart';
import '../../widgets/draggable_sheet.dart';
import 'artist_albums_strip.dart';
import 'artist_entries.dart';
import 'entry_songs_view.dart';
import 'shared.dart';

class ArtistSongsSheet extends StatelessWidget {
  final Artist artist;
  final List<Song> songs;

  /// 统一拖拽式窗口下发的共享滚动轴（头部与列表共轴，见 [showAppDraggableSheet]）。
  final ScrollController scrollCtrl;
  const ArtistSongsSheet(
      {required this.artist, required this.songs, required this.scrollCtrl});

  @override
  Widget build(BuildContext context) {
    final lib = context.read<LibraryProvider>();
    // 详情只在人物身份下有内容（组合/角色的关系挂在成员树上，不在这里展开）。
    // 只查一次：artistDetail 会跑展示曲目数统计，别在 build 里查两遍。
    final detail = lib.artistDetail(artist);
    // 本歌手的专辑：与列表行「N 张专辑」同一分组口径（Album.fromSongs），
    // 所以这里的专辑个数应与 artist.albumCount 一致。
    final albums = Album.fromSongs(songs);
    return ArtistSongsView(
      artist: artist,
      songs: songs,
      detail: detail,
      albums: albums,
      scrollCtrl: scrollCtrl,
      fromSheet: true,
    );
  }
}

/// 歌手歌曲视图（窄屏弹层 / 宽屏整页共用）：
/// 标题栏 + 专辑横条 + 详情块 + 歌曲列表 + 右下「重新解析」。
class ArtistSongsView extends StatelessWidget {
  final Artist artist;
  final List<Song> songs;
  final ArtistDetail? detail;
  final List<Album> albums;
  final ScrollController scrollCtrl;

  /// true=窄屏弹层（点歌/重新解析先关窗）；false=宽屏整页（保持页面）。
  final bool fromSheet;

  const ArtistSongsView({
    required this.artist,
    required this.songs,
    required this.detail,
    required this.albums,
    required this.scrollCtrl,
    required this.fromSheet,
  });

  @override
  Widget build(BuildContext context) {
    final leading = (albums.isEmpty && detail == null)
        ? null
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (albums.isNotEmpty)
                ArtistAlbumsStrip(albums: albums, artistSongs: songs),
              if (detail != null) _ArtistDetailBlock(detail: detail!),
            ],
          );
    return CornerFabLayer(
      content: EntrySongsView(
        songs: songs,
        scrollCtrl: scrollCtrl,
        title: zhDisplay(artist.name),
        headerLeading: fromSheet ? null : const DetailBackButton(),
        showClose: fromSheet,
        fromSheet: fromSheet,
        contextKey: PlayerProvider.anchorForArtist(artist.name),
        leading: leading,
      ),
      // 「重新解析」放歌手详情页右下角：只重拉这一位（含成员展开）。
      fab: CornerAddButton(
        icon: Icons.sync_alt,
        label: '重新解析',
        tooltip: '重新解析 ${zhDisplay(artist.name)}',
        onPressed: () => _forceReParse(context),
      ),
    );
  }

  /// 把这一位歌手打回 pending 并直跑一轮（含已解析成功的），受 MB 1 req/s 限流。
  Future<void> _forceReParse(BuildContext context) async {
    final resolver = context.read<ArtistResolver>();
    final nav = context.read<NavigationProvider>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('重新解析「${zhDisplay(artist.name)}」？'),
        content: const Text('会清掉这一位歌手已有的 MusicBrainz 绑定，重新搜索并拉取关系；'
            '可能改判到另一个同名实体，组合成员也会重新展开。'),
        actions: appDialogActions(
          c,
          confirmLabel: '开始',
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok != true) return;
    // 弹页/整页里的歌曲/详情是打开那一刻的快照，解析完身份可能变（合流、改判
    // 真人），留着旧数据容易误读：先退出详情（弹层关窗/整页出栈），列表会就
    // 地刷新。
    if (!context.mounted) return;
    if (fromSheet) {
      Navigator.of(context).pop();
    } else {
      nav.exitDetail(keepSearch: splitDetailActive(context));
    }
    await resolver.forceRetryOne(
        artistKey: artist.identityKey, canonicalKey: artist.canonicalKey);
    AppToast.show('已开始重新解析 ${zhDisplay(artist.name)}', isError: false);
  }
}

/// 宽屏歌手详情页：内容区整页（铺满，无宽度上限），内容与窄屏弹层同构。
class ArtistDetailPage extends StatefulWidget {
  final Artist artist;
  final List<Song> songs;
  const ArtistDetailPage({required this.artist, required this.songs});

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  final ScrollController _scroll = ScrollController();

  /// 正常进入时的打开时刻快照（与弹层一致）：只取一次，不随播放/后台通知重算。
  /// 冷启动恢复的路由没有歌曲快照，此时为 null / 空，改由曲库解析。
  ArtistDetail? _detail;
  List<Album> _albums = const [];
  List<Song>? _albumsBase;

  @override
  void initState() {
    super.initState();
    if (widget.songs.isNotEmpty) {
      _detail = context.read<LibraryProvider>().artistDetail(widget.artist);
      _albums = Album.fromSongs(widget.songs);
      _albumsBase = widget.songs;
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  List<Album> _albumsFor(List<Song> songs) {
    if (identical(songs, _albumsBase)) return _albums;
    _albumsBase = songs;
    return _albums = Album.fromSongs(songs);
  }

  @override
  Widget build(BuildContext context) {
    // 同专辑详情：冷启动恢复时 songs 为空，等曲库就绪后按身份键补出歌曲，
    // 让页面在加载完成的通知里自然重建。
    final lib = context.watch<LibraryProvider>();
    final songs =
        widget.songs.isEmpty ? lib.artistSongs(widget.artist) : widget.songs;
    return DetailPresentationShell(
      presentation: DetailPresentation.overlay,
      child: ArtistSongsView(
        artist: widget.artist,
        songs: songs,
        detail: _detail ?? lib.artistDetail(widget.artist),
        albums: _albumsFor(songs),
        scrollCtrl: _scroll,
        fromSheet: false,
      ),
    );
  }
}

/// 歌手弹页里的「详情」区：只在人物身份下有内容，默认收起，展开后是
/// 组合 / 角色 / 成员三栏。带本地身份键的行可以点进去。
class _ArtistDetailBlock extends StatefulWidget {
  final ArtistDetail detail;
  const _ArtistDetailBlock({required this.detail});

  @override
  State<_ArtistDetailBlock> createState() => _ArtistDetailBlockState();
}

class _ArtistDetailBlockState extends State<_ArtistDetailBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.detail;
    if (d.isEmpty) return const SizedBox.shrink();
    final n = d.bands.length + d.roles.length + d.members.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Icon(_open ? Icons.expand_less : Icons.expand_more,
                    size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 4),
                const Text('详情', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Text('($n)',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary)),
              ],
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _refSection(context, '组合', d.bands, Icons.groups) ??
                    const SizedBox.shrink(),
                _refSection(context, '角色', d.roles, Icons.theater_comedy) ??
                    const SizedBox.shrink(),
                _refSection(context, '成员', d.members, Icons.person) ??
                    const SizedBox.shrink(),
              ],
            ),
          ),
      ],
    );
  }

  Widget? _refSection(
      BuildContext context, String title, List<ArtistRef> refs, IconData icon) {
    if (refs.isEmpty) return null;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12,
                  color: cs.primary,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          for (final r in refs) _refRow(context, r, icon),
        ],
      ),
    );
  }

  Widget _refRow(BuildContext context, ArtistRef r, IconData icon) {
    final sub = _subtitle(r);
    return InkWell(
      // 本地没这条身份的行只能看，不能点进去。
      onTap: r.artistKey == null ? null : () => _openArtistByKey(context, r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 16, color: Theme.of(context).disabledColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(zhDisplay(r.name),
                      style: const TextStyle(fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                  if (sub != null)
                    Text(sub,
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).disabledColor)),
                ],
              ),
            ),
            if (r.artistKey != null) const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }

  /// 第二行：作品名/副标题 + 曲目数。本地没身份就没有曲目数。
  String? _subtitle(ArtistRef r) {
    final parts = <String>[];
    if (r.disambiguation != null) parts.add(zhDisplay(r.disambiguation!));
    if (r.songCount != null) {
      parts.add('${r.songCount} 首');
    } else {
      parts.add('未建档');
    }
    return parts.join(' · ');
  }

  void _openArtistByKey(BuildContext context, ArtistRef ref) {
    final key = ref.artistKey!;
    // 详情里的关联身份未必在歌手页当前列表里（没歌、没被筛进来），所以带
    // 显示名/曲目数兜一个临时条目，弹页标题和列表才对得上。
    openArtist(
        context,
        Artist(
          name: ref.name,
          songCount: ref.songCount ?? 0,
          albumCount: 0,
          identityKey: key,
          canonicalKey: key,
          status: 'resolved',
        ),
        context.read<ArtistResolver>(),
        // 从详情里的关联身份进入：压在上一层之上，可逐级返回。
        fromDetail: true);
  }
}
