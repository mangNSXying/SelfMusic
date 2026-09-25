import 'dart:convert';

import '../../utils/collection_sort.dart';
import 'local_index.dart';

/// 播放页（播放/歌词）切换过渡动画。
enum PlayerTransition {
  none('关闭'),
  fade('淡入'),
  slide('滑动'),
  scale('缩放');

  const PlayerTransition(this.label);
  final String label;

  static PlayerTransition parse(String? v) => PlayerTransition.values
      .firstWhere((e) => e.name == v, orElse: () => PlayerTransition.fade);
}

/// 歌曲标题显示格式（设置→歌曲，默认「歌手 - 歌名」）。
enum SongTitleFormat {
  fileName('文件名'),
  titleOnly('歌名'),
  artistTitle('歌手 - 歌名'),
  titleArtist('歌名 - 歌手');

  const SongTitleFormat(this.label);
  final String label;

  static SongTitleFormat parse(String? v) => SongTitleFormat.values
      .firstWhere((e) => e.name == v, orElse: () => SongTitleFormat.artistTitle);
}

/// 集合页（歌单/播放源/专辑/歌手）展示形式。
enum CollectionViewMode {
  list('列表', 'list'),
  card('卡片', 'card');

  const CollectionViewMode(this.label, this.storeValue);
  final String label;
  final String storeValue;

  static CollectionViewMode parse(String? v) =>
      v == card.storeValue ? card : list;
}

/// 客户端用户设置（直连模式 app_settings 表；settings.md §3）。
///
/// 已实现（settings.md §3.2/§3.3/§3.4）：
/// - 缓存来源模式 `cache_config_mode`（custom / follow_server，后者暂灰显）与自定义上限；
/// - 收藏自动缓存；播放页权重信息显示；忽略音频过滤；仅 Wi-Fi 扫描；
/// - 默认播放模式、断点续播开关（对应 DESIGN §6.7）；
/// - 服务端分区网络（settings.md §3.3）：`allow_insecure_http`（默认关，显式 http 才允许）、
///   `allow_self_signed`（默认关，dio/WebDAV 信任自签名 TLS）。
class AppSettings {
  static const String kCacheMaxBytes = 'cache_max_bytes';
  static const String kCacheSongLimit = 'cache_song_limit';
  static const String kAutoCacheFavorites = 'auto_cache_favorites';

  /// 允许不安全 HTTP（settings.md §3.3 服务端）：关（默认）时显式 `http://` 地址一律拒绝。
  static const String kAllowInsecureHttp = 'allow_insecure_http';

  /// 信任自签名证书（settings.md §3.3 服务端）：覆盖 dio API 与直连 WebDAV（dart:io）；
  /// 播放器层（ExoPlayer/mpv）不受此开关影响，仍要求 CA 有效证书。
  static const String kAllowSelfSigned = 'allow_self_signed';

  /// 多设备状态同步（阶段5，DESIGN §7.2）：服务端 cursor（pull 的 since_cursor 基准）。
  static const String kSyncCursor = 'sync_cursor';

  /// 多设备状态同步总开关（关=仅本地，直连模式同样跳过）。
  static const String kSyncEnabled = 'sync_enabled';

  /// 上次同步成功时间（ISO-8601，服务端分区展示用）。
  static const String kLastSyncAt = 'last_sync_at';

  /// 大封面回填补读是否已执行（设备本地一次性迁移标记）。
  /// 刻意不进 [knownKeys]：它与本机索引数据绑定，不随设置导出/导入。
  static const String kCoverReenrichV1Done = 'cover_reenrich_v1_done';

  /// 元数据回填补读是否已执行（块序异常歌曲重读，设备本地一次性迁移标记）。
  /// 同上不进 [knownKeys]。
  static const String kMetaReenrichV2Done = 'meta_reenrich_v2_done';

