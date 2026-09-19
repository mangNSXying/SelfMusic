import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import 'direct_source_manager.dart';

/// 全局图库数据源：合并后端（服务器模式）与所有直连源的歌曲，
/// 并在客户端按 专辑/歌手 分组聚合，供「歌曲/专辑/歌手」栏目共用。
class LibraryProvider extends ChangeNotifier {
  static const _cacheFileName = 'library_cache.json';

  /// 全局服务端源（key=`server`）。
  final MusicSource source;
  LibraryProvider(this.source);

  DirectSourceManager? _directManager;

  /// 是否已配置服务端（baseUrl 非空）。未配置时跳过全部服务端请求，直连源照常可用。
  bool serverConfigured = true;

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

  /// 启动加载：先恢复上次曲库快照即时展示，再后台刷新（新建播放源/重扫后自动合并）。
  Future<void> startup({String? query}) async {
    loading = true;
    error = null;
    notifyListeners();
    await restoreCache();
    loading = false;
    notifyListeners();
    await loadSongs(query: query);
  }

  /// 从磁盘恢复上次曲库快照（曲库缓存，上次 launch 成功加载后落盘）。
  Future<void> restoreCache() async {
    try {
      final file = await _cacheFile();
      if (file == null || !file.existsSync()) return;
      final data = jsonDecode(file.readAsStringSync());
      if (data is! List) return;
      songs = data
          .whereType<Map<String, dynamic>>()
          .map(Song.fromJson)
          .toList();
      _recomputeGroups();
      notifyListeners();
    } catch (e) {
      debugPrint('library cache restore failed: $e');
    }
  }

  Future<void> loadSongs({String? query}) async {
    loading = true;
    error = null;
    notifyListeners();
    // 未配置服务端时跳过拉取（避免每次启动都抛 Dio 「No host」错误）；
    // 已配置但失败则提示且不阻断直连源歌曲展示。
    List<Song> server = const [];
    if (serverConfigured) {
      try {
        server = await source.fetchAllSongs(query: query);
      } catch (e) {
        error = '服务端不可用：$e';
      }
    }
    final direct = _directManager?.allSongs(query: query) ?? const <Song>[];
    songs = _mergeSongs(server, direct);
    _recomputeGroups();
    unawaited(_saveCache());
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

  Future<File?> _cacheFile() async {
    try {
      final support = await getApplicationSupportDirectory();
      return File(p.join(support.path, 'selfmusic', _cacheFileName));
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveCache() async {
    final file = await _cacheFile();
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
          jsonEncode(songs.map((s) => s.toJson()).toList()),
          flush: true);
    } catch (e) {
      debugPrint('library cache save failed: $e');
    }
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