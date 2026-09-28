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

/// 全局图库数据源：合并所有直连源的歌曲，并在客户端按 专辑/歌手 分组聚合，
/// 供「歌曲/专辑/歌手」栏目共用。
class LibraryProvider extends ChangeNotifier {
  static const _cacheFileName = 'library_cache.json';

  LibraryProvider();

  DirectSourceManager? _directManager;

  /// 合并后的全部歌曲（所有直连源）。
  List<Song> songs = [];
  List<Album> albums = [];
  List<Artist> artists = [];
  bool loading = false;
  String? error;

  /// 关联直连源管理器，使「歌曲/专辑/歌手」能合并直连扫描结果。
  /// 同时监听其元数据版本号：扫描/后台补读/编辑元数据后就地重建列表。
  void attachDirectManager(DirectSourceManager m) {
    if (identical(_directManager, m)) return;
    _directManager?.removeListener(_onDirectChanged);
    _directManager = m;
    _seenMetaVersion = m.metaVersion;
    m.addListener(_onDirectChanged);
    notifyListeners();
  }

  int _seenMetaVersion = 0;
  bool _loadedOnce = false;
  String? _lastQuery;

  void _onDirectChanged() {
    final m = _directManager;
    if (m == null || m.metaVersion == _seenMetaVersion) return;
    _seenMetaVersion = m.metaVersion;
    // 首次 loadSongs 前不重建：避免与启动加载竞争。
    if (!_loadedOnce) return;
    refreshDirect();
  }

  /// 就地把列表换成索引最新数据（元数据补读/编辑/扫描后调用），并刷新分组。
  void refreshDirect() {
    final m = _directManager;
    if (m == null) return;
    songs = m.allSongs(query: _lastQuery);
    _recomputeGroups();
    notifyListeners();
  }

  /// 读取全部直连源的歌曲（同步，来自本地索引）。
  List<Song> get directSongs =>
      _directManager?.allSongs() ?? const <Song>[];

  /// 启动加载：先恢复上次曲库快照即时展示，再后台刷新。
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
  /// 旧版本快照可能含已废弃的服务端歌曲，恢复时直接过滤。
  Future<void> restoreCache() async {
    try {
      final file = await _cacheFile();
      if (file == null || !file.existsSync()) return;
      final data = jsonDecode(file.readAsStringSync());
      if (data is! List) return;
      songs = data
          .whereType<Map<String, dynamic>>()
          .map(Song.fromJson)
          .where((s) => s.sourceKey != 'server')
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
    songs = _directManager?.allSongs(query: query) ?? const <Song>[];
    _lastQuery = query;
    _recomputeGroups();
    _loadedOnce = true;
    unawaited(_saveCache());
    loading = false;
    notifyListeners();
  }

  /// 专辑/歌手从合并后的歌曲列表客户端聚合（统一先刷新歌曲，再分组）。
  Future<void> loadAlbums({String? query}) async {
    await loadSongs(query: query);
  }

  Future<void> loadArtists({String? query}) async {
    await loadSongs(query: query);
  }

  /// 客户端专辑查询对应歌曲（按 专辑歌手? + 专辑名 过滤合并列表，与分组规则一致）。
  List<Song> albumSongs(Album album) => songs
      .where((s) =>
          _blank(s.albumArtist, _blank(s.artist, 'Unknown')) == album.artist &&
          _blank(s.albumName, 'Unknown Album') == album.album)
      .toList();

  /// 歌手对应的歌曲列表。
  ///
  /// identity 模式（歌手处理.txt）：带 identityKey 的歌手走 artist_song_map
  /// 映射（别名/角色/归一化并组自动合并）；否则退回原字符串匹配。
  List<Song> artistSongs(Artist artist) {
    if (artist.identityKey != null) {
      return _directManager?.index.identitySongs(artist.identityKey!) ??
          const <Song>[];
    }
    return songs
        .where((s) => _blank(s.artist, 'Unknown') == artist.name)
        .toList();
  }

  void _recomputeGroups() {
    albums = Album.fromSongs(songs);
    if (_identityEnabled) {
      artists = _identityGroupsFromDb(_lastQuery);
    } else {
      artists = Artist.fromSongs(songs);
    }
  }

  /// 歌手分组是否走身份聚合（列=DB 身份行，源=歌曲映射；保真/合并别名）。
  bool get _identityEnabled =>
      _directManager?.settings.artistIdentity ?? false;

  List<Artist> _identityGroupsFromDb(String? query) {
    final m = _directManager;
    if (m == null) return const [];
    final out = <Artist>[
      ...m.index.identityArtistGroups(query: query),
    ];
    // 无映射残留兜底（通常为空）：保证身份聚合开启时歌手页仍完整。
    out.addAll(m.index.identityFallbackGroups());
    return out;
  }

  /// 歌手身份解析结果变化后（无需重扫歌曲）刷新歌手分组。
  void refreshArtists() {
    if (!_identityEnabled) return;
    artists = _identityGroupsFromDb(_lastQuery);
    notifyListeners();
  }

  /// 依据匹配的 sourceKey 解析播放源。
  MusicSource? sourceFor(String sourceKey) =>
      _directManager?.sourceByKey(sourceKey);

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

  static String _blank(String? v, String fallback) =>
      (v == null || v.isEmpty) ? fallback : v;
}
