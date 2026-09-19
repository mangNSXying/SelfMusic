import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/sources/music_source.dart';
import '../data/sources/scan_worker.dart';
import '../data/sources/webdav_direct_source.dart';
import '../data/sources/local_direct_source.dart';
import '../data/sources/server_proxy_source.dart';
import '../data/local/local_index.dart';
import '../data/local/app_settings.dart';
import '../data/local/cache_manager.dart';
import '../data/local/song_weight_store.dart';
import '../data/local/playlist_store.dart';
import '../models/song.dart';
import '../services/api_client.dart';

/// 直连模式源管理（阶段 3 / 阶段 4 接收器）。
///
/// - 持有 [LocalIndex]（直连模式的本地事实源）。
/// - 管理已配置的直连源（WebDAV 完整，SMB 为阶段 4 骨架）。
/// - 每个源可独立选择 [SourceMode.direct]（App 内扫描/播放）或
///   [SourceMode.proxy]（该源走后端 /api 拉整体库，需先配置「服务端」地址）。
/// - 所有源默认激活，歌曲经 [allSongs] 合并进全局图库。
/// - 提供 添加/删除/扫描/检索/收藏/缓存/模式切换 等操作，并驱动 UI 刷新。
class DirectSourceManager extends ChangeNotifier {
  final LocalIndex index = LocalIndex();
  final List<MusicSource> _sources = [];
  bool _ready = false;
  bool scanning = false;
  String? error;

  late AppSettings settings;
  late CacheManager cache;
  late SongWeightStore weight;
  late PlaylistStore playlists;

  ApiClient? _api;

  int _favoriteVersion = 0;

  /// 收藏列表版本号：全局收藏面板监听该值刷新（避免全量 rebuild）。
  int get favoriteVersion => _favoriteVersion;

  // ---------- 扫描：进度 / 取消 / 自动触发 ----------

