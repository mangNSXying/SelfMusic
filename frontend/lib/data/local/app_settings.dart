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
/// - 缓存来源模式 `cache_config_mode`（custom / follow_server）与自定义上限；
/// - 收藏自动缓存；播放页权重信息显示；忽略音频过滤；仅 Wi-Fi 扫描；
/// - 默认播放模式、断点续播开关（对应 DESIGN §6.7）；
/// - 服务端分区网络（settings.md §3.3）：`allow_insecure_http`（默认关，显式 http 才允许）、
///   `allow_self_signed`（默认关，dio/WebDAV 信任自签名 TLS）。
class AppSettings {
  static const String kCacheMaxBytes = 'cache_max_bytes';
  static const String kCacheSongLimit = 'cache_song_limit';

  /// 缓存来源模式（阶段6，settings.md §3.3）：custom=本地自定义；
  /// follow_server=采纳服务端建议值（GET /admin/config 下发）。
  static const String kCacheConfigMode = 'cache_config_mode';

  /// 服务端建议值本地镜像（不进 knownKeys，不随设置导出；进入分区/点同步时刷新）。
  static const String kCacheServerMaxBytes = 'cache_server_max_bytes';
  static const String kCacheServerSongLimit = 'cache_server_song_limit';
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

  /// wav/aiff 尾块 `id3 ` 标签补读是否已回填过（一次性，本机标记）。
  static const String kRiffTailMetaV1Done = 'riff_tail_meta_v1_done';

  /// 存量封面缩略图是否已补齐（一次性，本机标记）：老版本只存全尺寸原图，
  /// 列表解码大图是滑动卡顿来源；补齐后新增封面走补读即时生成，无需再扫。
  static const String kCoverThumbsV1Done = 'cover_thumbs_v1_done';

  /// 存量补推已执行的配对 client_id（设备本地标记，不进 [knownKeys]）：
  static const String kPlayModeDefault = 'play_mode_default';
  static const String kResumeOnStartup = 'resume_on_startup';
  static const String kPlayerShowWeight = 'player_show_weight';
  static const String kPlayerGestureSwipe = 'player_gesture_swipe';
  static const String kSleepPlayThroughDefault = 'sleep_play_through_default';
  static const String kSleepDefaultDurationMinutes =
      'sleep_default_duration_minutes';
  static const String kSleepDefaultCount = 'sleep_default_count';

  /// 播放页控件静置自动隐藏（改进.txt：无操作 N 秒后隐藏返回/更多按钮）。
  static const String kPlayerAutoHideIdleSec = 'player_auto_hide_idle_sec';
  static const String kPreloadNext = 'preload_next';
  static const String kScanIgnoreMinDurationSec = 'scan_ignore_min_duration_sec';
  static const String kScanIgnoreMinSizeBytes = 'scan_ignore_min_size_bytes';
  static const String kScanWifiOnly = 'scan_wifi_only';
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

  /// 时长削弱（改进.txt 功能8）：加权抽样时按歌曲时长乘以分段削弱系数。
  static const String kCurveWeightEnabled = 'curve_weight_enabled';
  static const String kCurveWeightSegments = 'curve_weight_segments';

  /// 集合页展示形式（列表/卡片）：歌单 / 播放源 / 专辑 / 歌手。
  static const String kViewModePlaylists = 'view_mode_playlists';
  static const String kViewModeSources = 'view_mode_sources';
  static const String kViewModeAlbums = 'view_mode_albums';
  static const String kViewModeArtists = 'view_mode_artists';

  /// 内容页排序（按页持久化）：默认 / 字符升降 / 权重升降（权重仅歌曲类）。
  static const String kSortSongs = 'sort_songs';
  static const String kSortFavorites = 'sort_favorites';
  static const String kSortPlaylistDetail = 'sort_playlist_detail';
  static const String kSortQueue = 'sort_queue';
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

  /// 歌手自动后台解析（歌手处理.txt）：向 MusicBrainz 搜索请求解析身份。
  static const String kArtistResolveAuto = 'artist_resolve_auto';

  /// 默认缓存总上限（512 MB）。
  static const int defaultCacheMaxBytes = 512 * 1024 * 1024;
  static const int defaultCacheSongLimit = 200;

  static const String defaultPlayMode = 'sequence';

  /// 歌词追焦等待可选秒数。
  static const List<int> lyricFocusIdleOptions = [2, 3, 5, 10, 15, 30];

