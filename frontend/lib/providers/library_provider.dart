import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../data/sources/music_source.dart';
import '../data/local/local_index.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../services/artist_resolver.dart';
import '../utils/off_thread.dart';
import '../utils/perf_log.dart';
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
    _seenSettingsVersion = m.settingsVersion;
    _seenArtistsVersion = m.artistsVersion;
    m.addListener(_onDirectChanged);
    notifyListeners();
  }

  /// 关联歌手身份解析服务：解析/成员展开/合流落库后逐批通知，歌手列表就地重算。
  /// 挂在 provider 层（而不是某个页面）——不在歌手页时也要保持数据新鲜，
  /// 否则下次进页面前列表还挂着解析前的旧曲目数/专辑数。
  void attachArtistResolver(ArtistResolver r) {
    if (identical(_artistResolver, r)) return;
    _artistResolver?.removeListener(_onArtistResolverChanged);
    _artistResolver = r;
    r.addListener(_onArtistResolverChanged);
  }

  ArtistResolver? _artistResolver;

  int _seenMetaVersion = 0;
  int _seenSettingsVersion = 0;
  int _seenArtistsVersion = 0;
  bool _loadedOnce = false;
  String? _lastQuery;

  /// 全量快照的世代号：后台读完成时若已被更新的加载接管，丢弃旧结果。
  int _snapshotToken = 0;
  bool _refreshInflight = false;
  bool _refreshDirty = false;

  /// 歌手列表的世代号（全量加载/刷新也会自增，作废在途的只刷歌手结果）。
  int _artistsToken = 0;
  bool _artistsRefreshInflight = false;
  bool _artistsRefreshDirty = false;

  void _onArtistResolverChanged() {
    // 首批加载前不重算：startup/loadSongs 会读到最新数据。
    if (!_loadedOnce) return;
    refreshArtists();
  }

  void _onDirectChanged() {
    final m = _directManager;
    if (m == null) return;
    final metaChanged = m.metaVersion != _seenMetaVersion;
    final settingsChanged = m.settingsVersion != _seenSettingsVersion;
    final artistsChanged = m.artistsVersion != _seenArtistsVersion;
    if (!metaChanged && !settingsChanged && !artistsChanged) return;
    _seenMetaVersion = m.metaVersion;
    _seenSettingsVersion = m.settingsVersion;
    _seenArtistsVersion = m.artistsVersion;
    // 首次 loadSongs 前不重建：避免与启动加载竞争。
    if (!_loadedOnce) return;
    // 只有身份映射变化（歌曲没变）：只重算歌手列表，不动歌曲/专辑。
    if (!metaChanged && !settingsChanged && artistsChanged) {
      refreshArtists();
      return;
    }
    refreshDirect();
  }

  /// 就地把列表换成索引最新数据（元数据补读/编辑/扫描后调用），并刷新分组。
  /// 查询/建模/分组都在后台 isolate 完成；token 丢弃乱序完成的旧结果，
  /// in-flight 期间的重复触发只登记 dirty，完成后补一轮（扫描期通知很密）。
  void refreshDirect() {
    if (_refreshInflight) {
      _refreshDirty = true;
      return;
    }
    _refreshInflight = true;
    final token = ++_snapshotToken;
    // 整表刷新也会重算歌手，作废在途的「只刷歌手」结果。
    _artistsToken++;
    unawaited(() async {
      try {
        final m = _directManager;
        if (m == null) return;
        // 诊断埋点（E）：后台快照 vs 主线程通知拆分，定位同步后整表重建掉帧。
        final swBg = Stopwatch()..start();
        final snap = await m.librarySnapshotInBackground(query: _lastQuery);
        final bgMs = swBg.elapsedMilliseconds;
        if (token != _snapshotToken) return; // 更新的全量刷新已接管
        songs = snap.songs;
        albums = snap.albums;
        artists = snap.artists;
        notifyListeners();
        perfLog('library.refreshDirect',
            'bg=${bgMs}ms n=${snap.songs.length}');
      } finally {
        _refreshInflight = false;
        if (_refreshDirty) {
          _refreshDirty = false;
          refreshDirect();
        }
      }
    }());
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
  /// 读文件与 JSON 解析都在后台 isolate，UI isolate 不做同步 IO/解码。
  Future<void> restoreCache() async {
    try {
      final file = await _cacheFile();
      if (file == null) return;
      final path = file.path;
      final loaded = await runOffThread<List<Song>?>(() {
        final f = File(path);
        if (!f.existsSync()) return null;
        final data = jsonDecode(f.readAsStringSync());
        if (data is! List) return null;
        return [
          for (final e in data.whereType<Map<String, dynamic>>())
            if ((e['sourceKey'] as String?) != 'server') Song.fromJson(e),
        ];
      });
      if (loaded == null) return;
      songs = loaded;
      // 先出歌曲列表，分组（后台）补上——启动首屏不为分组查询让路。
      notifyListeners();
      await _recomputeGroups();
      notifyListeners();
    } catch (e) {
      debugPrint('library cache restore failed: $e');
    }
  }

  Future<void> loadSongs({String? query}) async {
    loading = true;
    error = null;
    notifyListeners();
    final token = ++_snapshotToken;
    // 整表加载也会重算歌手，作废在途的「只刷歌手」结果。
    _artistsToken++;
    final m = _directManager;
    if (m == null) {
      songs = const <Song>[];
      _lastQuery = query;
      await _recomputeGroups();
    } else {
      final snap = await m.librarySnapshotInBackground(query: query);
      if (token == _snapshotToken) {
        songs = snap.songs;
        albums = snap.albums;
        artists = snap.artists;
      }
      _lastQuery = query;
    }
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
  /// 带 identityKey 的歌手走 artist_song_map 映射（别名/角色/归一化并组自动
  /// 合并）；否则退回原字符串匹配。
  List<Song> artistSongs(Artist artist) {
    if (artist.identityKey != null) {
      return _directManager?.index.identitySongs(artist.identityKey!,
              minDurationSec: _directManager!.settings.scanIgnoreMinDurationSec,
              minSizeBytes: _directManager!.settings.scanIgnoreMinSizeBytes) ??
          const <Song>[];
    }
    return songs
        .where((s) => _blank(s.artist, 'Unknown') == artist.name)
        .toList();
  }

  /// 人物身份的详情（组合/角色/成员），非人物身份返回 null。
  ArtistDetail? artistDetail(Artist artist) {
    final m = _directManager;
    final key = artist.identityKey;
    if (m == null || key == null) return null;
    return m.index.artistDetail(key,
        minDurationSec: m.settings.scanIgnoreMinDurationSec,
        minSizeBytes: m.settings.scanIgnoreMinSizeBytes);
  }

  /// 分组重算（无直连管理器时的纯内存分组；有管理器走后台 identity 分组）。
  Future<void> _recomputeGroups() async {
    final m = _directManager;
    final current = songs;
    if (m == null) {
      final snap = await runOffThread(() => (
            albums: Album.fromSongs(current),
            artists: Artist.fromSongs(current),
          ));
      albums = snap.albums;
      artists = snap.artists;
      return;
    }
    albums = await runOffThread(() => Album.fromSongs(current));
    artists = await m.artistGroupsInBackground(query: _lastQuery);
  }

  /// 歌手身份解析结果变化后（无需重扫歌曲）刷新歌手分组。
  /// 后台 isolate 重算；in-flight 期间再次触发只登记 dirty，完成后补一轮，
  /// 避免解析器逐批通知时排队堆积一串查询。
  void refreshArtists() {
    if (_artistsRefreshInflight) {
      _artistsRefreshDirty = true;
      return;
    }
    _artistsRefreshInflight = true;
    final token = ++_artistsToken;
    unawaited(() async {
      try {
        final m = _directManager;
        final current = songs;
        final list = m == null
            ? await runOffThread(() => Artist.fromSongs(current))
            : await m.artistGroupsInBackground(query: _lastQuery);
        if (token == _artistsToken) {
          artists = list;
          notifyListeners();
        }
      } finally {
        _artistsRefreshInflight = false;
        if (_artistsRefreshDirty) {
          _artistsRefreshDirty = false;
          refreshArtists();
        }
      }
    }());
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
    final path = file.path;
    final snapshot = songs;
    try {
      // 编码（全量 toJson）与写盘+fsync 都放后台 isolate：原来在 UI 线程
      // jsonEncode 每一首再同步写，是启动卡顿的主要来源之一。
      await runOffThread<void>(() {
        final f = File(path);
        f.parent.createSync(recursive: true);
        f.writeAsStringSync(
            jsonEncode([for (final s in snapshot) s.toJson()]),
            flush: true);
      });
    } catch (e) {
      debugPrint('library cache save failed: $e');
    }
  }

  static String _blank(String? v, String fallback) =>
      (v == null || v.isEmpty) ? fallback : v;
}