  /// 存量补推已执行的配对 client_id（设备本地标记，不进 [knownKeys]）：
  /// 同一配对只自动补推一次；换账号重配（client_id 变化）则重新补推。
  static const String kBackfillClientId = 'backfill_client_id';
  static const String kPlayModeDefault = 'play_mode_default';
  static const String kResumeOnStartup = 'resume_on_startup';
  static const String kPlayerShowWeight = 'player_show_weight';
  static const String kPlayerGestureSwipe = 'player_gesture_swipe';
  static const String kSleepPlayThroughDefault = 'sleep_play_through_default';
  static const String kPreloadNext = 'preload_next';
  static const String kScanIgnoreMinDurationSec = 'scan_ignore_min_duration_sec';
  static const String kScanIgnoreMinSizeBytes = 'scan_ignore_min_size_bytes';
  static const String kScanWifiOnly = 'scan_wifi_only';
  static const String kScanMode = 'scan_mode';
  static const String kScanHeadBytes = 'scan_head_bytes';
  static const String kScanEmbedCover = 'scan_embed_cover';
  static const String kScanAutoIntervalMin = 'scan_auto_interval_min';

  /// 淡入淡出（settings.md §3.2）：开/关与时长（ms）。
  static const String kFadeEnabled = 'fade_enabled';
  static const String kFadeDurationMs = 'fade_duration_ms';

  /// 均衡器（settings.md §3.2）：仅 Android（just_audio 原生 AndroidEqualizer）。
  static const String kEqualizerEnabled = 'equalizer_enabled';
  static const String kEqBands = 'eq_bands';

  /// 音频焦点（settings.md §3.6）：Android 来电/他应用抢占时自动暂停-恢复。
  static const String kAudioFocusEnabled = 'audio_focus_enabled';

  /// 通知栏播放控制（settings.md §3.6）：Android 通知栏/后台播放。
  static const String kNotificationControls = 'notification_controls';

  /// 播放页切换过渡动画（settings.md §3.7 界面）：none / fade / slide / scale。
  static const String kPlayerTransition = 'player_transition';

  /// 歌曲标题显示格式（settings.md §3.4 歌曲）：默认 song.artist - song.title。
  static const String kSongTitleFormat = 'song_title_format';

  /// 集合页展示形式（列表/卡片）：歌单 / 播放源 / 专辑 / 歌手。
  static const String kViewModePlaylists = 'view_mode_playlists';
  static const String kViewModeSources = 'view_mode_sources';
  static const String kViewModeAlbums = 'view_mode_albums';
  static const String kViewModeArtists = 'view_mode_artists';

  /// 内容页排序（按页持久化）：默认 / 字符升降 / 权重升降（权重仅歌曲类）。
  static const String kSortSongs = 'sort_songs';
  static const String kSortFavorites = 'sort_favorites';
  static const String kSortPlaylistDetail = 'sort_playlist_detail';
  static const String kSortAlbums = 'sort_albums';
  static const String kSortArtists = 'sort_artists';
  static const String kSortPlaylists = 'sort_playlists';
  static const String kSortSources = 'sort_sources';

  /// 歌词追焦等待秒数（用户拖动歌词后多久恢复自动跟随；播放设置可调）。
  static const String kLyricFocusIdleSec = 'lyric_focus_idle_sec';

  /// 播放页屏幕常亮（打开播放页期间不熄屏）。
  static const String kPlayerKeepScreenOn = 'player_keep_screen_on';

  /// 常亮限定的蓝牙设备（JSON {name,address}；空=不限定，打开播放页即常亮）。
  static const String kKeepScreenOnDevice = 'keep_screen_on_device';

  /// 默认缓存总上限（512 MB）。
  static const int defaultCacheMaxBytes = 512 * 1024 * 1024;
  static const int defaultCacheSongLimit = 200;

  static const String defaultPlayMode = 'sequence';

  /// 歌词追焦等待可选秒数。
  static const List<int> lyricFocusIdleOptions = [2, 3, 5, 10, 15, 30];

  /// 均衡器默认频段增益（5 段，dB）。
  static const List<double> defaultEqBands = [0, 0, 0, 0, 0];

  final LocalIndex index;
  AppSettings(this.index);

  // ---------- 缓存（settings.md §3.3） ----------

  int get cacheMaxBytes =>
      int.tryParse(index.settingsGet(kCacheMaxBytes) ?? '') ??
      defaultCacheMaxBytes;
  set cacheMaxBytes(int v) => index.settingsSet(kCacheMaxBytes, v.toString());

