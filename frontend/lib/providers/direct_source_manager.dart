import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/sources/music_source.dart';
import '../data/sources/meta_enrich.dart';
import '../data/sources/scan_worker.dart';
import '../data/sources/webdav_direct_source.dart';
import '../data/sources/local_direct_source.dart';
import '../data/sources/sftp_direct_source.dart';
import '../data/sources/smb_direct_source.dart';
import '../data/local/local_index.dart';
import '../data/local/sync_event_types.dart';
import '../data/local/app_settings.dart';
import '../data/local/cache_manager.dart';
import '../data/local/song_weight_store.dart';
import '../data/local/playlist_store.dart';
import '../models/song.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../services/api_client.dart';
import '../services/artist_resolver.dart';
import '../services/secret_store.dart';
import '../utils/cover_thumb.dart';
import '../utils/chunked_scheduler.dart';
import '../utils/perf_log.dart';
import '../utils/main_thread_probe.dart';
import '../utils/interaction_gate.dart';
import '../utils/thumb_gen_stats.dart';
import '../platform/harmonyos/ohos_bootstrap.dart' show isOhos;
import '../platform/harmonyos/harmonyos_player_flags.dart';
import 'direct_task_queue.dart';

/// 缩略图回填的批间让出间隔：线程下沉后原逐张固定间隔（ohos 50ms）已**放宽为 0**
/// ——节奏改由有界并发（[DirectSourceManager.thumbBackfillMaxInflight]）控制，
/// 不再逐张串行顿挫（R-5 / US2）。其余平台原即为 0，行为不变（R-9）。
const Duration _thumbBackfillGap = Duration.zero;

/// 交互期错峰等待步长（R-5 / T011）：交互进行中暂停推进「下一批」，交互结束
/// 立即续跑（幂等、最终一致，只是错开动画窗口）。
const Duration _interactionWaitStep = Duration(milliseconds: 120);

/// 回填默认并发上限 / 批大小（可配；R-4）。仅 ohos 启用多并发，其余平台保持
/// 串行（maxInflight=1），确保非 ohos 行为零回退（R-9）。
const int _thumbBackfillDefaultMaxInflight = 2;
const int _thumbBackfillDefaultBatchSize = 16;

/// 后台补读「整批提交」的分片大小（spec/ohos-meta-enrich-native R-2 / FR-001）：
/// 逐首提交任务（游标推进 + 入队）虽轻，但整批 100 首的同步遍历仍可能形成长块；
/// 用 [runChunked] 每 [kEnrichSubmitChunk] 首让出一次事件循环，保证单次同步块 ≪ 50ms。
const int kEnrichSubmitChunk = 16;

/// 默认让出实现（可注入以便确定性测试）。
Future<void> _defaultThumbSleep(Duration d) => Future<void>.delayed(d);

/// 有界并发 + 批驱动的封面缩略图回填调度（R-4 / R-5，T010 / T011）。
///
/// - **去重**：同一 [covers] 路径只处理一次（保留首次出现的顺序）；
/// - **有界并发**：同一批内至多 [maxInflight] 个 [generate] 在飞（交互期收紧为 1）；
/// - **批驱动**：每批 [batchSize] 个跑完再取下一批，避免一次性倾泻任务/结果回主线程；
/// - **交互错峰**：每批开始前等待交互结束（[interactionWaitStep] 步长，幂等、最终
///   一致），交互期并发收紧为 1，结束后自动恢复；
/// - 返回「成功把展示路径切到缩略图」的数量。
///
/// [sleep] 可注入以便确定性测试（默认 `Future.delayed`）。
Future<int> runThumbBackfill({
  required List<String> covers,
  required Future<bool> Function(String cover) generate,
  required bool Function() isInteracting,
  int maxInflight = _thumbBackfillDefaultMaxInflight,
  int batchSize = _thumbBackfillDefaultBatchSize,
  Duration gap = _thumbBackfillGap,
  Duration interactionWaitStep = _interactionWaitStep,
  Future<void> Function(Duration) sleep = _defaultThumbSleep,
}) async {
  // 同目标去重：保留首次出现的顺序。
  final seen = <String>{};
  final queue = <String>[];
  for (final c in covers) {
    if (seen.add(c)) queue.add(c);
  }
  if (queue.isEmpty) return 0;
  final limit = maxInflight < 1 ? 1 : maxInflight;
  final batch = batchSize < 1 ? 1 : batchSize;
  var made = 0;
  var cursor = 0;
  while (cursor < queue.length) {
    // 交互期错峰：等交互结束再推进下一批（期间不派发新任务）。
    while (isInteracting()) {
      await sleep(interactionWaitStep);
    }
    final end = (cursor + batch < queue.length) ? cursor + batch : queue.length;
    final inflight = <Future<bool>>[];
    for (var i = cursor; i < end; i++) {
      final activeLimit = isInteracting() ? 1 : limit;
      while (inflight.length >= activeLimit) {
        if (await inflight.removeAt(0)) made++;
      }
      inflight.add(generate(queue[i]));
    }
    for (final f in inflight) {
      if (await f) made++;
    }
    cursor = end;
    if (gap > Duration.zero && cursor < queue.length) {
      await sleep(gap);
    }
  }
  return made;
}

/// 直连源管理（阶段 3 / 阶段 4 接收器）。
///
/// - 持有 [LocalIndex]（本地事实源）。
/// - 管理已配置的直连源（WebDAV / 本地 / SFTP / SMB 完整实现）。
/// - 所有源默认激活，歌曲经 [allSongs] 合并进全局图库。
/// - 提供 添加/删除/扫描/检索/收藏/缓存 等操作，并驱动 UI 刷新。
class DirectSourceManager extends ChangeNotifier {
  final LocalIndex index = LocalIndex();
  final List<MusicSource> _sources = [];

  /// 直连补读的串行优先级队列（当前曲元数据 → 下一首音频 → 下一首元数据 → 全库）。
  final DirectTaskQueue tasks = DirectTaskQueue();
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

  /// 交互门控（R-2）：由 main 注入。未注入时为 null，通知行为与改动前一致。
  InteractionGate? _interactionGate;
  void attachInteractionGate(InteractionGate gate) => _interactionGate = gate;

  /// 回填并发上限（可配；R-4/US2）。仅 ohos 生效多并发，非 ohos 回填固定串行。
  int thumbBackfillMaxInflight = _thumbBackfillDefaultMaxInflight;

  /// 回填批大小（可配；R-4/US2）。
  int thumbBackfillBatchSize = _thumbBackfillDefaultBatchSize;

  /// 通知出口：交互期（滚动/过渡/浮层/队列）把高频数据通知去重聚合，
  /// 交互结束补投一次（最终一致），避免数据通知在动画帧内造成整屏行级重建。
  ///
  /// 直接调用 [super.notifyListeners]（而非 [notifyListeners]）用于补投，
  /// 避免递归进门控。
  @override
  void notifyListeners() {
    final gate = _interactionGate;
    if (gate != null && gate.isInteracting) {
      gate.scheduleNotify(_emit);
      return;
    }
    _emit();
  }

  void _emit() => super.notifyListeners();

  /// 扫描/元数据回填变更后：校准歌手身份映射并唤醒后台解析（幂等、静默）。
  /// 映射写完才自增 [artistsVersion]：歌手页计数改由身份映射驱动，提前通知会
  /// 让列表先按旧映射算一遍数（详情页读实时数据，两处对不上）。
  void _reconcileArtists() {
    unawaited(index.reconcileArtists().then((_) {
      _artistsVersion++;
      notifyListeners();
      artistResolver?.wake();
    }));
  }

  ApiClient? _api;

  /// 敏感凭据统一存储（WebDAV 密码 / 配对密钥，问题.md B1/B2 收敛）。
  SecretStore secrets = SecretStore();

  /// 各源 WebDAV 密码的内存镜像（编辑预填 / 源重建用；持久化在 [SecretStore]）。
  final Map<String, String> _webdavPwds = {};

