import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../providers/navigation_provider.dart';
import 'screen_metrics.dart';

/// 内容详情页的统一入口目标。
///
/// 三套既有详情（歌单 id / 专辑·歌手快照 / 源 key）在这里收成一族 target：
/// 入口函数只构造 target，[openDetail] 负责「是否已在显示」的去重与导航写入。
/// 导航状态仍由 `NavigationProvider` 的既有字段持有（details /
/// browsingPlaylistId / browsingSourceKey），不新增"选中态"。
///
/// 窄屏的专辑/歌手拖拽弹层由 `library_screen.dart` 的入口函数分流，不经过
/// [openDetail]（弹层需要页面私有构建器）；歌单/播放源的整页子视图在两种屏宽
/// 下都走这里。
sealed class DetailTarget {
  const DetailTarget();

  /// 该目标是否已经显示（重复点同一行不再压栈/换栏）。
  bool isShowing(NavigationProvider nav);
}

class PlaylistTarget extends DetailTarget {
  const PlaylistTarget(this.id);

  final int id;

  @override
  bool isShowing(NavigationProvider nav) => nav.browsingPlaylistId == id;
}

class SourceTarget extends DetailTarget {
  const SourceTarget(this.key);

  final String key;

  @override
  bool isShowing(NavigationProvider nav) => nav.browsingSourceKey == key;
}

/// 专辑详情。[fromDetail] = true 表示从详情内部进入（歌手页专辑横条等）：
/// 宽屏分栏时压在上一层之上，而不是把详情栈重置为这一层。
class AlbumTarget extends DetailTarget {
  const AlbumTarget(this.album, this.songs, {this.fromDetail = false});

  final Album album;
  final List<Song> songs;
  final bool fromDetail;

  @override
  bool isShowing(NavigationProvider nav) {
    final details = nav.details;
    if (details.isEmpty) return false;
    final top = details.last;
    return top is AlbumDetailRoute && top.album.groupKey == album.groupKey;
  }
}

/// 歌手详情。[fromDetail] 语义同 [AlbumTarget]；去重覆盖整个详情栈
/// （"歌手 → 专辑"嵌套时点回同一歌手不再压栈）。
class ArtistTarget extends DetailTarget {
  const ArtistTarget(this.artist, this.songs, {this.fromDetail = false});

  final Artist artist;
  final List<Song> songs;
  final bool fromDetail;

  @override
  bool isShowing(NavigationProvider nav) {
    final key = artist.identityKey ?? artist.name;
    for (final route in nav.details) {
      if (route is ArtistDetailRoute &&
          (route.artist.identityKey ?? route.artist.name) == key) {
        return true;
      }
    }
    return false;
  }
}

/// 统一详情入口（宽屏/分栏路径）：去重后按目标类型写入导航状态。
///
/// [keepSearch] 统一按 [splitDetailActive] 判定：分栏时搜索框是左栏过滤器，
/// 进详情不清词；整页/卡片呈现沿用旧口径清空。
void openDetail(BuildContext context, DetailTarget target) {
  final nav = context.read<NavigationProvider>();
  if (target.isShowing(nav)) return;
  final split = splitDetailActive(context);
  switch (target) {
    case PlaylistTarget(:final id):
      nav.enterPlaylist(id, keepSearch: split);
    case SourceTarget(:final key):
      nav.enterSource(key, keepSearch: split);
    case AlbumTarget(:final album, :final songs, :final fromDetail):
      nav.enterAlbum(album, songs,
          keepSearch: split, root: split && !fromDetail);
    case ArtistTarget(:final artist, :final songs, :final fromDetail):
      nav.enterArtist(artist, songs,
          keepSearch: split, root: split && !fromDetail);
  }
}