  /// 播放页控件静置自动隐藏可选秒数（0=不隐藏）。
  static const List<int> playerAutoHideIdleOptions = [0, 3, 5, 10, 15, 30];

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

  // ---------- 缓存来源模式（阶段6 follow_server，settings.md §3.3） ----------

  /// custom=用本地自定义值；follow_server=用服务端建议值。
  String get cacheConfigMode =>
      index.settingsGet(kCacheConfigMode) ?? 'custom';
  set cacheConfigMode(String v) =>
      index.settingsSet(kCacheConfigMode, v);

  bool get followServer => cacheConfigMode == 'follow_server';

  int? get serverCacheMaxBytes =>
      int.tryParse(index.settingsGet(kCacheServerMaxBytes) ?? '');
  set serverCacheMaxBytes(int? v) {
    if (v == null) return;
    index.settingsSet(kCacheServerMaxBytes, v.toString());
  }

  int? get serverCacheSongLimit =>
      int.tryParse(index.settingsGet(kCacheServerSongLimit) ?? '');
  set serverCacheSongLimit(int? v) {
    if (v == null) return;
    index.settingsSet(kCacheServerSongLimit, v.toString());
  }

  /// 生效值：follow_server 且有服务端镜像时用服务端值，否则回退本地自定义。
  int get effectiveCacheMaxBytes {
    if (followServer) {
      final s = serverCacheMaxBytes;
      if (s != null && s > 0) return s;
    }
    return cacheMaxBytes;
  }

  int get effectiveCacheSongLimit {
    if (followServer) {
      final s = serverCacheSongLimit;
      if (s != null && s >= 0) return s;
    }
    return cacheSongLimit;
  }

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

  bool get riffTailMetaV1Done =>
      (index.settingsGet(kRiffTailMetaV1Done) ?? '0') == '1';
  set riffTailMetaV1Done(bool v) =>
      index.settingsSet(kRiffTailMetaV1Done, v ? '1' : '0');

  /// 存量封面缩略图补齐标记（一次性，本机）；见 direct_source_manager.init。
  bool get coverThumbsV1Done =>
      (index.settingsGet(kCoverThumbsV1Done) ?? '0') == '1';
  set coverThumbsV1Done(bool v) =>
      index.settingsSet(kCoverThumbsV1Done, v ? '1' : '0');

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

  /// 睡眠定时弹窗「指定时长」模式的默认分钟数与「指定曲数」模式的默认首数
  /// （已在弹窗内调整过则记忆上次值，下次打开预选）。
  int get sleepDefaultDurationMinutes =>
      int.tryParse(index.settingsGet(kSleepDefaultDurationMinutes) ?? '') ?? 30;
  set sleepDefaultDurationMinutes(int v) =>
      index.settingsSet(kSleepDefaultDurationMinutes, v.toString());
  int get sleepDefaultCount =>
      int.tryParse(index.settingsGet(kSleepDefaultCount) ?? '') ?? 3;
  set sleepDefaultCount(int v) =>
      index.settingsSet(kSleepDefaultCount, v.toString());

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

  /// 播放页控件静置自动隐藏（默认 5 秒；0=不隐藏）：无操作 N 秒后隐藏
  /// 左上返回箭头与右上「更多」按钮，触摸即恢复。
  int get playerAutoHideIdleSec =>
      int.tryParse(index.settingsGet(kPlayerAutoHideIdleSec) ?? '') ?? 5;
  set playerAutoHideIdleSec(int v) =>
      index.settingsSet(kPlayerAutoHideIdleSec, v.toString());

  /// 常亮限定的蓝牙设备 JSON（空=不限定）。
  String get keepScreenOnDevice =>
      index.settingsGet(kKeepScreenOnDevice) ?? '';
  set keepScreenOnDevice(String v) =>
      index.settingsSet(kKeepScreenOnDevice, v);

  // ---------- 无状态转码（阶段6，服务端代理，不建库） ----------

  /// 转码总开关（默认关）：开 + 服务端 ffmpeg 可用时，WebDAV 播放走
  /// GET /transcode/stream?origin=..&bitrate=..，失败回落直连原文件。
  static const String kTranscodeEnabled = 'transcode_enabled';

  /// 转码码率（kbps，仅 192/256/320，默认 192；MP3 无 512 档，不开放）。
  static const String kTranscodeBitrate = 'transcode_bitrate';