  final Map<String, ScanToken> _scanTokens = {};
  final StreamController<ScanProgress> _scanProgress =
      StreamController<ScanProgress>.broadcast();
  ScanProgress? _lastProgress;
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);
  bool _scanningNow = false;

  /// 扫描进度事件（内存广播；UI 监听即可，无需轮询）。
  Stream<ScanProgress> get scanProgressStream => _scanProgress.stream;

  /// 最近一次进度（UI 直接读取，避免全量 rebuild 丢帧）。
  ScanProgress? get currentScanProgress => _lastProgress;

  /// 是否有源正在扫描。
  bool get scanningNow => _scanningNow;

  /// 指定源是否正在扫描。
  bool isScanning(String key) => _scanTokens.containsKey(key);

  /// 取消指定源的扫描（worker 收到后尽快停止并返回已完成的增量）。
  void cancelScan(String key) => _scanTokens[key]?.cancel();

  // ---------- 自动扫描 ----------

  Timer? _autoScanTimer;
  final List<DirectoryWatcher> _watchers = [];

  /// 按设置重启周期自动扫描定时器 + 本地目录监视（检测到变化即增量扫描）。
  void restartAutoScan() {
    _autoScanTimer?.cancel();
    _autoScanTimer = null;
    final minutes = settings.scanAutoIntervalMin;
    if (minutes > 0) {
      _autoScanTimer = Timer.periodic(Duration(minutes: minutes), (_) {
        unawaited(autoScanAll());
      });
    }
    // 重建本地目录监视（路径/模式变更后生效）。
    for (final w in _watchers) {
      w.dispose();
    }
    _watchers.clear();
    for (final s in _sources) {
      if (s is LocalDirectSource) _registerWatcher(s);
    }
  }

  void _registerWatcher(LocalDirectSource src) {
    if (_watchers.any((w) => w.key == src.key)) return;
    try {
      final dir = Directory(src.rootPath);
      if (!dir.existsSync()) return;
      late final DirectoryWatcher entry;
      final sub = dir.watch(recursive: true).listen((_) {
        // 去抖 2s：批量改动只触发一次。
        entry.debounce?.cancel();
        entry.debounce = Timer(const Duration(seconds: 2), () {
          unawaited(scanSource(src.key));
        });
      }, onError: (_) {});
      entry = DirectoryWatcher(src.key, src.rootPath, sub);
      _watchers.add(entry);
    } catch (_) {
      // 目录不可监听（如 Android FUSE 存储）时静默降级给周期定时器。
    }
  }

  /// 对所有直连源依次增量扫描（自动触发用；并发保护在 scanSource 内）。
  Future<void> autoScanAll() async {
    for (final s in _sources) {
      if (!s.supportsDirect || isProxy(s.key)) continue;
      try {
        await scanSource(s.key);
      } catch (_) {
        // 自动扫描失败静默，不影响其余源。
      }
    }
  }

  /// 关联后端接入点，供按源代理源使用其中的 dio/baseUrl。
  void attachApi(ApiClient api) => _api = api;

  /// 拉取服务端缓存建议值并填入 [settings]（settings.md §3.3 follow_server 来源）。
  Future<bool> refreshServerConfig() async {
    final api = _api;
    if (api == null) return false;
    final cfg = await api.fetchServerConfig();
    if (cfg == null) return false;
    final mb = (cfg['cache_max_bytes'] as num?)?.toInt();
    final limit = (cfg['cache_song_limit'] as num?)?.toInt();
    if (mb != null && limit != null) {
      settings.serverCacheMaxBytes = mb;
      settings.serverCacheSongLimit = limit;
      notifyListeners();
      return true;
    }
    return false;
  }

  bool get ready => _ready;
  List<MusicSource> get sources => List.unmodifiable(_sources);

  /// 服务器模式始终存在。
  String get serverKey => 'server';

  /// 从 [src] 读出该源的模式（默认直连）。
  static SourceMode modeOf(MusicSource src) =>
      src is ServerProxySource ? SourceMode.proxy : SourceMode.direct;

  /// 该源当前是否为「服务端代理」模式。
  bool isProxy(String key) =>
      _sources.where((x) => x.key == key).firstOrNull is ServerProxySource;

  Future<void> init() async {
    await index.open();
    settings = AppSettings(index);
    cache = CacheManager(index, settings);
    weight = SongWeightStore(index);
    playlists = PlaylistStore(index);
    final rows = index.listSources();
    for (final r in rows) {
      if (!r.enabled) continue;
      try {
        if (r.kind == 'webdav' || r.kind == 'local') {
          final cfg = jsonDecode(r.config) as Map<String, dynamic>;
          final mode = _modeFromConfig(cfg);
          final name = cfg['name'] as String? ?? r.name;
          _sources.add(_buildFor(
              kind: r.kind, key: r.key, name: name, cfg: cfg, mode: mode));
        }
        // SMB 自动恢复在阶段 4 补充。
      } catch (_) {
        // 忽略损坏的源配置
      }
    }
    _ready = true;
    restartAutoScan();
    notifyListeners();
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
    for (final w in _watchers) {
      w.dispose();
    }
    _watchers.clear();
    for (final t in _scanTokens.values) {
      t.cancel();
    }
    _scanTokens.clear();
    _scanProgress.close();
    super.dispose();
  }

  SourceMode _modeFromConfig(Map<String, dynamic> cfg) =>
      (cfg['mode'] as String?) == 'proxy' ? SourceMode.proxy : SourceMode.direct;

  String _webdavKey(String name) => 'webdav:$name';

  String _localKey(String name) => 'local:$name';

  /// 按源类型构建直连源实例（webdav / local）。
  MusicSource _buildDirect({
    required String kind,
    required String name,
    required Map<String, dynamic> cfg,
  }) {
    if (kind == 'local') {
      return LocalDirectSource(
        name: name,
        rootPath: cfg['path'] as String? ?? '',
        index: index,
      );
    }
    return WebdavDirectSource(
      name: name,
      baseUrl: cfg['baseUrl'] as String? ?? '',
      username: cfg['username'] as String? ?? '',
      password: cfg['password'] as String? ?? '',
      index: index,
    );
  }

  /// 按类型 + 数据通道构建源实例（直连或服务端代理）。
  MusicSource _buildFor({
    required String kind,
    required String key,
    required String name,
    required Map<String, dynamic> cfg,
    required SourceMode mode,
  }) =>
      mode == SourceMode.proxy
          ? _buildProxy(name: name, key: key)
          : _buildDirect(kind: kind, name: name, cfg: cfg);

  /// 读取某源的可编辑配置（含 kind/name/path/baseUrl/username/password/mode）。
  /// 代理模式下内存对象只是 [ServerProxySource]，原始凭据需从持久化配置还原。
  Map<String, dynamic> editableConfig(String key) {
    final row = index.getSource(key);
    if (row == null) return const {};
    final cfg = <String, dynamic>{'kind': row.kind, 'key': row.key};
    try {
      cfg.addAll(jsonDecode(row.config) as Map<String, dynamic>);
    } catch (_) {}
    return cfg;
  }

  ServerProxySource _buildProxy({required String name, required String key}) {
    final base = _api?.baseUrl ?? '';
    return ServerProxySource(
      dio: _api?.dio ?? Dio(),
      baseUrl: base,
      key: key,
      name: name,
    );
  }

  void setActive(String key) {
    notifyListeners();
  }

  MusicSource? sourceByKey(String key) {
    if (key == serverKey) return null; // 服务器无直连源对象
    return _sources.where((x) => x.key == key).firstOrNull;
  }

  Future<void> addWebdav({
    required String name,
    required String baseUrl,
    String username = '',
    String password = '',
    SourceMode mode = SourceMode.direct,
  }) async {
    final key = _webdavKey(name);
    final src = mode == SourceMode.proxy
        ? _buildProxy(name: name, key: key)
        : WebdavDirectSource(
            name: name,
            baseUrl: baseUrl,
            username: username,
            password: password,
            index: index,
          );
    _sources.add(src);
    final cfg = <String, dynamic>{
      'name': name,
      'baseUrl': baseUrl,
      'username': username,
      'password': password,
      'mode': mode.name,
    };
    index.upsertSource(key, 'webdav', name, jsonEncode(cfg));
    restartAutoScan();
    notifyListeners();
  }

  /// 新增本地文件夹源。
  Future<void> addLocal({
    required String name,
    required String path,
    SourceMode mode = SourceMode.direct,
  }) async {
    final key = _localKey(name);
    final cfg = <String, dynamic>{
      'name': name,
      'path': path,
      'mode': mode.name,
    };
    _sources.add(_buildFor(
        kind: 'local', key: key, name: name, cfg: cfg, mode: mode));
    index.upsertSource(key, 'local', name, jsonEncode(cfg));
    restartAutoScan();
    notifyListeners();
  }

  /// 编辑源：可改 名称（含 key 迁移）/ 地址或目录 / 账号 / 密码 / 数据通道。
  ///
  /// 改名会派生新的 key，[LocalIndex.renameSource] 同步迁移已索引歌曲、
  /// 收藏与歌单条目；与已有源重名时抛 [StateError]。
  Future<void> updateSource(
    String key, {
    String? name,
    String? path,
    String? baseUrl,
    String? username,
    String? password,
    SourceMode? mode,
  }) async {
    final row = index.getSource(key);
    if (row == null) return;
    final cfg = <String, dynamic>{};
    try {
      cfg.addAll(jsonDecode(row.config) as Map<String, dynamic>);
    } catch (_) {}
    final newName = (name ?? cfg['name'] ?? row.name).toString().trim();
    if (newName.isEmpty) throw StateError('源名称不能为空');
    cfg['name'] = newName;
    if (path != null) cfg['path'] = path;
    if (baseUrl != null) cfg['baseUrl'] = baseUrl;
    if (username != null) cfg['username'] = username;
    if (password != null) cfg['password'] = password;
    final newMode = mode ?? _modeFromConfig(cfg);
    cfg['mode'] = newMode.name;

    final newKey = '${row.kind}:$newName';
    if (newKey != key && _sources.any((s) => s.key == newKey)) {
      throw StateError('已存在同名播放源');
    }

    final rebuilt = <MusicSource>[];
    for (final s in _sources) {
      if (s.key == key) {
        rebuilt.add(_buildFor(
            kind: row.kind, key: newKey, name: newName, cfg: cfg, mode: newMode));
      } else {
        rebuilt.add(s);
      }
    }
    _sources
      ..clear()
      ..addAll(rebuilt);
    if (newKey != key) {
      index.renameSource(key, newKey);
    }
    index.upsertSource(newKey, row.kind, newName, jsonEncode(cfg));
    restartAutoScan();
    notifyListeners();
  }

  /// 切换某源的数据通道模式（直连 ↔ 服务端代理）并持久化。
  Future<void> setMode(String key, SourceMode mode) async {
    final row = index.getSource(key);
    if (row == null) return;
    final cfg = <String, dynamic>{};
    try {
      final existing = jsonDecode(row.config) as Map<String, dynamic>;
      cfg.addAll(existing);
    } catch (_) {}
    cfg['mode'] = mode.name;

    final name = cfg['name'] as String? ?? row.name;
    final List<MusicSource> rebuilt = [];
    for (final s in _sources) {
      if (s.key == key) {
        rebuilt.add(_buildFor(
            kind: row.kind, key: key, name: name, cfg: cfg, mode: mode));
      } else {
        rebuilt.add(s);
      }
    }
    _sources
      ..clear()
      ..addAll(rebuilt);
    index.upsertSource(key, row.kind, name, jsonEncode(cfg));
    restartAutoScan();
    notifyListeners();
  }

  Future<void> removeSource(String key) async {
    _scanTokens[key]?.cancel();
    final gone = _watchers.where((w) => w.key == key).toList();
    for (final w in gone) {
      w.dispose();
    }
    _watchers.removeWhere((w) => gone.contains(w));
    _sources.removeWhere((s) => s.key == key);
    index.deleteSource(key);
    notifyListeners();
  }

  Future<ScanSummary>? _inFlightScan;

  /// 扫描指定源（增量：mtime/size/etag 未变快速跳过，零音频下载）。
  /// 并发保护：同一时刻仅允许一次扫描在飞，重复触发复用同一 Future，
  /// 避免「自动扫描」与手动扫描叠加造成重复探测。
  Future<ScanSummary> scanSource(String key) {
    final existing = _inFlightScan;
    if (existing != null) return existing;
    final token = ScanToken();
    _scanTokens[key] = token;
    _scanningNow = true;
    final f = _doScan(key, token);
    _inFlightScan = f;
    return f.whenComplete(() {
      _scanTokens.remove(key);
      _inFlightScan = null;
      _scanningNow = false;
      _lastProgress = null;
      notifyListeners();
    });
  }

  Future<ScanSummary> _doScan(String key, ScanToken token) async {
    final src = sourceByKey(key);
    if (src == null || !src.supportsDirect) {
      throw StateError('$key 不支持直连扫描');
    }
    // 「仅 Wi-Fi 扫描」（settings.md §3.4）：移动端生效，桌面忽略。
    if (settings.scanWifiOnly && Platform.isAndroid && !await _hasWifi()) {
      throw StateError('已开启「仅 Wi-Fi 扫描」，当前不在 Wi-Fi 下');
    }
    scanning = true;
    error = null;
    notifyListeners();
    try {
      index.updateSourceScan(key, 'scanning');
      final options = ScanOptions(
        minSizeBytes: settings.scanIgnoreMinSizeBytes,
        minDurationSec: settings.scanIgnoreMinDurationSec,
        headBytes: settings.scanHeadBytes,
        fullMeta: settings.scanModeFull,
        fast: settings.scanModeFast,
        collectCover: settings.scanEmbedCover && settings.scanModeFull,
      );
      final summary = await src.scan(
        options: options,
        token: token,
        onProgress: (p) {
          // 节流：距上次通知 >250ms 或进度比例/阶段发生变化时才通知 UI。
          final now = DateTime.now();
          final prevValue = _lastProgress?.value;
          final pv = p.value;
          final changed =
              p.listing != (_lastProgress?.listing ?? false) || pv != prevValue;
          if (now.difference(_lastProgressNotify).inMilliseconds >= 250 ||
              changed) {
            _lastProgressNotify = now;
            _lastProgress = p;
            _scanProgress.add(p);
            notifyListeners();
          }
        },
      );
      if (token.cancelled) {
        index.updateSourceScan(key, 'cancelled');
      } else {
        index.updateSourceScan(key, 'done');
      }
      return ScanSummary(
        added: summary.added,
        updated: summary.updated,
        unchanged: summary.unchanged,
        total: summary.total,
        cancelled: token.cancelled,
      );
    } catch (e) {
      error = e.toString();
      index.updateSourceScan(key, 'failed');
      rethrow;
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// 零依赖 Wi-Fi 探测（best-effort）：存在 `wlan` 网卡即认为在 Wi-Fi。
  static Future<bool> _hasWifi() async {
    try {
      final ifaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4);
      return ifaces.any((i) => i.name.toLowerCase().contains('wlan') ||
          i.name.toLowerCase().contains('wifi'));
    } catch (_) {
      return true; // 探测失败放行，避免误锁扫描。
    }
  }

  /// 检索某源索引的歌。代理源走后端整体库（异步，分页取完）。
  Future<List<Song>> fetchSongsFor(String? sourceKey, {String? query}) async {
    final key = sourceKey ?? serverKey;
    if (key == serverKey) return const [];
    final s = _sources.where((x) => x.key == key).firstOrNull;
    if (s is ServerProxySource) {
      return s.fetchAllSongs(query: query);
    }
    return index.searchSongs(sourceKey: key, query: query);
  }

  /// 同步检索（本地索引）。代理源无本地索引，返回空（由 [fetchSongsFor] 异步取后端）。
  List<Song> songsOf(String? sourceKey, {String? query}) {
    final key = sourceKey ?? serverKey;
    if (key == serverKey) return const [];
    final s = _sources.where((x) => x.key == key).firstOrNull;
    if (s is ServerProxySource) return const [];
    return index.searchSongs(sourceKey: key, query: query);
  }

  int countOf(String sourceKey) {
    final s = _sources.where((x) => x.key == sourceKey).firstOrNull;
    if (s is ServerProxySource) return 0;
    return index.countSongs(sourceKey);
  }

  /// 所有直连源本地索引歌曲的总和（供全局图库合并）。
  List<Song> allSongs({String? query}) {
    final out = <Song>[];
    for (final s in _sources) {
      if (s is ServerProxySource) continue;
      out.addAll(index.searchSongs(sourceKey: s.key, query: query));
    }
    return out;
  }

  /// 所有直连源歌曲总数。
  int get allSongsCount {
    var n = 0;
    for (final s in _sources) {
      if (s is ServerProxySource) continue;
      n += index.countSongs(s.key);
    }
    return n;
  }

  /// 收藏统一收口到 play_meta（直连 + 服务器一致）；收藏直连歌自动后台缓存。
  void setFavorite(Song s, bool fav) {
    if (fav) {
      weight.setLiked(s);
    } else {
      weight.setUnliked(s);
    }
    _favoriteVersion++;
    notifyListeners();
    // 自动缓存喜欢的直连歌（LRU 淘汰见 CacheManager，stage2.md §6）。
    if (fav && s.isDirect) {
      unawaited(cache.autoCacheIfNeeded(sourceByKey(s.sourceKey), s,
          becameFavorite: true));
    }
  }

  /// 全部已收藏歌曲（直连 + 服务器，统一来自 play_meta 快照）。
  List<Song> favoriteSongs() => index.likedSongs();

  /// 是否处于「不喜欢」态（权重锁定最低）。
  bool isDisliked(Song s) => weight.isDisliked(s);

  /// 手动「不喜欢」开关：开 → 权重降到最低并锁定；关 → 解锁回到 1.0。
  void setDisliked(Song s, bool disliked) {
    weight.setDisliked(s, disliked);
    _favoriteVersion++;
    notifyListeners();
  }

  Future<void> cacheSong(MusicSource src, Song s) async {
    await src.cacheSong(s);
    cache.currentCacheKey = cache.cacheKeyOf(src, s);
    cache.evictIfNeeded();
    notifyListeners();
  }

  String? cachedPathOf(MusicSource src, Song s) {
    final k = cache.cacheKeyOf(src, s);
    return k == null ? null : index.cachedPath(k);
  }

  /// 播放某直连歌时登记其缓存访问时间与当前 key（LRU 保留当前播放）。
  void onTrackPlaying(MusicSource src, Song s) {
    cache.currentCacheKey = cache.cacheKeyOf(src, s);
    cache.touch(src, s);
  }
}

/// 本地目录监视句柄（变化去抖后触发增量扫描）。
class DirectoryWatcher {
  final String key;
  final String path;
  final StreamSubscription<FileSystemEvent> sub;
  Timer? debounce;
  DirectoryWatcher(this.key, this.path, this.sub);

  void dispose() {
    debounce?.cancel();
    sub.cancel();
  }
}
