import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../layout/app_shell.dart';
import '../../navigation/detail_target.dart';
import '../../models/song.dart';
import '../../models/album.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/detail_presentation.dart';
import '../../widgets/draggable_sheet.dart';
import '../../widgets/song_table.dart';
import '../../widgets/song_table_sliver.dart';
import '../../widgets/song_tile.dart';
import '../../widgets/square_card.dart';
import 'shared.dart';

/// 专辑副标题 spans：主歌手正常色、其余合作者淡化，末尾跟曲目数。
/// 列表行与方形卡片共用，保证两处展示一致。
InlineSpan albumSubtitleSpan(BuildContext context, Album album) {
  final scheme = Theme.of(context).colorScheme;
  final main = scheme.onSurface.withValues(alpha: 0.6);
  final faint = scheme.onSurface.withValues(alpha: 0.38);
  final parts = album.artists.isEmpty ? [album.artist] : album.artists;
  final spans = <InlineSpan>[];
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) {
      spans.add(TextSpan(text: '、', style: TextStyle(color: faint)));
    }
    spans.add(TextSpan(
        text: zhDisplay(parts[i]),
        style: TextStyle(color: i == 0 ? main : faint)));
  }
  spans.add(
      TextSpan(text: ' · ${album.trackCount}首', style: TextStyle(color: main)));
  return TextSpan(children: spans);
}

/// 打开专辑歌曲详情：宽屏=内容区整页（叠层，底层列表保活），窄屏=统一拖拽弹层。
///
/// 大横屏分栏时详情进右栏（同一份 [detailPageOf]），左栏列表原地保活。
Future<void> openAlbum(BuildContext context, Album album) async {
  final lib = context.read<LibraryProvider>();
  final songs = lib.albumSongs(album);
  if (!context.mounted) return;
  if (AppShell.isWide(context)) {
    openDetail(context, AlbumTarget(album, songs));
    return;
  }
  await showAppDraggableSheet<void>(
    context,
    builder: (c, scrollCtrl) =>
        AlbumSongsSheet(album: album, songs: songs, scrollCtrl: scrollCtrl),
  );
}

class AlbumListTile extends StatelessWidget {
  final Album album;

  /// 分栏时是否为「当前详情」对应的左栏行（只做底色提示，不改文字色）。
  final bool active;
  const AlbumListTile({required this.album, this.active = false});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      // tileColor 由 ListTile 自己画在 Material 上：不插入额外图层，
      // 墨迹/涟漪仍落在正确的 Material 上（见 page_transition 的历史坑）。
      tileColor: active
          ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
          : null,
      leading:
          CoverThumb(coverPath: album.coverPath, fallbackIcon: Icons.album),
      title: Text(zhDisplay(album.album),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodyLarge
              ?.copyWith(fontWeight: FontWeight.w600)),
      subtitle: RichText(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
              style: DefaultTextStyle.of(context).style,
              children: [albumSubtitleSpan(context, album)])),
      onTap: () => openAlbum(context, album),
    );
  }
}

class AlbumCard extends StatelessWidget {
  final Album album;
  const AlbumCard({required this.album});

  @override
  Widget build(BuildContext context) {
    final parts = album.artists.isEmpty ? [album.artist] : album.artists;
    return SquareCard(
      title: zhDisplay(album.album),
      subtitle: '${parts.map(zhDisplay).join('、')} · ${album.trackCount}首',
      subtitleSpan: albumSubtitleSpan(context, album),
      coverPath: album.coverPath,
      fallbackIcon: Icons.album,
      onTap: () => openAlbum(context, album),
    );
  }
}

class AlbumSongsSheet extends StatelessWidget {
  final Album album;
  final List<Song> songs;

  /// 统一拖拽式窗口下发的共享滚动轴（头部与列表共轴，见 [showAppDraggableSheet]）。
  final ScrollController scrollCtrl;
  const AlbumSongsSheet(
      {required this.album, required this.songs, required this.scrollCtrl});

  @override
  Widget build(BuildContext context) {
    return AlbumSongsView(
      album: album,
      songs: songs,
      scrollCtrl: scrollCtrl,
      fromSheet: true,
      header:
          AppSheetTitleBar(title: zhDisplay(album.album), count: songs.length),
    );
  }
}

/// 专辑歌曲视图（窄屏弹层 / 宽屏整页共用）。
///
/// 只差外壳：弹层带把手/关闭按钮、点歌先关窗；整页带返回箭头、点歌不关页
///（播放页盖在上方，关掉播放页回到详情）。列表与计数口径完全一致。
class AlbumSongsView extends StatelessWidget {
  final Album album;
  final List<Song> songs;
  final ScrollController scrollCtrl;
  final Widget header;

  /// true=窄屏弹层（点歌先 pop 关窗）；false=宽屏整页（保持页面）。
  final bool fromSheet;

  const AlbumSongsView({
    required this.album,
    required this.songs,
    required this.scrollCtrl,
    required this.header,
    required this.fromSheet,
  });

  @override
  Widget build(BuildContext context) {
    final player = context.read<PlayerProvider>();
    final lib = context.read<LibraryProvider>();
    final nav = context.read<NavigationProvider>();
    return LayoutBuilder(builder: (context, constraints) {
      final table = SongTableLayout.fit(constraints.maxWidth);
      return CustomScrollView(
        controller: scrollCtrl,
        slivers: [
          // 置顶标题行：滚动歌曲时专辑名/歌曲数常驻顶部（与队列/歌手弹层同构）。
          AppSheetHeader(
            height: AppSheetTitleBar.heightOf(context),
            child: header,
          ),
          SongTableSliverList(
            songs: songs,
            table: table,
            sourceOf: (s) => lib.sourceFor(s.sourceKey),
            onPlay: (i) {
              if (fromSheet) Navigator.of(context).pop();
              player.playQueue(songs,
                  index: i,
                  contextKey: PlayerProvider.anchorForAlbum(album.id));
              nav.openPlayer();
            },
          ),
        ],
      );
    });
  }
}

class AlbumDetailPage extends StatefulWidget {
  final Album album;
  final List<Song> songs;
  const AlbumDetailPage({required this.album, required this.songs});

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 冷启动恢复的详情路由只带专辑元信息（不持久化歌曲快照）：曲库加载
    // 完成后按 groupKey 从这里补出歌曲；正常进入仍用打开时的快照。
    final lib = context.watch<LibraryProvider>();
    final songs =
        widget.songs.isEmpty ? lib.albumSongs(widget.album) : widget.songs;
    return DetailPresentationShell(
      presentation: DetailPresentation.overlay,
      child: AlbumSongsView(
        album: widget.album,
        songs: songs,
        scrollCtrl: _scroll,
        fromSheet: false,
        header: AppSheetTitleBar(
          title: zhDisplay(widget.album.album),
          count: songs.length,
          leading: const DetailBackButton(),
          showClose: false,
        ),
      ),
    );
  }
}
