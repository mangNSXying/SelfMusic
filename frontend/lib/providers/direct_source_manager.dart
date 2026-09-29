import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/sources/music_source.dart';
import '../data/sources/meta_enrich.dart';
import '../data/sources/scan_worker.dart';
import '../data/sources/webdav_direct_source.dart';
import '../data/sources/local_direct_source.dart';
import '../data/local/local_index.dart';
import '../data/local/sync_event_types.dart';
import '../data/local/app_settings.dart';
import '../data/local/cache_manager.dart';
import '../data/local/song_weight_store.dart';
import '../data/local/playlist_store.dart';
import '../models/song.dart';
import '../services/api_client.dart';
import '../services/artist_resolver.dart';
import '../services/secret_store.dart';

/// 直连源管理（阶段 3 / 阶段 4 接收器）。
///
/// - 持有 [LocalIndex]（本地事实源）。
/// - 管理已配置的直连源（WebDAV 完整，SMB 为阶段 4 骨架）。
/// - 所有源默认激活，歌曲经 [allSongs] 合并进全局图库。
/// - 提供 添加/删除/扫描/检索/收藏/缓存 等操作，并驱动 UI 刷新。
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

  /// 歌手身份解析服务（歌手处理.txt）：扫描/补读后经 [_reconcileArtists] 唤醒。
  ArtistResolver? artistResolver;
  void attachArtistResolver(ArtistResolver r) => artistResolver = r;

  /// 扫描/元数据回填变更后：校准歌手身份映射并唤醒后台解析（幂等、静默）。
  void _reconcileArtists() {
    unawaited(index.reconcileArtists().then((_) => artistResolver?.wake()));
  }

  ApiClient? _api;

  /// 敏感凭据统一存储（WebDAV 密码 / 配对密钥，问题.md B1/B2 收敛）。
  SecretStore secrets = SecretStore();

  /// 各源 WebDAV 密码的内存镜像（编辑预填 / 源重建用；持久化在 [SecretStore]）。
  final Map<String, String> _webdavPwds = {};

  int _favoriteVersion = 0;

  /// 收藏列表版本号：全局收藏面板监听该值刷新（避免全量 rebuild）。
  int get favoriteVersion => _favoriteVersion;

  /// 歌曲元数据版本号：扫描/补读/编辑后自增，[LibraryProvider] 监听它就地重建。
  int _metaVersion = 0;
  int get metaVersion => _metaVersion;

  /// 「忽略音频（时长/大小）」等会影响列表内容的设置变更版本号：列表类 UI
  /// 监听它重查（改进.txt 功能6：设置变更后已入库歌曲也按新规则过滤）。
  int _settingsVersion = 0;
  int get settingsVersion => _settingsVersion;

  /// 设置变更后调用：通知列表类页面重查（歌曲/专辑/歌手/喜欢/源浏览 + 计数）。
  void settingsChanged() {
    _settingsVersion++;
    notifyListeners();
  }

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
      if (!s.supportsDirect) continue;
      try {
        await scanSource(s.key);
      } catch (_) {
        // 自动扫描失败静默，不影响其余源。
      }
    }
  }

  /// 关联后端接入点（同步/配对用；未配置时同步全跳）。
  /// 关联后补发存量远端源的 source.create（仅一次：uuid 已存在的不再重发）。
  void attachApi(ApiClient api) {
    _api = api;
    unawaited(_bootstrapSourceSync());
  }

  /// 存量远端类型源首次接入同步时补 uuid + source.create。
  Future<void> _bootstrapSourceSync() async {
    if (!isServerAvailable) return;
    for (final r in index.listSources()) {
      if (!isSyncableKind(r.kind)) continue;
      if (index.sourceUuidOf(r.key) != null) continue;
      await index.ensureSourceUuid(r.key);
      await _emitSource(SyncEventTypes.sourceCreate, r.key);
    }
  }

  /// 远端类型源的同步事件（本地文件夹源各机独立；未连服务器不发）。
  Future<void> _emitSource(String type, String key) async {
    if (!isServerAvailable) return;
    final row = index.getSource(key);
    if (row == null || !isSyncableKind(row.kind)) return;
    final uuid = await index.ensureSourceUuid(key);
    Map<String, dynamic> cfg = const {};
    try {
      cfg = jsonDecode(row.config) as Map<String, dynamic>;
    } catch (_) {}
    final sanitized = Map<String, dynamic>.of(cfg)..remove('password');
    await index.enqueueOutbox(type, {
      'client_uuid': uuid,
      'kind': row.kind,
      if (row.name.isNotEmpty) 'name': row.name,
      'address': sourceAddressOf(row.kind, cfg),
      'config': sanitized,
      'enabled': row.enabled,
    });
  }

  /// 该源是否等待本机补输密码（同步到的 WebDAV 源密码不落地服务端）。
  bool sourceNeedsPassword(String key) {
    final s = sourceByKey(key);
    if (s == null || s.kind != SourceKind.webdav) return false;
    return (_webdavPwds[key] ?? '').isEmpty;
  }

  /// 同步落库后重建内存源列表（源集合可能新增/改名/删除/改配置）。
  /// 存量补推（歌单 + 权重绝对态）：把配对前建的数据补进 outbox，
  /// 由 SyncEngine 下个 tick 上推。配对成功后由用户弹窗确认触发，
  /// 每台设备只问一次，内容幂等（服务端 LWW，重跑安全）。
  /// 返回 {playlists, items, songs}。
  Future<Map<String, int>> backfillNow() async {
    final pl = await playlists.backfill();
    final songs = await weight.backfill();
    return {'playlists': pl['playlists']!, 'items': pl['items']!, 'songs': songs};
  }

  Future<void> reloadSourcesFromIndex() async {
    // 先完整重建新列表再整体替换：_sources 全程非空，避免「先 clear 再逐个 await
    // 重建」留下的空窗被并发读取（如启动断点恢复的 sourceByKey）命中，误报
    // 「找不到该歌曲的播放源」。webdav 源重建含 SecretStore 异步读，空隙真实存在。
    final rebuilt = <MusicSource>[];
    for (final r in index.listSources()) {
      if (!r.enabled) continue;
      final src = await _buildRowFromRow(r);
      if (src != null) rebuilt.add(src);
    }
    _sources
      ..clear()
      ..addAll(rebuilt);
    restartAutoScan();
    notifyListeners();
  }

  Future<MusicSource?> _buildRowFromRow(DirectSourceRow r) async {
    try {
      if (r.kind == 'webdav') {
        var cfg = jsonDecode(r.config) as Map<String, dynamic>;
        final name = (cfg['name'] as String? ?? r.name).toString();
        var pwd = await secrets.webdavPassword(r.key);
        final legacy = (cfg['password'] as String? ?? '');
        if ((pwd == null || pwd.isEmpty) && legacy.isNotEmpty) {
          await secrets.setWebdavPassword(r.key, legacy);
          pwd = legacy;
        }
        if (cfg.containsKey('password')) {
          cfg = Map<String, dynamic>.of(cfg)..remove('password');
          await index.upsertSource(r.key, r.kind, r.name, jsonEncode(cfg));
        }
        _webdavPwds[r.key] = pwd ?? '';
        cfg['password'] = pwd ?? '';
        return _buildDirect(
            kind: r.kind, key: r.key, name: name, cfg: cfg);
      }
      if (r.kind == 'local') {
        final cfg = jsonDecode(r.config) as Map<String, dynamic>;
        final name = cfg['name'] as String? ?? r.name;
        return _buildDirect(
            kind: r.kind, key: r.key, name: name, cfg: cfg);
      }
    } catch (_) {
      // 忽略损坏的源配置。
    }
    return null;
  }

  /// 服务器是否可达（配了后端地址）：直连歌曲同步事件的进队门控
  ///（SongWeightStore/PlaylistStore/PlayerProvider 共用；SyncEngine 用
  ///同一信号决定是否上推，未配对时跳过）。读实时值，attach 先后无碍。
  bool get isServerAvailable => _api?.baseUrl.isNotEmpty ?? false;

  bool get ready => _ready;
  List<MusicSource> get sources => List.unmodifiable(_sources);

  /// 轻量刷新：通知监听者重建（如切换动画设置即时生效）。
  void refresh() => notifyListeners();

  /// 「信任自签名」开关已写入 [settings] 后调用：按新策略重建 WebDAV 直连源
  /// （dart:io `badCertificateCallback`），本地源无需重建。
  void applySecuritySettings() {
    final rebuilt = <MusicSource>[];
    for (final s in _sources) {
      final row = index.getSource(s.key);
      if (row == null) {
        rebuilt.add(s);
        continue;
      }
      Map<String, dynamic> cfg = {};
      try {
        cfg.addAll(jsonDecode(row.config) as Map<String, dynamic>);
      } catch (_) {}
      rebuilt.add(_buildDirect(
          kind: row.kind,
          key: row.key,
          name: (cfg['name'] as String? ?? row.name).toString(),
          cfg: cfg));
    }
    _sources
      ..clear()
      ..addAll(rebuilt);
    notifyListeners();
  }

  Future<void> init() async {
    await index.open();
    settings = AppSettings(index);
    cache = CacheManager(index, settings);
    weight = SongWeightStore(index,
        serverAvailable: () => isServerAvailable);
    playlists = PlaylistStore(index,
        serverAvailable: () => isServerAvailable);
    final rows = index.listSources();
    for (final r in rows) {
      if (!r.enabled) continue;
      final src = await _buildRowFromRow(r);
      if (src != null) _sources.add(src);
      // SMB 自动恢复在阶段 4 补充。
    }
    _ready = true;
    restartAutoScan();
    notifyListeners();
    // 一次性回填：旧版封面读取受头部采样截断（大内嵌封面丢失）且已标已读的行，
    // 重置为未读，交给后台补读用加深的封面读取重取。仅本机一次（不进 knownKeys）。
    if (!settings.coverReenrichV1Done) {
      final reset = await index.resetMetaReadForMissingCovers();
      settings.coverReenrichV1Done = true;
      if (reset > 0) debugPrint('封面回填补读：已重置 $reset 首待重读');
    }
    // 一次性回填：旧版解析在块序异常（如 FLAC 的 PICTURE 在 VORBIS_COMMENT
    // 之前）的文件上提前中断，已标已读却读不出歌手。重置这些行，交给后台
    // 补读用「从头完整读取」重取。仅本机一次（不进 knownKeys）。
    if (!settings.metaReenrichV2Done) {
      final keys = _sources.map((s) => s.key).toList();
      final reset = await index.resetMetaReadForMissingArtist(keys);
      settings.metaReenrichV2Done = true;
      if (reset > 0) debugPrint('元数据回填补读：已重置 $reset 首待重读');
    }
    // 后台清理历史无效封面（旧解析缺陷可能写脏数据），清理到的歌标未读待补读。
    unawaited(index.cleanupInvalidCovers().then((cleaned) {
      if (cleaned > 0) {
        _metaVersion++;
        notifyListeners();
      }
    }));
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

  String _webdavKey(String name) => 'webdav:$name';

  String _localKey(String name) => 'local:$name';

  /// 按源类型构建直连源实例（webdav / local）。WebDAV 密码取内存镜像
  /// （持久化在 SecretStore，config 不落地明文）；[allowSelfSigned] 随直连构建生效。
  MusicSource _buildDirect({
    required String kind,
    required String key,
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
      password: _webdavPwds[key] ?? (cfg['password'] as String? ?? ''),
      index: index,
      allowSelfSigned: settings.allowSelfSigned,
    );
  }

  /// 读取某源的可编辑配置（含 kind/name/path/baseUrl/username/password）。
  Map<String, dynamic> editableConfig(String key) {
    final row = index.getSource(key);
    if (row == null) return const {};
    final cfg = <String, dynamic>{'kind': row.kind, 'key': row.key};
    try {
      cfg.addAll(jsonDecode(row.config) as Map<String, dynamic>);
    } catch (_) {}
    // WebDAV 密码从内存镜像（SecretStore）回填，供编辑弹窗预填。
    cfg['password'] = _webdavPwds[key] ?? '';
    return cfg;
  }

  void setActive(String key) {
    notifyListeners();
  }

  MusicSource? sourceByKey(String key) =>
      _sources.where((x) => x.key == key).firstOrNull;

  Future<void> addWebdav({
    required String name,
    required String baseUrl,
    String username = '',
    String password = '',
  }) async {
    final key = _webdavKey(name);
    _webdavPwds[key] = password;
    await secrets.setWebdavPassword(key, password);
    // config 不含密码（明文收敛到 SecretStore）。
    final cfg = <String, dynamic>{
      'name': name,
      'baseUrl': baseUrl,
      'username': username,
    };
    _sources.add(_buildDirect(
        kind: 'webdav', key: key, name: name, cfg: cfg));
    await index.upsertSource(key, 'webdav', name, jsonEncode(cfg));
    await index.ensureSourceUuid(key);
    await _emitSource(SyncEventTypes.sourceCreate, key);
    restartAutoScan();
    notifyListeners();
  }

  /// 新增本地文件夹源。
  Future<void> addLocal({
    required String name,
    required String path,
  }) async {
    final key = _localKey(name);
    final cfg = <String, dynamic>{
      'name': name,
      'path': path,
    };
    _sources.add(
        _buildDirect(kind: 'local', key: key, name: name, cfg: cfg));
    await index.upsertSource(key, 'local', name, jsonEncode(cfg));
    restartAutoScan();
    notifyListeners();
  }

  /// 编辑源：可改 名称（含 key 迁移）/ 地址或目录 / 账号 / 密码。
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

    final newKey = '${row.kind}:$newName';
    if (newKey != key && _sources.any((s) => s.key == newKey)) {
      throw StateError('已存在同名播放源');
    }

    // WebDAV 密码：持久化收敛到 SecretStore，config 不落地明文。
    if (password != null) {
      cfg.remove('password');
      if (newKey != key) {
        await secrets.migrateWebdav(key, newKey);
        _webdavPwds.remove(key);
      }
      await secrets.setWebdavPassword(newKey, password);
      _webdavPwds[newKey] = password;
    } else if (newKey != key && _webdavPwds.containsKey(key)) {
      // 仅改名未传密码：迁移内存镜像 + SecretStore 键。
      await secrets.migrateWebdav(key, newKey);
      _webdavPwds[newKey] = _webdavPwds[key]!;
      _webdavPwds.remove(key);
    }

    final rebuilt = <MusicSource>[];
    for (final s in _sources) {
      if (s.key == key) {
        rebuilt.add(_buildDirect(
            kind: row.kind, key: newKey, name: newName, cfg: cfg));
      } else {
        rebuilt.add(s);
      }
    }
    _sources
      ..clear()
      ..addAll(rebuilt);
    if (newKey != key) {
      await index.renameSource(key, newKey);
    }
    await index.upsertSource(newKey, row.kind, newName, jsonEncode(cfg));
    await _emitSource(SyncEventTypes.sourceUpdate, newKey);
    restartAutoScan();
    notifyListeners();
  }

  Future<void> removeSource(String key) async {
    _emitSource(SyncEventTypes.sourceDelete, key);
    _scanTokens[key]?.cancel();
    final gone = _watchers.where((w) => w.key == key).toList();
    for (final w in gone) {
      w.dispose();
    }
    _watchers.removeWhere((w) => gone.contains(w));
    _sources.removeWhere((s) => s.key == key);
    _webdavPwds.remove(key);
    await secrets.deleteWebdav(key);
    await index.deleteSource(key);
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
      await index.updateSourceScan(key, 'scanning');
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
      await index.updateSourceScan(
          key, token.cancelled ? 'cancelled' : 'done');
      // 扫描有增改 → 元数据版本自增（全局库/LibraryProvider 就地刷新）。
      if (summary.added > 0 || summary.updated > 0) {
        _metaVersion++;
        _reconcileArtists();
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
      await index.updateSourceScan(key, 'failed');
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

  /// 「忽略音频（时长/大小）」读取期过滤（改进.txt 功能6）：已入库歌曲
  /// 按当前设置即时过滤；设置本身就是阈值，0=关。
  ({int minDurationSec, int minSizeBytes}) get _ignoreFilters => (
        minDurationSec: settings.scanIgnoreMinDurationSec,
        minSizeBytes: settings.scanIgnoreMinSizeBytes,
      );

  /// 检索某源索引的歌（本地索引）。
  List<Song> songsOf(String? sourceKey, {String? query}) {
    if (sourceKey == null) return const [];
    final f = _ignoreFilters;
    return index.searchSongs(
        sourceKey: sourceKey,
        query: query,
        minDurationSec: f.minDurationSec,
        minSizeBytes: f.minSizeBytes);
  }

  int countOf(String sourceKey) {
    final f = _ignoreFilters;
    return index.countSongs(sourceKey,
        minDurationSec: f.minDurationSec, minSizeBytes: f.minSizeBytes);
  }

  /// 所有直连源本地索引歌曲的总和（供全局图库合并）。
  List<Song> allSongs({String? query}) {
    final f = _ignoreFilters;
    final out = <Song>[];
    for (final s in _sources) {
      out.addAll(index.searchSongs(
          sourceKey: s.key,
          query: query,
          minDurationSec: f.minDurationSec,
          minSizeBytes: f.minSizeBytes));
    }
    return out;
  }

  /// 所有直连源歌曲总数。
  int get allSongsCount {
    final f = _ignoreFilters;
    var n = 0;
    for (final s in _sources) {
      n += index.countSongs(s.key,
          minDurationSec: f.minDurationSec, minSizeBytes: f.minSizeBytes);
    }
    return n;
  }

  /// 收藏统一收口到 play_meta；收藏直连歌自动后台缓存。
  Future<void> setFavorite(Song s, bool fav) async {
    if (fav) {
      await weight.setLiked(s);
    } else {
      await weight.setUnliked(s);
    }
    _favoriteVersion++;
    notifyListeners();
    // 自动缓存喜欢的直连歌（LRU 淘汰见 CacheManager，stage2.md §6）。
    if (fav && s.isDirect) {
      unawaited(cache.autoCacheIfNeeded(sourceByKey(s.sourceKey), s,
          becameFavorite: true));
    }
  }

  /// 全部已收藏歌曲（统一来自 play_meta 快照，忽略音频规则仅作用于直连歌）。
  List<Song> favoriteSongs() {
    final f = _ignoreFilters;
    return index.likedSongs(
        minDurationSec: f.minDurationSec, minSizeBytes: f.minSizeBytes);
  }

  /// 是否处于「不喜欢」态（权重锁定最低）。
  bool isDisliked(Song s) => weight.isDisliked(s);
  /// 手动「不喜欢」开关：开 → 权重降到最低并锁定；关 → 解锁回到 1.0。
  Future<void> setDisliked(Song s, bool disliked) async {
    await weight.setDisliked(s, disliked);
    _favoriteVersion++;
    notifyListeners();
  }

  /// 用户手动修改歌曲元数据（标题/歌手/专辑/专辑歌手）。
  ///
  /// 落库并标记扫描保护；字段语义：null=不修改，''=清空为未知，其余=新值。
  /// 返回刷新后的歌曲（供播放队列/当前歌曲同步），失败返回 null。
  Future<Song?> updateSongMeta(Song s,
      {String? title,
      String? artist,
      String? album,
      String? albumArtist}) async {
    await index.updateSongUserMeta(s.sourceKey, s.sourceRef,
        title: title, artist: artist, album: album, albumArtist: albumArtist);
    _metaVersion++;
    _favoriteVersion++;
    notifyListeners();
    return index.songByRef(s.sourceKey, s.sourceRef);
  }

  Future<void> cacheSong(MusicSource src, Song s) async {
    await src.cacheSong(s);
    cache.currentCacheKey = cache.cacheKeyOf(src, s);
    cache.evictIfNeeded();
    notifyListeners();
  }

  /// 预载指定歌曲（播放开始后对 peekNext() 的结果调用）：
  /// 开关关闭/非直连歌/已缓存直接返回；下载后走 LRU 淘汰（预载条目受保护），失败静默。
  Future<void> preloadSong(Song s) async {
    if (!settings.preloadNext) return;
    if (!s.isDirect) return;
    final src = sourceByKey(s.sourceKey);
    if (src == null) return;
    try {
      final existing = await src.cachedFilePath(s);
      if (existing != null) {
        // 已缓存：只刷新访问时间并登记保护，不再下载。
        cache.touch(src, s);
        cache.preloadCacheKey = cache.cacheKeyOf(src, s);
        return;
      }
      await src.cacheSong(s);
      final k = cache.cacheKeyOf(src, s);
      if (k != null) index.touchCache(k);
      cache.preloadCacheKey = k;
      cache.evictIfNeeded();
    } catch (_) {
      // 预载失败静默，不影响当前播放。
    }
  }

  String? cachedPathOf(MusicSource src, Song s) {
    final k = cache.cacheKeyOf(src, s);
    return k == null ? null : index.cachedPath(k);
  }

  /// 播放某直连歌时登记其缓存访问时间与当前 key（LRU 保留当前播放），
  /// 并触发后台元数据补读（未读过的歌曲逐个读头回填）。
  void onTrackPlaying(MusicSource src, Song s) {
    cache.currentCacheKey = cache.cacheKeyOf(src, s);
    // 预载曲开始播放：解除预载保护（它现在由 currentCacheKey 保护）。
    final k = cache.cacheKeyOf(src, s);
    if (k != null && cache.preloadCacheKey == k) cache.preloadCacheKey = null;
    cache.touch(src, s);
    _playingSourceKey = s.sourceKey;
    _playingRef = s.sourceRef;
    enrichUnreadInBackground();
  }

  bool _enrichRunning = false;
  String? _playingSourceKey;
  String? _playingRef;

  /// 后台补读：各直连源未读取过元数据的歌曲逐个读头回填，分批循环直到读完。
  /// 播放开始后触发；单例运行；跳过正在播放的歌（播放链路自己会重读）；
  /// 解析失败不标已读，靠 id 游标跳过继续处理后面的歌（不整批卡死）；
  /// 每批成功即通知 UI 就地刷新。
  void enrichUnreadInBackground() {
    if (_enrichRunning) return;
    _enrichRunning = true;
    unawaited(_doEnrichUnread());
  }

  /// 播放链路懒补读成功后调用：元数据版本号 +1，驱动全局库/列表就地刷新。
  void notifySongMetaChanged() {
    _metaVersion++;
    notifyListeners();
  }

  Future<void> _doEnrichUnread() async {
    try {
      for (final s in _sources) {
        if (!s.supportsDirect) continue;
        var afterId = 0;
        while (true) {
          final skipRef = _playingSourceKey == s.key ? _playingRef : null;
          final unread = index.unreadSongs(s.key, 100,
              excludeRef: skipRef, afterId: afterId > 0 ? afterId : null);
          if (unread.isEmpty) break;
          for (final song in unread) {
            // 游标始终前进：不可解析/失败的歌本轮跳过，下次播放再重试。
            if (song.id > afterId) afterId = song.id;
            try {
              await enrichSongMeta(index, s, song);
            } catch (_) {
              // 单首失败跳过，不标已读。
            }
            // 让出事件循环，避免长循环卡 UI。
            await Future.delayed(Duration.zero);
          }
          _metaVersion++;
          notifyListeners();
        }
        _reconcileArtists();
      }
    } finally {
      _enrichRunning = false;
    }
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