  int get cacheSongLimit =>
      int.tryParse(index.settingsGet(kCacheSongLimit) ?? '') ??
      defaultCacheSongLimit;
  set cacheSongLimit(int v) => index.settingsSet(kCacheSongLimit, v.toString());

  // ---------- 服务端分区·网络（settings.md §3.3） ----------

  /// 允许不安全 HTTP：关（默认）时显式 `http://` 地址被拒绝；缺 scheme 恒默认 https，
  /// 不受此开关影响。
  bool get allowInsecureHttp =>
      (index.settingsGet(kAllowInsecureHttp) ?? '0') == '1';
  set allowInsecureHttp(bool v) =>
      index.settingsSet(kAllowInsecureHttp, v ? '1' : '0');

  /// 信任自签名证书：dio API 与直连 WebDAV（dart:io）跳过证书校验；播放器层不受影响。
  bool get allowSelfSigned =>
      (index.settingsGet(kAllowSelfSigned) ?? '0') == '1';
  set allowSelfSigned(bool v) =>
      index.settingsSet(kAllowSelfSigned, v ? '1' : '0');

  // ---------- 多设备状态同步（阶段5，DESIGN §7.2） ----------

  /// 服务端 cursor：pull 增量基准，SyncEngine 每次成功后推进。
  int get syncCursor => int.tryParse(index.settingsGet(kSyncCursor) ?? '0') ?? 0;
  set syncCursor(int v) => index.settingsSet(kSyncCursor, v.toString());

  /// 同步总开关（默认开；关=仅本地，不上推也不拉取）。
  bool get syncEnabled => (index.settingsGet(kSyncEnabled) ?? '1') == '1';
  set syncEnabled(bool v) => index.settingsSet(kSyncEnabled, v ? '1' : '0');

  /// 上次同步成功时间（ISO-8601，空=从未成功）。
  String get lastSyncAt => index.settingsGet(kLastSyncAt) ?? '';
  set lastSyncAt(String v) => index.settingsSet(kLastSyncAt, v);

  // ---------- 设备本地一次性迁移标记（不进 knownKeys） ----------

  /// 大内嵌封面回填补读标记：旧版封面读取受头部采样截断，见 direct_source_manager.init。
  bool get coverReenrichV1Done =>
      (index.settingsGet(kCoverReenrichV1Done) ?? '0') == '1';
  set coverReenrichV1Done(bool v) =>
      index.settingsSet(kCoverReenrichV1Done, v ? '1' : '0');

  /// 元数据回填补读标记：旧版解析在块序异常（PICTURE 在 VORBIS_COMMENT 之前等）
  /// 的文件上会提前中断、读不出歌手，见 direct_source_manager.init。
  bool get metaReenrichV2Done =>
      (index.settingsGet(kMetaReenrichV2Done) ?? '0') == '1';
  set metaReenrichV2Done(bool v) =>
      index.settingsSet(kMetaReenrichV2Done, v ? '1' : '0');

  /// 存量补推已执行的配对 client_id（空=未执行过）。
  String get backfillClientId => index.settingsGet(kBackfillClientId) ?? '';
  set backfillClientId(String v) =>
      index.settingsSet(kBackfillClientId, v);

  // ---------- 收藏自动缓存（settings.md §3.4 歌曲分区） ----------

  bool get autoCacheFavorites =>
      (index.settingsGet(kAutoCacheFavorites) ?? '1') == '1';
  set autoCacheFavorites(bool v) =>
      index.settingsSet(kAutoCacheFavorites, v ? '1' : '0');

  // ---------- 播放分区（settings.md §3.2） ----------

  /// 默认播放模式（sequence / loopList / loopOne / weighted）。
  String get playModeDefault =>
      index.settingsGet(kPlayModeDefault) ?? defaultPlayMode;
  set playModeDefault(String v) =>
      index.settingsSet(kPlayModeDefault, v);

  /// 断点续播开关：启动时是否恢复上次队列与位置（恢复为暂停态）。
  bool get resumeOnStartup =>
      (index.settingsGet(kResumeOnStartup) ?? '1') == '1';
  set resumeOnStartup(bool v) =>
      index.settingsSet(kResumeOnStartup, v ? '1' : '0');

