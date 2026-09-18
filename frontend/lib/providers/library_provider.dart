import 'package:flutter/foundation.dart';
import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import 'direct_source_manager.dart';

/// 全局图库数据源：合并后端（服务器模式）与所有直连源的歌曲，
/// 并在客户端按 专辑/歌手 分组聚合，供「歌曲/专辑/歌手」栏目共用。
class LibraryProvider extends ChangeNotifier {
  /// 全局服务端源（key=`server`）。
  final MusicSource source;
  LibraryProvider(this.source);

  DirectSourceManager? _directManager;

  /// 合并后的全部歌曲（服务器 + 所有直连源）。
  List<Song> songs = [];
  List<Album> albums = [];
  List<Artist> artists = [];
  bool loading = false;
  String? error;

  /// 关联直连源管理器，使「歌曲/专辑/歌手」能合并直连扫描结果。
  void attachDirectManager(DirectSourceManager m) {
    _directManager = m;
    notifyListeners();
  }

  /// 读取全部直连源的歌曲（同步，来自本地索引）。
  List<Song> get directSongs =>
      _directManager?.allSongs() ?? const <Song>[];

  Future<void> loadSongs({String? query}) async {
    loading = true;
    error = null;
    notifyListeners();
    // 服务器不可用时不应阻断直连源歌曲的合并展示（未配对 / 断网场景）。
    List<Song> server = const [];
    try {
      server = await source.fetchSongs(query: query, size: 2000);
    } catch (e) {
      error = '服务端不可用：$e';
    }
    final direct = _directManager?.allSongs(query: query) ?? const <Song>[];
    songs = _mergeSongs(server, direct);
    _recomputeGroups();
    loading = false;
    notifyListeners();
  }

  /// 专辑/歌手从合并后的歌曲列表客户端聚合（统一先刷新歌曲，再由 loadSongs 分组）。
  Future<void> loadAlbums({String? query}) async {
    await loadSongs(query: query);
  }

  Future<void> loadArtists({String? query}) async {
    await loadSongs(query: query);
  }

  /// 客户端专辑查询对应歌曲（按 artist + album 名过滤合并列表）。
  List<Song> albumSongs(Album album) => songs
      .where((s) =>
          _blank(s.artist, 'Unknown') == album.artist &&
          _blank(s.albumName, 'Unknown Album') == album.album)
      .toList();

  /// 歌手对应的歌曲列表。
  List<Song> artistSongs(Artist artist) => songs
      .where((s) => _blank(s.artist, 'Unknown') == artist.name)
      .toList();

  /// 依据匹配的 sourceKey 解析播放源（服务器→全局代理源；直连→管理器源）。
  MusicSource? sourceFor(String sourceKey) {
    if (sourceKey == 'server') return source;
    return _directManager?.sourceByKey(sourceKey);
  }

  List<Song> _mergeSongs(List<Song> server, List<Song> direct) {
    final seen = <String>{};
    final out = <Song>[];
    void add(Song s) {
      final key = '${s.title}\x00${s.artist}\x00${s.albumName}';
      if (!seen.add(key)) return;
      out.add(s);
    }

    for (final s in server) {
      add(s);
    }
    for (final s in direct) {
      add(s);
    }
    return out;
  }

  void _recomputeGroups() {
    albums = Album.fromSongs(songs);
    artists = Artist.fromSongs(songs);
  }

  static String _blank(String? v, String fallback) =>
      (v == null || v.isEmpty) ? fallback : v;
}