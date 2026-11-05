import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../layout/app_shell.dart';
import '../../navigation/detail_target.dart';
import '../../models/song.dart';
import '../../models/album.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/draggable_sheet.dart';
import '../../widgets/song_tile.dart';
import 'album_detail.dart';

/// 歌手弹页的「专辑」区：把该歌手的歌曲按全局专辑分组键（专辑歌手? 否则曲目
/// 歌手 + 专辑名）聚合，与列表行「N 张专辑」同一口径。点专辑打开其歌曲弹层
/// （只含该歌手的曲目，合辑不会带进同专辑的其他歌手）。
class ArtistAlbumsStrip extends StatelessWidget {
  final List<Album> albums;
  final List<Song> artistSongs;
  const ArtistAlbumsStrip({required this.albums, required this.artistSongs});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('专辑 (${albums.length})',
              style: TextStyle(
                  fontSize: 12,
                  color: cs.primary,
                  fontWeight: FontWeight.w600)),
        ),
        SizedBox(
          height: 104,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: albums.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (c, i) {
              final album = albums[i];
              return InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _openAlbumOfArtist(context, album),
                child: SizedBox(
                  width: 72,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CoverThumb(
                          coverPath: album.coverPath,
                          fallbackIcon: Icons.album),
                      const SizedBox(height: 4),
                      Text(zhDisplay(album.album),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12)),
                      Text('${album.trackCount}首',
                          style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).disabledColor)),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _openAlbumOfArtist(BuildContext context, Album album) {
    final songs = artistSongs.where((s) => album.containsSong(s)).toList();
    if (AppShell.isWide(context)) {
      // 详情内部进入：压在歌手层之上，不重置详情栈。
      openDetail(context, AlbumTarget(album, songs, fromDetail: true));
      return;
    }
    showAppDraggableSheet<void>(
      context,
      builder: (c, scrollCtrl) =>
          AlbumSongsSheet(album: album, songs: songs, scrollCtrl: scrollCtrl),
    );
  }
}