  /// 播放页左右滑动手势：左滑返回列表、右滑查看歌词（默认开）。
  bool get playerGestureSwipe =>
      (index.settingsGet(kPlayerGestureSwipe) ?? '1') == '1';
  set playerGestureSwipe(bool v) =>
      index.settingsSet(kPlayerGestureSwipe, v ? '1' : '0');

  /// 睡眠定时弹窗中「播放完最后的曲目」开关的默认值（默认开）。
  bool get sleepPlayThroughDefault =>
      (index.settingsGet(kSleepPlayThroughDefault) ?? '1') == '1';
  set sleepPlayThroughDefault(bool v) =>
      index.settingsSet(kSleepPlayThroughDefault, v ? '1' : '0');

  /// 预载下一首（默认开）：播放某首歌时按播放顺序算法确定下一首并后台缓存
  /// （加权随机也先抽样确定，切歌时复用同一结果），开关只决定是否预载。
  bool get preloadNext => (index.settingsGet(kPreloadNext) ?? '1') == '1';
  set preloadNext(bool v) => index.settingsSet(kPreloadNext, v ? '1' : '0');

  /// 歌词追焦等待秒数：用户拖动歌词后多久恢复自动追焦（默认 5 秒）。
  int get lyricFocusIdleSec =>
      int.tryParse(index.settingsGet(kLyricFocusIdleSec) ?? '') ?? 5;
  set lyricFocusIdleSec(int v) =>
      index.settingsSet(kLyricFocusIdleSec, v.toString());

  /// 播放页屏幕常亮：打开播放页期间不熄屏（默认关）。
  bool get playerKeepScreenOn =>
      (index.settingsGet(kPlayerKeepScreenOn) ?? '0') == '1';
  set playerKeepScreenOn(bool v) =>
      index.settingsSet(kPlayerKeepScreenOn, v ? '1' : '0');

  /// 常亮限定的蓝牙设备 JSON（空=不限定）。
  String get keepScreenOnDevice =>
      index.settingsGet(kKeepScreenOnDevice) ?? '';
  set keepScreenOnDevice(String v) =>
      index.settingsSet(kKeepScreenOnDevice, v);

  // ---------- 歌曲分区（settings.md §3.4） ----------

  bool get playerShowWeight =>
      (index.settingsGet(kPlayerShowWeight) ?? '1') == '1';
  set playerShowWeight(bool v) =>
      index.settingsSet(kPlayerShowWeight, v ? '1' : '0');

  /// 忽略音频（时长过滤）：0=关；>0 秒，扫描时过滤更短的音频文件。
  int get scanIgnoreMinDurationSec =>
      int.tryParse(index.settingsGet(kScanIgnoreMinDurationSec) ?? '') ?? 0;
  set scanIgnoreMinDurationSec(int v) =>
      index.settingsSet(kScanIgnoreMinDurationSec, v.toString());

  /// 忽略音频（大小过滤）：0=关；>0 字节，扫描时过滤更小的音频文件。
  int get scanIgnoreMinSizeBytes =>
      int.tryParse(index.settingsGet(kScanIgnoreMinSizeBytes) ?? '') ?? 0;
  set scanIgnoreMinSizeBytes(int v) =>
      index.settingsSet(kScanIgnoreMinSizeBytes, v.toString());

  /// 仅 Wi-Fi 扫描（移动端生效，桌面忽略）。（settings.md §3.4）
  bool get scanWifiOnly => (index.settingsGet(kScanWifiOnly) ?? '1') == '1';
  set scanWifiOnly(bool v) =>
      index.settingsSet(kScanWifiOnly, v ? '1' : '0');

  /// 扫描元数据深度（settings.md §3.4）：minimal（只读标题/歌手/专辑，默认）/
  /// full（含时长/曲目/年份/流派/封面）/ fast（仅文件名，零读头请求）。
  String get scanMode => index.settingsGet(kScanMode) ?? 'fast';
  set scanMode(String v) => index.settingsSet(kScanMode, v);