  bool get transcodeEnabled =>
      (index.settingsGet(kTranscodeEnabled) ?? '0') == '1';
  set transcodeEnabled(bool v) =>
      index.settingsSet(kTranscodeEnabled, v ? '1' : '0');

  int get transcodeBitrate {
    final v = int.tryParse(index.settingsGet(kTranscodeBitrate) ?? '') ?? 192;
    if (v == 192 || v == 256 || v == 320) return v;
    return 192;
  }

  set transcodeBitrate(int v) =>
      index.settingsSet(kTranscodeBitrate, v.toString());

  // ---------- 歌手身份解析（歌手处理.txt） ----------

  bool get artistResolveAuto =>
      (index.settingsGet(kArtistResolveAuto) ?? '1') == '1';
  set artistResolveAuto(bool v) =>
      index.settingsSet(kArtistResolveAuto, v ? '1' : '0');

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

  /// 周期自动扫描间隔（分钟）。0=关。增量指纹使其成本极低（无变化的文件零下载），
  /// 相当于「目录变化检测」；本地源另有 FileSystem watcher 即时触发。
  int get scanAutoIntervalMin =>
      int.tryParse(index.settingsGet(kScanAutoIntervalMin) ?? '') ?? 0;
  set scanAutoIntervalMin(int v) =>
      index.settingsSet(kScanAutoIntervalMin, v.toString());

  // ---------- 播放分区·淡入淡出（settings.md §3.2） ----------

  bool get fadeEnabled => (index.settingsGet(kFadeEnabled) ?? '1') == '1';
  set fadeEnabled(bool v) => index.settingsSet(kFadeEnabled, v ? '1' : '0');

  /// 淡入淡出时长（ms）。有效域 [500, 2000]，默认 2000；越界的历史存储值
  /// （如旧版 1~3 s 档位写的 3000）在读取时钳制到最近边界，不迁移存储，
  /// 用户下次拖动滑条即写回合法值。
  int get fadeDurationMs =>
      (int.tryParse(index.settingsGet(kFadeDurationMs) ?? '') ?? 2000)
          .clamp(500, 2000);
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

  // ---------- 播放分区·时长削弱（改进.txt 功能8） ----------

  /// 时长削弱总开关（默认关）。开启且配置了分段时，加权抽样按歌曲时长乘系数。
  bool get weightCurveEnabled =>
      (index.settingsGet(kCurveWeightEnabled) ?? '0') == '1';
  set weightCurveEnabled(bool v) =>
      index.settingsSet(kCurveWeightEnabled, v ? '1' : '0');

  /// 时长-权重分段函数（默认空=不削弱）。条目 `{min_sec, max_sec|null, factor}`，
  /// 作用域为 [min_sec, max_sec)（max_sec 为空=时长 ≥ min_sec 起恒生效，可作「超过
  /// 设定值」的开启要点）；区间不重叠，命中第一段即止，未命中返回 1.0（不削弱）。
  /// 非法/空数据回退空列表。
  List<Map<String, Object?>> get weightCurveSegments {
    final raw = index.settingsGet(kCurveWeightSegments);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final l = jsonDecode(raw) as List;
      return [
        for (final e in l)
          if (e is Map)
            Map<String, Object?>.from(e)
                .cast<String, Object?>()
                .map((k, v) => MapEntry(k, v)),
      ];
    } catch (_) {
      return const [];
    }
  }

  set weightCurveSegments(List<Map<String, Object?>> v) {
    index.settingsSet(kCurveWeightSegments, jsonEncode(v));
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

  CollectionSort get sortQueue => _sort(kSortQueue);
  set sortQueue(CollectionSort v) => _setSort(kSortQueue, v);

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
    kCacheConfigMode,
    kTranscodeEnabled,
    kTranscodeBitrate,
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
    kSleepDefaultDurationMinutes,
    kSleepDefaultCount,
    kPlayerAutoHideIdleSec,
    kPreloadNext,
    kLyricFocusIdleSec,
    kPlayerKeepScreenOn,
    kKeepScreenOnDevice,
    kArtistResolveAuto,
    kScanIgnoreMinDurationSec,
    kScanIgnoreMinSizeBytes,
    kScanWifiOnly,
    kScanAutoIntervalMin,
    kFadeEnabled,
    kFadeDurationMs,
    kEqualizerEnabled,
    kEqBands,
    kCurveWeightEnabled,
    kCurveWeightSegments,
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
    kSortQueue,
    kSortAlbums,
    kSortArtists,
    kSortPlaylists,
    kSortSources,
  ];
}