  /// 各源 SFTP 三件套的内存镜像（密码/私钥文本/passphrase；持久化在 [SecretStore]）。
  final Map<String, _SftpSecrets> _sftpSecrets = {};

  /// 各源 SMB 密码的内存镜像（持久化在 [SecretStore]；用户名与密码双空即匿名）。
  final Map<String, String> _smbPwds = {};

  /// 备用源凭据内存镜像（key → slot → 凭据；持久化在 SecretStore `#fb*` 槽位）。
  final Map<String, Map<int, String>> _webdavFbPwds = {};
  final Map<String, Map<int, _SftpSecrets>> _sftpFbSecrets = {};
  final Map<String, Map<int, String>> _smbFbPwds = {};

  int _favoriteVersion = 0;

  /// 收藏列表版本号：全局收藏面板监听该值刷新（避免全量 rebuild）。
  int get favoriteVersion => _favoriteVersion;

  /// 歌曲元数据版本号：扫描/补读/编辑后自增，[LibraryProvider] 监听它就地重建。
  int _metaVersion = 0;
  int get metaVersion => _metaVersion;

  /// 歌手身份映射版本号：reconcile（扫描/补读/编辑后重建歌曲↔身份映射）写完自增，
  /// [LibraryProvider] 监听它只重算歌手列表（不动歌曲列表）。
  int _artistsVersion = 0;
  int get artistsVersion => _artistsVersion;

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
    if (isOhos) {
      // ohos 用户存储层（类 FUSE）会合成目录事件洪水：真机 VM service
      // timeline 取证 ~7800 条 dart:io 事件/秒、应用全程 1.5-2 核自旋、
      // 内存压力周期性触发系统 GpuReclaim（2026-10-07）。ohos 放弃目录
      // 监听，自动扫描仍由周期定时器覆盖；其余平台行为不变。
      return;
    }
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
    final sanitized = Map<String, dynamic>.of(cfg)
      ..remove('password')
      ..remove('keyPem')
      ..remove('passphrase');
    // 备用同步：同样去敏感（各槽位只留非敏感连接参数）。
    final rawFbs = sanitized['fallbacks'];
    if (rawFbs is List) {
      sanitized['fallbacks'] = [
        for (final e in rawFbs)
          if (e is Map) sanitizeFallbackConfig(Map<String, dynamic>.of(
              e.map((k, v) => MapEntry(k.toString(), v))))
      ];
    }
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
    if (s == null) return false;
    if (s.kind == SourceKind.webdav) return (_webdavPwds[key] ?? '').isEmpty;
    // SMB：有用户名无密码才算待补（双空=匿名，不等待）。
    if (s is SmbDirectSource) {
      return s.username.isNotEmpty && (_smbPwds[key] ?? '').isEmpty;
    }
    return false;
  }

  /// 该源是否等待本机补输凭据（含 SFTP：按认证方式看密码或私钥；SMB 同上）。
  bool sourceNeedsSecrets(String key) {
    final s = sourceByKey(key);
    if (s == null) return false;
    if (s.kind == SourceKind.webdav) return sourceNeedsPassword(key);
    if (s is SmbDirectSource) return sourceNeedsPassword(key);
    if (s is SftpDirectSource) {
      final m = _sftpSecrets[key];
      if (s.authMethod == SftpAuthMethod.key) {
        return (m?.keyPem ?? '').isEmpty;
      }
      return (m?.password ?? '').isEmpty;
    }
    return false;
  }

  /// SSH 主机指纹存取（TOFU 钉，`ssh_known_hosts`，不参与同步）。
  String? sshFingerprintOf(String hostPort) =>
      index.sshFingerprint(hostPort);

  Future<void> pinSshHost(String hostPort, String fingerprint) =>
      index.sshPin(hostPort, fingerprint);

  Future<void> forgetSshHost(String hostPort) =>
      index.sshForget(hostPort);

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
    final oldSig = _watcherSignature(_sources);
    final rebuilt = <MusicSource>[];
    for (final r in index.listSources()) {
      if (!r.enabled) continue;
      final src = await _buildRowFromRow(r);
      if (src != null) rebuilt.add(src);
    }
    _sources
      ..clear()
      ..addAll(rebuilt);
    // watcher 重建只在「本地源的 key/路径」真变化时做：同步每次落库重载都
    // 取消+重挂目录监听是纯浪费，还会丢掉去抖状态与新事件窗口。
    if (_watcherSignature(_sources) != oldSig) restartAutoScan();
    notifyListeners();
  }

  /// 目录监听的关注面：本地源的 key + rootPath（其余源不挂 watcher）。
  String _watcherSignature(List<MusicSource> sources) => [
        for (final s in sources)
          if (s is LocalDirectSource) '${s.key}|${s.rootPath}' else s.key
      ].join('\n');

  Future<void> _loadFallbackSecrets(String key, Map<String, dynamic> cfg) async {
    final fbs = parseFallbackConfigs(cfg['fallbacks']);
    if (fbs.isEmpty) {
      _webdavFbPwds.remove(key);
      _sftpFbSecrets.remove(key);
      _smbFbPwds.remove(key);
      return;
    }
    final w = <int, String>{};
    final s = <int, _SftpSecrets>{};
    final m = <int, String>{};
    for (var i = 0; i < fbs.length; i++) {
      final kind = (fbs[i]['kind'] as String? ?? '').trim();
      if (kind == 'webdav') {
        w[i] = await secrets.webdavPasswordFb(key, i) ?? '';
      } else if (kind == 'sftp') {
        s[i] = _SftpSecrets(
          password: await secrets.sftpPasswordFb(key, i) ?? '',
          keyPem: await secrets.sftpKeyPemFb(key, i) ?? '',
          passphrase: await secrets.sftpKeyPassphraseFb(key, i) ?? '',
        );
      } else if (kind == 'smb') {
        m[i] = await secrets.smbPasswordFb(key, i) ?? '';
      }
    }
    if (w.isEmpty) {
      _webdavFbPwds.remove(key);
    } else {
      _webdavFbPwds[key] = w;
    }
    if (s.isEmpty) {
      _sftpFbSecrets.remove(key);
    } else {
      _sftpFbSecrets[key] = s;
    }
    if (m.isEmpty) {
      _smbFbPwds.remove(key);
    } else {
      _smbFbPwds[key] = m;
    }
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
        await _loadFallbackSecrets(r.key, cfg);
        return _buildDirect(
            kind: r.kind, key: r.key, name: name, cfg: cfg);
      }
      if (r.kind == 'local') {
        final cfg = jsonDecode(r.config) as Map<String, dynamic>;
        final name = cfg['name'] as String? ?? r.name;
        await _loadFallbackSecrets(r.key, cfg);
        return _buildDirect(
            kind: r.kind, key: r.key, name: name, cfg: cfg);
      }
      if (r.kind == 'sftp') {
        final cfg = jsonDecode(r.config) as Map<String, dynamic>;
        final name = (cfg['name'] as String? ?? r.name).toString();
        _sftpSecrets[r.key] = _SftpSecrets(
          password: await secrets.sftpPassword(r.key) ?? '',
          keyPem: await secrets.sftpKeyPem(r.key) ?? '',
          passphrase: await secrets.sftpKeyPassphrase(r.key) ?? '',
        );
        await _loadFallbackSecrets(r.key, cfg);
        return _buildDirect(
            kind: r.kind, key: r.key, name: name, cfg: cfg);
      }
      if (r.kind == 'smb') {
        var cfg = jsonDecode(r.config) as Map<String, dynamic>;
        final name = (cfg['name'] as String? ?? r.name).toString();
        var pwd = await secrets.smbPassword(r.key);
        final legacy = (cfg['password'] as String? ?? '');
        if ((pwd == null || pwd.isEmpty) && legacy.isNotEmpty) {
          await secrets.setSmbPassword(r.key, legacy);
          pwd = legacy;
        }
        if (cfg.containsKey('password')) {
          cfg = Map<String, dynamic>.of(cfg)..remove('password');
          await index.upsertSource(r.key, r.kind, r.name, jsonEncode(cfg));
        }
        _smbPwds[r.key] = pwd ?? '';
        await _loadFallbackSecrets(r.key, cfg);
        return _buildDirect(
            kind: r.kind, key: r.key, name: name, cfg: cfg);
      }
    } catch (e) {
      // 损坏的源配置：记日志再丢行。曾出现"源在安卓可见、鸿蒙不可见"的
      // 线上 case，静默丢行零线索难定位，故此处必须带 kind+key 落日志。
      debugPrint('[direct] 忽略损坏的源配置 ${r.kind}:${r.key}: $e');
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
  /// （dart:io `badCertificateCallback`），本地源无需重建。同步刷新鸿蒙原生
  /// 播放器（fvp/mdk）的 `avio.tls_verify` 镜像。
  void applySecuritySettings() {
    ohosPlayerAllowSelfSigned = settings.allowSelfSigned;
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
    perfLog('boot.directInit indexOpen before');
    await index.open();
    perfLog('boot.directInit indexOpen done');
    settings = AppSettings(index);
    // 自签策略镜像给鸿蒙原生播放器（mdk `avio.tls_verify`）。
    ohosPlayerAllowSelfSigned = settings.allowSelfSigned;
    // 压缩图像画质开关（默认关）：同步给 cover_thumb 全局闸（显示+生成共用）。
    setCoverThumbCompressionEnabled(settings.compressCoverImage);
    cache = CacheManager(index, settings);
    weight = SongWeightStore(index,
        serverAvailable: () => isServerAvailable);
    playlists = PlaylistStore(index,
        serverAvailable: () => isServerAvailable);
    final rows = index.listSources();
    perfLog('boot.directInit listSources done', 'rows=${rows.length}');
    for (final r in rows) {
      if (!r.enabled) continue;
      final src = await _buildRowFromRow(r);
      if (src != null) _sources.add(src);
    }
    perfLog('boot.directInit buildRows done', 'sources=${_sources.length}');
    _ready = true;
    restartAutoScan();
    perfLog('boot.directInit restartAutoScan done');
    notifyListeners();
    // 一次性回填与封面清理不阻塞启动链：首启可能重置大量行（旧解析缺陷兜底），
    // 原先是 await 在 main() 的 init 链上。重置只改 meta_read 标记，随后播放/
    // 后台补读会重读；清理完成有变化再通知列表刷新。
    unawaited(_runOneTimeBackfills());
  }

  /// 一次性回填（封面/元数据/RIFF 尾块）+ 历史无效封面清理（版本标记保证只跑一次）。
  Future<void> _runOneTimeBackfills() async {
    try {
      perfPhase('direct.backfills'); // TEMP-PROBE
      // 一次性回填：旧版封面读取受头部采样截断（大内嵌封面丢失）且已标已读的行，
      // 重置为未读，交给后台补读用加深的封面读取重取。仅本机一次（不进 knownKeys）。
      if (!settings.coverReenrichV1Done) {
        perfPhase('direct.backfills.resetMissingCovers'); // TEMP-PROBE
        final reset = await index.resetMetaReadForMissingCovers();
        settings.coverReenrichV1Done = true;
        if (reset > 0) debugPrint('封面回填补读：已重置 $reset 首待重读');
      }
      // 一次性回填：旧版解析在块序异常（如 FLAC 的 PICTURE 在 VORBIS_COMMENT
      // 之前）的文件上提前中断，已标已读却读不出歌手。重置这些行，交给后台
      // 补读用「从头完整读取」重取。仅本机一次（不进 knownKeys）。
      if (!settings.metaReenrichV2Done) {
        perfPhase('direct.backfills.resetMissingArtist'); // TEMP-PROBE
        final keys = _sources.map((s) => s.key).toList();
        final reset = await index.resetMetaReadForMissingArtist(keys);
        settings.metaReenrichV2Done = true;
        if (reset > 0) debugPrint('元数据回填补读：已重置 $reset 首待重读');
      }
      // 一次性回填：wav/aiff 的标签/封面常写在音频块之后的 `id3 ` 块里，旧版解析
      // 遇到 `data`/`SSND` 就 break，读不到却又标了已读。重置这些行交给后台补读。
      if (!settings.riffTailMetaV1Done) {
        perfPhase('direct.backfills.resetRiffTail'); // TEMP-PROBE
        final reset = await index.resetMetaReadForRiffTailTags();
        settings.riffTailMetaV1Done = true;
        if (reset > 0) debugPrint('wav/aiFF 尾块标签回填：已重置 $reset 首待重读');
      }
      // 后台清理历史无效封面（旧解析缺陷可能写脏数据），清理到的歌标未读待补读。
      perfPhase('direct.backfills.cleanupInvalidCovers'); // TEMP-PROBE
      final cleaned = await index.cleanupInvalidCovers();
      if (cleaned > 0) {
        _metaVersion++;
        notifyListeners();
      }
      // 存量封面补齐缩略图（老版本只存了全尺寸原图）：一次性后台补齐，
      // 新增封面在补读持久化时即时生成（meta_enrich），无需再扫。
      // 开关关闭时跳过且不标记：日后打开仍会补齐（打开时见 applyCoverThumbSetting）。
      if (!settings.coverThumbsV1Done) {
        if (settings.compressCoverImage) {
          perfPhase('direct.backfills.coverThumbs'); // TEMP-PROBE
          await _backfillCoverThumbs();
          settings.coverThumbsV1Done = true;
        }
      }
    } catch (e) {
      debugPrint('[direct] 一次性回填失败（忽略）：$e');
    }
  }

  /// 为存量封面生成列表用缩略图（滑动性能）：线程下沉后放宽逐张固定间隔，
  /// 改为**有界并发 + 批驱动**（[runThumbBackfill]），交互期错峰让位、结束时续跑；
  /// 失败忽略（展示自动退回原图）。新补读的封面在 [ensureCoverThumb] 即时生成。
  /// 开关关闭时直接返回（[ensureCoverThumb] 本身也有闸，此处避免空跑一批）。
  Future<void> _backfillCoverThumbs() async {
    if (!settings.compressCoverImage) return;
    final sw = Stopwatch()..start(); // TEMP-PROBE
    try {
      perfPhase('direct.backfillCoverThumbs'); // TEMP-PROBE
      ThumbGenStats.startBatch();
      final made = await runThumbBackfill(
        covers: index.allCoverPaths(),
        generate: (cover) async {
          perfPhase('direct.backfillCoverThumbs.one'); // TEMP-PROBE
          final before = coverDisplayPath(cover);
          await ensureCoverThumb(cover);
          return coverDisplayPath(cover) != before;
        },
        isInteracting: () => _interactionGate?.isInteracting ?? false,
        // 非 ohos 固定串行线程路径（R-9 零回退）；ohos 才有界并发提速（US2）。
        maxInflight: isOhos ? thumbBackfillMaxInflight : 1,
        batchSize: thumbBackfillBatchSize,
        gap: _thumbBackfillGap,
      );
      if (made > 0) debugPrint('[direct] 封面缩略图回填 $made 张');
    } catch (e) {
      debugPrint('[direct] 封面缩略图回填失败（忽略）：$e');
    } finally {
      perfLog('direct.backfillCoverThumbs',
          '${sw.elapsedMilliseconds}ms'); // TEMP-PROBE
    }
  }

  /// 设置页切换「压缩图像画质」后调用：同步全局开关并刷新列表；
  /// 由关→开且存量未补齐时，后台补触发一次回填（关→开不删文件，开→关不删文件）。
  Future<void> applyCoverThumbSetting() async {
    setCoverThumbCompressionEnabled(settings.compressCoverImage);
    notifyListeners();
    if (settings.compressCoverImage && !settings.coverThumbsV1Done) {
      await _backfillCoverThumbs();
      // 回填成功与否都标记，避免每次切换重复全扫；
      // 新封面后续由补读即时生成。
      settings.coverThumbsV1Done = true;
    }
  }

  /// 交互期错峰等待：滚动/过渡等交互进行时逐小步让出，结束后立即返回继续
  /// 后台补读（幂等、最终一致，不改变补读结果，只是措开动画窗口）。
  Future<void> _awaitInteractionIdle() async {
    final gate = _interactionGate;
    if (gate == null) return;
    while (gate.isInteracting) {
      await Future<void>.delayed(_interactionWaitStep);
    }
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

  String _sftpKey(String name) => 'sftp:$name';

  String _smbKey(String name) => 'smb:$name';

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
    if (kind == 'sftp') {
      final m = _sftpSecrets[key];
      return SftpDirectSource(
        name: name,
        host: cfg['host'] as String? ?? '',
        port: (cfg['port'] as num?)?.toInt() ?? 22,
        username: cfg['username'] as String? ?? '',
        authMethod: parseSftpAuthMethod(cfg['authMethod']),
        password: m?.password ?? '',
        keyPem: m?.keyPem ?? '',
        keyPassphrase: m?.passphrase ?? '',
        index: index,
        rootPath: cfg['path'] as String? ?? '',
        route: parseSourceRoute(cfg['route']),
      );
    }
    if (kind == 'smb') {
      return SmbDirectSource(
        name: name,
        host: cfg['host'] as String? ?? '',
        share: cfg['share'] as String? ?? '',
        username: cfg['username'] as String? ?? '',
        password: _smbPwds[key] ?? '',
        index: index,
        rootPath: cfg['path'] as String? ?? '',
        useSmbConnect: isOhos,
        route: parseSourceRoute(cfg['route']),
      );
    }
    return WebdavDirectSource(
      name: name,
      baseUrl: cfg['baseUrl'] as String? ?? '',
      username: cfg['username'] as String? ?? '',
      password: _webdavPwds[key] ?? (cfg['password'] as String? ?? ''),
      index: index,
      allowSelfSigned: settings.allowSelfSigned,
      route: parseSourceRoute(cfg['route']),
    );
  }

  /// 读取某源的可编辑配置（含 kind/name/path/baseUrl/username/password + fallbacks）。
  Map<String, dynamic> editableConfig(String key) {
    final row = index.getSource(key);
    if (row == null) return const {};
    final cfg = <String, dynamic>{'kind': row.kind, 'key': row.key};
    try {
      cfg.addAll(jsonDecode(row.config) as Map<String, dynamic>);
    } catch (_) {}
    // WebDAV 密码从内存镜像（SecretStore）回填，供编辑弹窗预填。
    cfg['password'] = _webdavPwds[key] ?? '';
    // SFTP 三件套同样回填（弹窗按认证方式取用）。
    final sm = _sftpSecrets[key];
    cfg['sftpPassword'] = sm?.password ?? '';
    cfg['sftpKeyPem'] = sm?.keyPem ?? '';
    cfg['sftpPassphrase'] = sm?.passphrase ?? '';
    // SMB 密码从内存镜像（SecretStore）回填，供编辑弹窗预填。
    cfg['smbPassword'] = _smbPwds[key] ?? '';
    // 备用：每个槽位回填敏感字段供编辑弹窗预填（含各类型密码/密钥）。
    final fbs = parseFallbackConfigs(cfg['fallbacks']);
    final outFbs = <Map<String, dynamic>>[];
    for (var i = 0; i < fbs.length; i++) {
      final fb = Map<String, dynamic>.of(fbs[i]);
      final kind = (fb['kind'] as String? ?? '').trim();
      if (kind == 'webdav') {
        fb['password'] = _webdavFbPwds[key]?[i] ?? '';
      } else if (kind == 'sftp') {
        final m = _sftpFbSecrets[key]?[i];
        fb['password'] = m?.password ?? '';
        fb['keyPem'] = m?.keyPem ?? '';
        fb['passphrase'] = m?.passphrase ?? '';
      } else if (kind == 'smb') {
        fb['password'] = _smbFbPwds[key]?[i] ?? '';
      }
      outFbs.add(fb);
    }
    cfg['fallbacks'] = outFbs;
    return cfg;
  }

  void setActive(String key) {
    notifyListeners();
  }

  MusicSource? sourceByKey(String key) =>
      _sources.where((x) => x.key == key).firstOrNull;

  // ---------- 备用源 ----------

  /// 该逻辑源的备用配置（已 sanitize 的持久化形态，不含敏感明文）。
  List<Map<String, dynamic>> fallbacksOf(String key) {
    final row = index.getSource(key);
    if (row == null) return const [];
    try {
      final cfg = jsonDecode(row.config) as Map<String, dynamic>;
      return parseFallbackConfigs(cfg['fallbacks']);
    } catch (_) {
      return const [];
    }
  }

  int fallbackCountOf(String key) => fallbacksOf(key).length;

  MusicSource? _buildFallbackDirect({
    required String primaryKey,
    required String primaryName,
    required int slot,
    required Map<String, dynamic> fb,
  }) {
    final kind = (fb['kind'] as String? ?? '').trim();
    if (kind.isEmpty || kind == 'local') return null;
    if (kind == 'webdav') {
      final pwd = _webdavFbPwds[primaryKey]?[slot] ?? '';
      return WebdavDirectSource(
        name: primaryName,
        baseUrl: fb['baseUrl'] as String? ?? '',
        username: fb['username'] as String? ?? '',
        password: pwd,
        index: index,
        allowSelfSigned: settings.allowSelfSigned,
        route: parseSourceRoute(fb['route']),
      );
    }
    if (kind == 'sftp') {
      final m = _sftpFbSecrets[primaryKey]?[slot];
      return SftpDirectSource(
        name: primaryName,
        host: fb['host'] as String? ?? '',
        port: (fb['port'] as num?)?.toInt() ?? 22,
        username: fb['username'] as String? ?? '',
        authMethod: parseSftpAuthMethod(fb['authMethod']),
        password: m?.password ?? '',
        keyPem: m?.keyPem ?? '',
        keyPassphrase: m?.passphrase ?? '',
        index: index,
        rootPath: fb['path'] as String? ?? '',
        route: parseSourceRoute(fb['route']),
      );
    }
    if (kind == 'smb') {
      final pwd = _smbFbPwds[primaryKey]?[slot] ?? '';
      return SmbDirectSource(
        name: primaryName,
        host: fb['host'] as String? ?? '',
        share: fb['share'] as String? ?? '',
        username: fb['username'] as String? ?? '',
        password: pwd,
        index: index,
        rootPath: fb['path'] as String? ?? '',
        useSmbConnect: isOhos,
        route: parseSourceRoute(fb['route']),
      );
    }
    return null;
  }

  /// 该逻辑源的备用实例（瞬态，不进 [_sources]，不索引不扫描）。
  /// 相对路径对应：调用方用主源的 `song.sourceRef` 直接在备源上 open。
  List<MusicSource> fallbackSourcesOf(String key) {
    final row = index.getSource(key);
    if (row == null) return const [];
    final fbs = fallbacksOf(key);
    if (fbs.isEmpty) return const [];
    final out = <MusicSource>[];
    for (var i = 0; i < fbs.length; i++) {
      final src = _buildFallbackDirect(
        primaryKey: key,
        primaryName: row.name,
        slot: i,
        fb: fbs[i],
      );
      if (src != null) out.add(src);
    }
    return out;
  }

  /// 手动线路偏好（auto/primary/fb0/fb1）。
  SourceLine linePrefOf(String key) =>
      parseSourceLine(settings.getSourceLine(key));
  Future<void> setLinePref(String key, SourceLine line) async {
    settings.setSourceLine(key, line.name);
    notifyListeners();
  }

  /// 播放候选排序：锁定线路只返回该路；auto 返回 [主, 备0, 备1] 中存在者。
  /// 返回 `(source, lineIndex)`，lineIndex: 0=主, 1=备1, 2=备2。
  List<(MusicSource, int)> lineCandidates(String key) {
    final primary = sourceByKey(key);
    if (primary == null) return const [];
    final fbs = fallbackSourcesOf(key);
    final pref = linePrefOf(key);
    switch (pref) {
      case SourceLine.primary:
        return [(primary, 0)];
      case SourceLine.fb0:
        return fbs.isNotEmpty ? [(fbs[0], 1)] : [(primary, 0)];
      case SourceLine.fb1:
        return fbs.length > 1 ? [(fbs[1], 2)] : [(primary, 0)];
      case SourceLine.auto:
        final out = <(MusicSource, int)>[(primary, 0)];
        for (var i = 0; i < fbs.length; i++) {
          out.add((fbs[i], i + 1));
        }
        return out;
    }
  }

  /// 备用是否待配凭据（供卡片提示）。
  bool fallbackNeedsSecrets(String key) {
    final fbs = fallbacksOf(key);
    for (var i = 0; i < fbs.length; i++) {
      final kind = (fbs[i]['kind'] as String? ?? '').trim();
      if (kind == 'webdav' &&
          ((_webdavFbPwds[key]?[i] ?? '').isEmpty)) {
        // WebDAV 允许空密码（匿名），仅同步来源且有用户名才算待补？与主源口径
        // 对齐：主源空密码即待补提示，此处同样提示空密码，避免静默失败。
        // 匿名需求可在弹窗留空保存，播放时仍可尝试。
        return true;
      }
      if (kind == 'smb') {
        final u = (fbs[i]['username'] as String? ?? '').trim();
        if (u.isNotEmpty && ((_smbFbPwds[key]?[i] ?? '').isEmpty)) return true;
      }
      if (kind == 'sftp') {
        final m = _sftpFbSecrets[key]?[i];
        final am = parseSftpAuthMethod(fbs[i]['authMethod']);
        if (am == SftpAuthMethod.key) {
          if ((m?.keyPem ?? '').isEmpty) return true;
        } else {
          if ((m?.password ?? '').isEmpty) return true;
        }
      }
    }
    return false;
  }

  /// 校验备用列表（UI 保存前调用）：返回错误文案，null=通过。
  /// 规则：至多2个、禁 local、地址必填且与主/彼此不重复。
  String? validateFallbacks(
      String primaryKind, Map<String, dynamic> primaryCfg, List<Map<String, dynamic>> fbs) {
    if (fbs.length > kMaxFallbacks) return '至多可设置两个备用源';
    final seen = <String>{};
    final primaryAddr = sourceAddressOf(primaryKind, primaryCfg);
    if (primaryAddr.isNotEmpty) seen.add('$primaryKind|$primaryAddr');
    for (var i = 0; i < fbs.length; i++) {
      final fb = fbs[i];
      final kind = (fb['kind'] as String? ?? '').trim();
      if (kind.isEmpty) return '${fallbackLabel(i)}请选择类型';
      if (kind == 'local') return '本地只可做主源，不可做备用源';
      final addr = fallbackAddressOf(fb);
      if (addr.isEmpty) return '${fallbackLabel(i)}地址不完整';
      final fp = '$kind|$addr';
      if (seen.contains(fp)) return '${fallbackLabel(i)}与主源/其他备用重复';
      seen.add(fp);
    }
    return null;
  }

  /// 持久化备用（含敏感收敛）：[rawFbs] 可携带 password/keyPem 等明文，
  /// 返回 sanitize 后的可存形态。调用方负责落库 + [_emitSource]。
  Future<List<Map<String, dynamic>>> _persistFallbackSecrets(
      String key, List<Map<String, dynamic>> rawFbs) async {
    final out = <Map<String, dynamic>>[];
    // 先清旧槽位内存（删除备用即删凭据，避免残留）。
    _webdavFbPwds.remove(key);
    _sftpFbSecrets.remove(key);
    _smbFbPwds.remove(key);
    final w = <int, String>{};
    final s = <int, _SftpSecrets>{};
    final m = <int, String>{};
    for (var i = 0; i < rawFbs.length && i < kMaxFallbacks; i++) {
      final fb = Map<String, dynamic>.of(rawFbs[i]);
      final kind = (fb['kind'] as String? ?? '').trim();
      if (kind == 'webdav') {
        final pwd = (fb['password'] as String? ?? '').toString();
        w[i] = pwd;
        await secrets.setWebdavPasswordFb(key, i, pwd);
      } else if (kind == 'sftp') {
        final entry = _SftpSecrets(
          password: (fb['password'] as String? ?? '').toString(),
          keyPem: (fb['keyPem'] as String? ?? '').toString(),
          passphrase: (fb['passphrase'] as String? ?? '').toString(),
        );
        s[i] = entry;
        await secrets.setSftpSecretsFb(key, i,
            password: entry.password,
            keyPem: entry.keyPem,
            passphrase: entry.passphrase);
      } else if (kind == 'smb') {
        final pwd = (fb['password'] as String? ?? '').toString();
        m[i] = pwd;
        await secrets.setSmbPasswordFb(key, i, pwd);
      }
      out.add(sanitizeFallbackConfig(fb));
    }
    // 清掉超出新长度的旧槽位（缩减/删除备用时）。
    for (var i = out.length; i < kMaxFallbacks; i++) {
      await secrets.deleteWebdavFb(key, i);
      await secrets.deleteSftpFb(key, i);
      await secrets.deleteSmbFb(key, i);
    }
    if (w.isNotEmpty) _webdavFbPwds[key] = w;
    if (s.isNotEmpty) _sftpFbSecrets[key] = s;
    if (m.isNotEmpty) _smbFbPwds[key] = m;
    return out;
  }

  /// 主源播放成功后的单首按需补齐（默认关）：抽查备源同 ref 是否存在，
  /// 缺失则把主源当前曲流式复制过去。失败静默（不打断播放）。
  Future<void> maybeRepairFallback(Song song) async {
    if (!settings.fallbackAutoRepair) return;
    if (!song.isDirect) return;
    final primary = sourceByKey(song.sourceKey);
    if (primary == null) return;
    final fbs = fallbackSourcesOf(song.sourceKey);
    if (fbs.isEmpty) return;
    for (final fb in fbs) {
      if (!fb.supportsWrite) continue;
      try {
        // 1 字节探针：存在即跳过，避免整曲搬运。
        try {
          await fb.open(song, range: const IntRange(0, 1)).then((o) async {
            await for (final _ in o.stream) {
              break;
            }
          });
          continue;
        } catch (_) {
          // 不存在才继续复制；探针异常同样按缺失处理（404/无权限都会抛）。
        }
        final opened = await primary.open(song);
        final total = opened.totalLength ?? song.fileSize;
        final ref = song.sourceRef;
        final slash = ref.lastIndexOf('/');
        final parent = slash <= 0 ? '' : ref.substring(0, slash);
        final filename =
            slash < 0 ? ref : ref.substring(slash + 1);
        if (filename.isEmpty || filename.contains('..')) continue;
        await fb.uploadFile(parent, filename, opened.stream, total);
      } catch (_) {
        // 单备失败不影响其他备。
      }
    }
  }

  Future<void> addWebdav({
    required String name,
    required String baseUrl,
    String username = '',
    String password = '',
    SourceRoute route = SourceRoute.direct,
    List<Map<String, dynamic>> fallbacks = const [],
  }) async {
    final key = _webdavKey(name);
    if (_sources.any((s) => s.key == key)) {
      throw StateError('已存在同名播放源');
    }
    _webdavPwds[key] = password;
    await secrets.setWebdavPassword(key, password);
    final sanitizedFbs = await _persistFallbackSecrets(key, fallbacks);
    // config 不含密码（明文收敛到 SecretStore）；route 随配置持久化并同步。
    final cfg = <String, dynamic>{
      'name': name,
      'baseUrl': baseUrl,
      'username': username,
      'route': route.name,
      if (sanitizedFbs.isNotEmpty) 'fallbacks': sanitizedFbs,
    };
    _sources.add(_buildDirect(
        kind: 'webdav', key: key, name: name, cfg: cfg));
    await index.upsertSource(key, 'webdav', name, jsonEncode(cfg));
    await index.ensureSourceUuid(key);
    await _emitSource(SyncEventTypes.sourceCreate, key);
    restartAutoScan();
    notifyListeners();
  }

  /// 新增本地文件夹源（本地只做主源，仍可配远端备用）。
  Future<void> addLocal({
    required String name,
    required String path,
    List<Map<String, dynamic>> fallbacks = const [],
  }) async {
    final key = _localKey(name);
    if (_sources.any((s) => s.key == key)) {
      throw StateError('已存在同名播放源');
    }
    final sanitizedFbs = await _persistFallbackSecrets(key, fallbacks);
    final cfg = <String, dynamic>{
      'name': name,
      'path': path,
      if (sanitizedFbs.isNotEmpty) 'fallbacks': sanitizedFbs,
    };
    _sources.add(
        _buildDirect(kind: 'local', key: key, name: name, cfg: cfg));
    await index.upsertSource(key, 'local', name, jsonEncode(cfg));
    restartAutoScan();
    notifyListeners();
  }

  /// 新增 SFTP 源（阶段 7）：密码与私钥文本只存 SecretStore，配置持久化
  /// 非敏感部分（host/port/username/authMethod/path/route）并参与同步。
  Future<void> addSftp({
    required String name,
    required String host,
    int port = 22,
    String username = '',
    SftpAuthMethod authMethod = SftpAuthMethod.password,
    String password = '',
    String keyPem = '',
    String passphrase = '',
    String rootPath = '',
    SourceRoute route = SourceRoute.direct,
    List<Map<String, dynamic>> fallbacks = const [],
  }) async {
    final key = _sftpKey(name);
    if (_sources.any((s) => s.key == key)) {
      throw StateError('已存在同名播放源');
    }
    _sftpSecrets[key] = _SftpSecrets(
        password: password, keyPem: keyPem, passphrase: passphrase);
    await secrets.setSftpSecrets(key,
        password: password, keyPem: keyPem, passphrase: passphrase);
    final sanitizedFbs = await _persistFallbackSecrets(key, fallbacks);
    final cfg = <String, dynamic>{
      'name': name,
      'host': host.trim(),
      'port': port,
      'username': username.trim(),
      'authMethod': authMethod.name,
      'path': rootPath.trim(),
      'route': route.name,
      if (sanitizedFbs.isNotEmpty) 'fallbacks': sanitizedFbs,
    };
    _sources.add(
        _buildDirect(kind: 'sftp', key: key, name: name, cfg: cfg));
    await index.upsertSource(key, 'sftp', name, jsonEncode(cfg));
    await index.ensureSourceUuid(key);
    await _emitSource(SyncEventTypes.sourceCreate, key);
    restartAutoScan();
    notifyListeners();
  }

  /// 新增 SMB 源（阶段 4）：密码只存 SecretStore，配置持久化非敏感部分
  /// （host/share/username/path/route）并参与同步；用户名与密码双空即匿名。
  Future<void> addSmb({
    required String name,
    required String host,
    required String share,
    String username = '',
    String password = '',
    String rootPath = '',
    SourceRoute route = SourceRoute.direct,
    List<Map<String, dynamic>> fallbacks = const [],
  }) async {
    final key = _smbKey(name);
    if (_sources.any((s) => s.key == key)) {
      throw StateError('已存在同名播放源');
    }
    _smbPwds[key] = password;
    await secrets.setSmbPassword(key, password);
    final sanitizedFbs = await _persistFallbackSecrets(key, fallbacks);
    final cfg = <String, dynamic>{
      'name': name,
      'host': host.trim(),
      'share': share.trim(),
      'username': username.trim(),
      'path': rootPath.trim(),
      'route': route.name,
      if (sanitizedFbs.isNotEmpty) 'fallbacks': sanitizedFbs,
    };
    _sources.add(
        _buildDirect(kind: 'smb', key: key, name: name, cfg: cfg));
    await index.upsertSource(key, 'smb', name, jsonEncode(cfg));
    await index.ensureSourceUuid(key);
    await _emitSource(SyncEventTypes.sourceCreate, key);
    restartAutoScan();
    notifyListeners();
    // 排查"鸿蒙建后即失踪"：此行出现=内存+落库+通知全成功，之后若列表仍无
    // 该行，必是后续 reload 丢行（看 [direct] 忽略损坏的源配置 日志）。
    debugPrint('[direct] 新增SMB源 $key（host=$host share=$share）');
  }

  /// 编辑源：可改 名称（含 key 迁移）/ 地址或目录 / 账号 / 密码·密钥 / 播放链路。
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
    SourceRoute? route,
    String? host,
    String? share,
    int? port,
    SftpAuthMethod? authMethod,
    String? keyPem,
    String? passphrase,
    List<Map<String, dynamic>>? fallbacks,
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
    if (route != null) cfg['route'] = route.name;
    if (host != null) cfg['host'] = host;
    if (share != null) cfg['share'] = share;
    if (port != null) cfg['port'] = port;
    if (authMethod != null) cfg['authMethod'] = authMethod.name;

    final newKey = '${row.kind}:$newName';
    if (newKey != key && _sources.any((s) => s.key == newKey)) {
      throw StateError('已存在同名播放源');
    }

    // WebDAV 密码：持久化收敛到 SecretStore，config 不落地明文。
    // （仅 webdav 行；sftp 走下方三件套，避免杂散键。）
    if (row.kind == 'webdav' && password != null) {
      cfg.remove('password');
      if (newKey != key) {
        await secrets.migrateWebdav(key, newKey);
        _webdavPwds.remove(key);
      }
      await secrets.setWebdavPassword(newKey, password);
      _webdavPwds[newKey] = password;
    } else if (row.kind == 'webdav' &&
        newKey != key &&
        _webdavPwds.containsKey(key)) {
      // 仅改名未传密码：迁移内存镜像 + SecretStore 键。
      await secrets.migrateWebdav(key, newKey);
      _webdavPwds[newKey] = _webdavPwds[key]!;
      _webdavPwds.remove(key);
    }

    // SFTP 三件套：同上收敛；改名迁移三键。
    if (row.kind == 'sftp' &&
        (password != null || keyPem != null || passphrase != null)) {
      if (newKey != key) {
        await secrets.migrateSftp(key, newKey);
        _sftpSecrets.remove(key);
      }
      final cur = _sftpSecrets[newKey];
      final merged = _SftpSecrets(
        password: password ?? cur?.password ?? '',
        keyPem: keyPem ?? cur?.keyPem ?? '',
        passphrase: passphrase ?? cur?.passphrase ?? '',
      );
      _sftpSecrets[newKey] = merged;
      await secrets.setSftpSecrets(newKey,
          password: merged.password,
          keyPem: merged.keyPem,
          passphrase: merged.passphrase);
    } else if (newKey != key && _sftpSecrets.containsKey(key)) {
      await secrets.migrateSftp(key, newKey);
      _sftpSecrets[newKey] = _sftpSecrets[key]!;
      _sftpSecrets.remove(key);
    }

    // SMB 密码：同上收敛；改名迁移密码键（匿名源密码恒空，迁移即清理旧键）。
    if (row.kind == 'smb' && password != null) {
      cfg.remove('password');
      if (newKey != key) {
        await secrets.migrateSmb(key, newKey);
        _smbPwds.remove(key);
      }
      await secrets.setSmbPassword(newKey, password);
      _smbPwds[newKey] = password;
    } else if (newKey != key && _smbPwds.containsKey(key)) {
      await secrets.migrateSmb(key, newKey);
      _smbPwds[newKey] = _smbPwds[key]!;
      _smbPwds.remove(key);
    }

    // 备用源：全量替换（null=不动，用于仅改主字段的旧调用）。
    if (fallbacks != null) {
      // 改名先迁移旧槽位，再按新 key 重存（_persist 会清旧内存并写新键）。
      if (newKey != key) {
        for (var i = 0; i < kMaxFallbacks; i++) {
          await secrets.migrateWebdavFb(key, newKey, i);
          await secrets.migrateSftpFb(key, newKey, i);
          await secrets.migrateSmbFb(key, newKey, i);
        }
        _webdavFbPwds.remove(key);
        _sftpFbSecrets.remove(key);
        _smbFbPwds.remove(key);
      }
      final sanitized = await _persistFallbackSecrets(newKey, fallbacks);
      if (sanitized.isEmpty) {
        cfg.remove('fallbacks');
      } else {
        cfg['fallbacks'] = sanitized;
      }
    } else if (newKey != key) {
      // 仅改名：迁移备用槽位 + 配置内 fallbacks 原样保留。
      for (var i = 0; i < kMaxFallbacks; i++) {
        await secrets.migrateWebdavFb(key, newKey, i);
        await secrets.migrateSftpFb(key, newKey, i);
        await secrets.migrateSmbFb(key, newKey, i);
      }
      if (_webdavFbPwds.containsKey(key)) {
        _webdavFbPwds[newKey] = _webdavFbPwds[key]!;
        _webdavFbPwds.remove(key);
      }
      if (_sftpFbSecrets.containsKey(key)) {
        _sftpFbSecrets[newKey] = _sftpFbSecrets[key]!;
        _sftpFbSecrets.remove(key);
      }
      if (_smbFbPwds.containsKey(key)) {
        _smbFbPwds[newKey] = _smbFbPwds[key]!;
        _smbFbPwds.remove(key);
      }
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
    _sftpSecrets.remove(key);
    await secrets.deleteSftp(key);
    _smbPwds.remove(key);
    await secrets.deleteSmb(key);
    for (var i = 0; i < kMaxFallbacks; i++) {
      await secrets.deleteWebdavFb(key, i);
      await secrets.deleteSftpFb(key, i);
      await secrets.deleteSmbFb(key, i);
    }
    _webdavFbPwds.remove(key);
    _sftpFbSecrets.remove(key);
    _smbFbPwds.remove(key);
    await index.deleteSource(key);
    notifyListeners();
  }

  /// 硬删一首歌曲（阶段6：删除全删 + 二次确认由 UI 完成）：
  /// 先删远端/本地文件，再清本地全部痕迹（索引/权重/歌词/歌单条目/歌手映射）
  /// 与离线缓存（文件+行）。任一步失败即抛错，调用方 toast。
  Future<void> deleteSong(Song song) async {
    final src = sourceByKey(song.sourceKey);
    if (src == null) throw StateError('源不存在：${song.sourceKey}');
    if (!src.supportsWrite) throw StateError('该源不支持删除');
    await src.deleteSong(song);
    // 离线缓存：cache_key 由源侧计算，先删文件+行再清 DB 痕迹。
    // （WebDAV/SFTP/SMB 三源都有 cacheKeyFor，对称处理。）
    final cacheKey = src is WebdavDirectSource
        ? src.cacheKeyFor(song)
        : src is SftpDirectSource
            ? src.cacheKeyFor(song)
            : src is SmbDirectSource
                ? src.cacheKeyFor(song)
                : null;
    if (cacheKey != null) {
      try {
        await index.deleteCache(cacheKey);
      } catch (_) {
        // 无缓存或删文件失败不挡主流程（DB 痕迹仍要清）。
      }
    }
    await index.deleteSong(song.sourceKey, song.sourceRef);
    weight.notifyExternalWrite();
    _metaVersion++;
    notifyListeners();
  }

  /// 上传音频文件到源根（parentRef=''）并增量刷新索引。
  /// 返回后调用方 toast + 局部刷新；大文件流式上传不驻留内存。
  Future<void> uploadAudio(String sourceKey, String filename,
      Stream<List<int>> bytes, int length) async {
    final src = sourceByKey(sourceKey);
    if (src == null) throw StateError('源不存在：$sourceKey');
    if (!src.supportsWrite) throw StateError('该源不支持上传');
    await src.uploadFile('', filename, bytes, length);
    // 上传后增量扫描该源（新文件指纹为 added，自动落库）。
    await scanSource(sourceKey);
  }

  Future<void> createFolder(String sourceKey, String name) async {
    final src = sourceByKey(sourceKey);
    if (src == null) throw StateError('源不存在：$sourceKey');
    if (!src.supportsWrite) throw StateError('该源不支持新建文件夹');
    await src.createFolder('', name);
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
      // 扫描方式写死「快速：只建索引」（原「扫描模式 / 读取音频头部 / 提取内嵌封面」
      // 三个设置项已随之删除）：PROPFIND/枚举拿到 ref/size/mtime/etag 就落库，一个
      // 字节的音频内容都不读，零读头请求。元数据与封面交给播放时补读与后台补读——
      // 那两条链路知道歌马上要放，按结构定位后精确读取（见 readAudioMeta），比在
      // 首扫里对整库盲目读头划算。代价：首扫没有时长，故时长过滤要等补读到时长后
      // 才生效（见设置项文案）。
      final summary = await src.scan(
        options: ScanOptions(
          minSizeBytes: settings.scanIgnoreMinSizeBytes,
          minDurationSec: settings.scanIgnoreMinDurationSec,
        ),
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

  /// 启动/刷新用的后台快照读：歌曲 + 专辑 + 歌手分组在后台 isolate 完成，
  /// UI isolate 不做 SELECT/映射/分组（消除启动两秒卡顿的来源）。
  Future<({List<Song> songs, List<Album> albums, List<Artist> artists})>
      librarySnapshotInBackground({String? query}) {
    final f = _ignoreFilters;
    return index.librarySnapshotInBackground(
      sourceKeys: [for (final s in _sources) s.key],
      query: query,
      artistSort: settings.sortArtists,
      minDurationSec: f.minDurationSec,
      minSizeBytes: f.minSizeBytes,
    );
  }

  /// 身份解析完成后的轻量刷新：只重算歌手分组（同样在后台 isolate）。
  Future<List<Artist>> artistGroupsInBackground({String? query}) {
    final f = _ignoreFilters;
    return index.artistGroupsInBackground(
      query: query,
      sort: settings.sortArtists,
      minDurationSec: f.minDurationSec,
      minSizeBytes: f.minSizeBytes,
    );
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
    // 改了歌手名 → 身份映射要跟着校准，否则歌手页/计数还挂在旧身份上。
    if (artist != null) {
      _reconcileArtists();
    }
    notifyListeners();
    return index.songByRef(s.sourceKey, s.sourceRef);
  }

  Future<void> cacheSong(MusicSource src, Song s) async {
    await src.cacheSong(s);
    cache.currentCacheKey = cache.cacheKeyOf(src, s);
    cache.evictIfNeeded();
    notifyListeners();
  }

  /// 预载指定歌曲（完整下载整曲）：
  /// 开关关闭/非直连歌/已缓存直接返回；下载后走 LRU 淘汰（预载条目受保护），失败静默。
  /// 由 [_scheduleNextTrack] 以 [DirectTaskPriority.nextAudio] 排队调用
  /// （原先是切歌时直接并发开跑，会跟当前曲的补读抢同一条链路）。
  Future<void> preloadSong(Song s, {bool Function()? shouldAbort}) async {
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
      await src.cacheSong(s, shouldAbort: shouldAbort);
      final k = cache.cacheKeyOf(src, s);
      if (k != null) index.touchCache(k);
      cache.preloadCacheKey = k;
      cache.evictIfNeeded();
    } on PreloadAbortedException {
      // 下一首变了，这份预载作废：不提示、不重试（缓存目录里的半截临时文件
      // 已由 cacheSong 自己清掉）。
      debugPrint('[preload] 放弃预载《${s.title}》（下一首已变）');
    } catch (_) {
      // 预载失败静默，不影响当前播放。
    }
  }

  /// 预载票据：换歌时作废在途的那一份（见 [_scheduleNextTrack]）。
  /// 用自增票据而不是一个布尔位——新预载开始时会清位，若只靠布尔位，
  /// 老预载下一轮轮询就会看到「已恢复」而继续下载，白占连接。
  int _preloadTicket = 0;
  bool _preloadAborted = false;

  Future<void> _runPreloadTask(Song s) async {
    final ticket = ++_preloadTicket;
    _preloadAborted = false;
    await preloadSong(s, shouldAbort: () => _preloadAborted || ticket != _preloadTicket);
  }

  String? cachedPathOf(MusicSource src, Song s) {
    final k = cache.cacheKeyOf(src, s);
    return k == null ? null : index.cachedPath(k);
  }

  /// 播放某直连歌时登记其缓存访问时间与当前 key（LRU 保留当前播放），
  /// 并按优先级重排「下一首」与全库后台补读（[DirectTaskQueue]）。
  ///
  /// [next] 是当前模式下接下来会播的那首（单曲循环为 null）：它要排在当前曲
  /// 元数据之后、全库后台补读之前。接线见 main.dart，由播放器算出后传入。
  void onTrackPlaying(MusicSource src, Song s, {Song? next}) {
    cache.currentCacheKey = cache.cacheKeyOf(src, s);
    // 预载曲开始播放：解除预载保护（它现在由 currentCacheKey 保护）。
    final k = cache.cacheKeyOf(src, s);
    if (k != null && cache.preloadCacheKey == k) cache.preloadCacheKey = null;
    cache.touch(src, s);
    _playingSourceKey = s.sourceKey;
    _playingRef = s.sourceRef;
    _scheduleNextTrack(next);
    // 主源播放成功才触发备用补齐（备用成功的 key 与 song.sourceKey 对不上，
    // 天然跳过；避免“主挂了还从主读”做无用功）。
    if (src.key == s.sourceKey) {
      unawaited(maybeRepairFallback(s));
    }
  }

  /// 下一首变了（插队/删曲/切模式）：作废过期的预载与预读，排新的。
  void onNextChanged(Song? next) {
    if (_playingSourceKey == null) return;
    _scheduleNextTrack(next);
  }

  void _scheduleNextTrack(Song? next) {
    // 换歌后旧任务已无意义（预载到不再会播的那首、给它补的封面也用不上）。
    tasks.dropPending((p, _) =>
        p == DirectTaskPriority.nextAudio || p == DirectTaskPriority.nextMeta);
    // 队列只能作废「还没开始」的任务；在途的整曲下载还在占连接，让它跑完会把
    // 当前曲的元数据/封面（最高优先级）堵到几分钟后。通知源放弃。
    _preloadAborted = true;
    final sameSong = next != null &&
        next.sourceKey == _playingSourceKey &&
        next.sourceRef == _playingRef;
    if (next != null && !sameSong) {
      final key = '${next.sourceKey}\u0000${next.sourceRef}';
      if (settings.preloadNext && next.isDirect) {
        tasks.submit(DirectTaskPriority.nextAudio,
            key: 'nextAudio/$key', body: () => _runPreloadTask(next));
      }
      tasks.submit(DirectTaskPriority.nextMeta,
          key: 'nextMeta/$key', body: () => enrichNextSongMeta(next));
    }
    enrichUnreadInBackground();
  }

  /// 下一首的元数据/封面补读：已读过的不重复（当前曲才每次强制重读）。
  Future<void> enrichNextSongMeta(Song s) async {
    final src = sourceByKey(s.sourceKey);
    if (src == null || !src.supportsDirect) return;
    final row = index.songByRef(s.sourceKey, s.sourceRef);
    if (row == null || row.metaRead) return;
    if (row.sourceKey == _playingSourceKey && row.sourceRef == _playingRef) return;
    try {
      await enrichSongMeta(index, src, row);
    } catch (_) {
      return; // 失败不标已读：下次切到它时再试。
    }
    _metaVersion++;
    notifyListeners();
  }

  /// 供 PlayerProvider 把「当前曲元数据/封面」排到队列最前（接线见 main.dart）。
  void submitCurrentMeta(String key, Future<void> Function() body) {
    tasks.submit(DirectTaskPriority.currentMeta, key: 'currentMeta/$key', body: body);
  }

  bool _enrichRunning = false;
  String? _playingSourceKey;
  String? _playingRef;

  /// 后台补读：各直连源未读取过元数据的歌曲逐个补齐，分批循环直到读完。
  /// 播放开始后触发；单例运行；跳过正在播放的歌（播放链路自己会重读）；
  /// 解析失败不标已读，靠 id 游标跳过继续处理后面的歌（不整批卡死）。
  ///
  /// 每一首都是一个独立的 [DirectTaskPriority.background] 任务：整批先排队，
  /// 再等这一批跑完才取下一批。这样切歌插进来的当前曲/下一首任务总能插到两首之间，
  /// 而不会等全库读完（原先是一个长循环，中途插进来的东西只能等它跑完整库）。
  void enrichUnreadInBackground() {
    if (_enrichRunning) return;
    _enrichRunning = true;
    unawaited(_pumpUnread());
  }

  /// 播放链路懒补读成功后调用：元数据版本号 +1，驱动全局库/列表就地刷新。
  void notifySongMetaChanged() {
    _metaVersion++;
    notifyListeners();
  }

  /// play_meta 由外部路径写入后调用（如同步引擎 pull 落库歌曲权重快照）：
  /// 失效行缓存、刷新收藏/元数据版本，喜欢页与列表行即时反映远端结果。
  void notifyPlayMetaChanged() {
    weight.notifyExternalWrite();
    _favoriteVersion++;
    _metaVersion++;
    notifyListeners();
  }

  Future<void> _pumpUnread() async {
    try {
      for (final s in _sources) {
        if (!s.supportsDirect) continue;
        var afterId = 0;
        while (true) {
          final skipRef = _playingSourceKey == s.key ? _playingRef : null;
          perfPhase('direct.pumpUnread.query:${s.key}'); // TEMP-PROBE
          final unread = index.unreadSongs(s.key, 100,
              excludeRef: skipRef, afterId: afterId > 0 ? afterId : null);
          if (unread.isEmpty) break;
          perfLog('direct.pumpUnread.batch',
              'src=${s.key} n=${unread.length} afterId=$afterId'); // TEMP-PROBE
          var enriched = 0;
          // 分片提交：每 [kEnrichSubmitChunk] 首让出事件循环一次（FR-001/T007），
          // 保证「游标推进 + 入队」的同步块 ≪ 50ms。游标仍逐首前进。
          await runChunked(
            length: unread.length,
            chunkSize: kEnrichSubmitChunk,
            process: (i) {
              final song = unread[i];
              // 游标始终前进：不可解析/失败的歌本轮跳过，下次播放再重试。
              if (song.id > afterId) afterId = song.id;
              _submitBackgroundSong(s, song, onEnriched: () => enriched++);
            },
          );
          // 等这批真正跑完再取下一批：保持游标语义，也避免一次性排几百个任务。
          perfPhase('direct.pumpUnread.idle:${s.key}'); // TEMP-PROBE
          await tasks.idle();
          // 交互期（滚动/过渡）暂停推进下一批，交互结束后补跑（T015，幂等）。
          await _awaitInteractionIdle();
          // 每批通知一次（不是每首一次）：一批 100 首逐首通知会让整库页重建 100 次。
          if (enriched > 0) {
            _metaVersion++;
            notifyListeners();
          }
        }
        perfPhase('direct.pumpUnread.reconcile:${s.key}'); // TEMP-PROBE
        _reconcileArtists();
      }
    } finally {
      _enrichRunning = false;
    }
  }

  void _submitBackgroundSong(MusicSource src, Song song,
      {required void Function() onEnriched}) {
    // 正在播放的那首由播放链路自己重读（还排在最高优先级），这里不重复排。
    if (song.sourceKey == _playingSourceKey && song.sourceRef == _playingRef) {
      return;
    }
    tasks.submit(DirectTaskPriority.background,
        key: 'background/${song.sourceKey}\u0000${song.sourceRef}',
        body: () async {
      try {
        await enrichSongMeta(index, src, song);
      } catch (_) {
        return; // 单首失败跳过，不标已读。
      }
      onEnriched();
    });
  }
}

/// SFTP 三件套内存镜像（密码/私钥文本/passphrase；持久化在 [SecretStore]）。
class _SftpSecrets {
  String password;
  String keyPem;
  String passphrase;
  _SftpSecrets({this.password = '', this.keyPem = '', this.passphrase = ''});
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