  bool get scanModeFull => scanMode == 'full';
  bool get scanModeFast => scanMode == 'fast';

  /// 扫描头部采样上限（字节）。默认 64KB：足够标题/歌手/专辑，且是旧 256KB 的 1/4。
  int get scanHeadBytes =>
      int.tryParse(index.settingsGet(kScanHeadBytes) ?? '') ?? 64 * 1024;
  set scanHeadBytes(int v) => index.settingsSet(kScanHeadBytes, v.toString());

  /// full 模式下是否提取并落盘嵌入封面。
  bool get scanEmbedCover =>
      (index.settingsGet(kScanEmbedCover) ?? '1') == '1';
  set scanEmbedCover(bool v) =>
      index.settingsSet(kScanEmbedCover, v ? '1' : '0');

  /// 周期自动扫描间隔（分钟）。0=关。增量指纹使其成本极低（无变化的文件零下载），
  /// 相当于「目录变化检测」；本地源另有 FileSystem watcher 即时触发。
  int get scanAutoIntervalMin =>
      int.tryParse(index.settingsGet(kScanAutoIntervalMin) ?? '') ?? 0;
  set scanAutoIntervalMin(int v) =>
      index.settingsSet(kScanAutoIntervalMin, v.toString());

  // ---------- 播放分区·淡入淡出（settings.md §3.2） ----------

  bool get fadeEnabled => (index.settingsGet(kFadeEnabled) ?? '1') == '1';
  set fadeEnabled(bool v) => index.settingsSet(kFadeEnabled, v ? '1' : '0');

  /// 淡入淡出时长（ms，建议 1000~3000）。
  int get fadeDurationMs =>
      int.tryParse(index.settingsGet(kFadeDurationMs) ?? '') ?? 2000;
  set fadeDurationMs(int v) =>
      index.settingsSet(kFadeDurationMs, v.toString());

  // ---------- 播放分区·均衡器（settings.md §3.2，仅 Android） ----------

  bool get equalizerEnabled =>
      (index.settingsGet(kEqualizerEnabled) ?? '0') == '1';
  set equalizerEnabled(bool v) =>
      index.settingsSet(kEqualizerEnabled, v ? '1' : '0');

  /// 5 段频段增益（dB）。非法/缺省回退全 0。
  List<double> get eqBands {
    final raw = index.settingsGet(kEqBands);
    if (raw == null || raw.isEmpty) return List.of(defaultEqBands);
    try {
      final l = jsonDecode(raw) as List;
      if (l.length != 5) return List.of(defaultEqBands);
      return l.map((e) => (e as num).toDouble()).toList();
    } catch (_) {
      return List.of(defaultEqBands);
    }
  }

  set eqBands(List<double> v) {
    final norm = (v.length == 5)
        ? v.map((e) => e.toDouble()).toList()
        : List.of(defaultEqBands);
    index.settingsSet(kEqBands, jsonEncode(norm.map((e) => e.round())));
  }

  // ---------- 界面分区（settings.md §3.7） ----------

  /// 播放页（播放/歌词）切换过渡动画（默认淡入）。
  PlayerTransition get playerTransition =>
      PlayerTransition.parse(index.settingsGet(kPlayerTransition));
  set playerTransition(PlayerTransition v) =>
      index.settingsSet(kPlayerTransition, v.name);

  /// 歌曲标题显示格式（默认「歌手 - 歌名」）。
  SongTitleFormat get songTitleFormat =>
      SongTitleFormat.parse(index.settingsGet(kSongTitleFormat));
  set songTitleFormat(SongTitleFormat v) =>
      index.settingsSet(kSongTitleFormat, v.name);

  CollectionViewMode _viewMode(String key, CollectionViewMode fallback) {
    final raw = index.settingsGet(key);
    if (raw == null) return fallback;
    return CollectionViewMode.parse(raw);
  }

  /// 各集合页展示形式（默认：歌单=列表，播放源/专辑/歌手=卡片）。
  CollectionViewMode get viewModePlaylists =>
      _viewMode(kViewModePlaylists, CollectionViewMode.list);
  set viewModePlaylists(CollectionViewMode v) =>
      index.settingsSet(kViewModePlaylists, v.storeValue);

  CollectionViewMode get viewModeSources =>
      _viewMode(kViewModeSources, CollectionViewMode.card);
  set viewModeSources(CollectionViewMode v) =>
      index.settingsSet(kViewModeSources, v.storeValue);

  CollectionViewMode get viewModeAlbums =>
      _viewMode(kViewModeAlbums, CollectionViewMode.card);
  set viewModeAlbums(CollectionViewMode v) =>
      index.settingsSet(kViewModeAlbums, v.storeValue);

  CollectionViewMode get viewModeArtists =>
      _viewMode(kViewModeArtists, CollectionViewMode.card);
  set viewModeArtists(CollectionViewMode v) =>
      index.settingsSet(kViewModeArtists, v.storeValue);

  // ---------- 内容页排序（按页持久化） ----------

  CollectionSort _sort(String key) =>
      CollectionSortX.parse(index.settingsGet(key));
  void _setSort(String key, CollectionSort v) =>
      index.settingsSet(key, v.name);

  CollectionSort get sortSongs => _sort(kSortSongs);
  set sortSongs(CollectionSort v) => _setSort(kSortSongs, v);

  CollectionSort get sortFavorites => _sort(kSortFavorites);
  set sortFavorites(CollectionSort v) => _setSort(kSortFavorites, v);

  CollectionSort get sortPlaylistDetail => _sort(kSortPlaylistDetail);
  set sortPlaylistDetail(CollectionSort v) =>
      _setSort(kSortPlaylistDetail, v);

  CollectionSort get sortAlbums => _sort(kSortAlbums);
  set sortAlbums(CollectionSort v) => _setSort(kSortAlbums, v);

  CollectionSort get sortArtists => _sort(kSortArtists);
  set sortArtists(CollectionSort v) => _setSort(kSortArtists, v);

  CollectionSort get sortPlaylists => _sort(kSortPlaylists);
  set sortPlaylists(CollectionSort v) => _setSort(kSortPlaylists, v);

  CollectionSort get sortSources => _sort(kSortSources);
  set sortSources(CollectionSort v) => _setSort(kSortSources, v);

  // ---------- 通知分区（settings.md §3.6） ----------

  bool get audioFocusEnabled =>
      (index.settingsGet(kAudioFocusEnabled) ?? '1') == '1';
  set audioFocusEnabled(bool v) =>
      index.settingsSet(kAudioFocusEnabled, v ? '1' : '0');

  bool get notificationControls =>
      (index.settingsGet(kNotificationControls) ?? '1') == '1';
  set notificationControls(bool v) =>
      index.settingsSet(kNotificationControls, v ? '1' : '0');

  /// 全部已知键（供设置导入导出筛选，settings.md §3.5）。
  static const List<String> knownKeys = [
    kCacheMaxBytes,
    kCacheSongLimit,
    kAutoCacheFavorites,
    kAllowInsecureHttp,
    kAllowSelfSigned,
    kSyncCursor,
    kSyncEnabled,
    kLastSyncAt,
    kPlayModeDefault,
    kResumeOnStartup,
    kPlayerShowWeight,
    kPlayerGestureSwipe,
    kSleepPlayThroughDefault,
    kPreloadNext,
    kLyricFocusIdleSec,
    kPlayerKeepScreenOn,
    kKeepScreenOnDevice,
    kScanIgnoreMinDurationSec,
    kScanIgnoreMinSizeBytes,
    kScanWifiOnly,
    kScanMode,
    kScanHeadBytes,
    kScanEmbedCover,
    kScanAutoIntervalMin,
    kFadeEnabled,
    kFadeDurationMs,
    kEqualizerEnabled,
    kEqBands,
    kAudioFocusEnabled,
    kNotificationControls,
    kPlayerTransition,
    kSongTitleFormat,
    kViewModePlaylists,
    kViewModeSources,
    kViewModeAlbums,
    kViewModeArtists,
    kSortSongs,
    kSortFavorites,
    kSortPlaylistDetail,
    kSortAlbums,
    kSortArtists,
    kSortPlaylists,
    kSortSources,
  ];
}