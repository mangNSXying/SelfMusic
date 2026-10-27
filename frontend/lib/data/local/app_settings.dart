import 'dart:convert';

import '../../utils/collection_sort.dart';
import '../../utils/song_groups.dart';
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

  static SongTitleFormat parse(String? v) =>
      SongTitleFormat.values.firstWhere((e) => e.name == v,
          orElse: () => SongTitleFormat.artistTitle);
}

/// 在线元数据保存位置（设置→歌曲）。
enum OnlineMetaSaveMode {
  /// 仅应用缓存：歌词写 `song_lyrics`，封面写 `covers/`（全源安全，默认）。
  appCache('仅应用缓存'),

  /// 同时写回源目录：DB 必写，额外覆盖写同目录 `<stem>.lrc`（自定义歌词
  /// 目录仅本地有效）与 `cover.jpg`（专辑级，同目录共享）；远端源经上传口
  /// 直写（不经服务端代理），不可写（服务端歌/鸿蒙本地/无路径）自动跳过。
  sidecar('同时写回源目录'),

  /// 内嵌到歌曲：DB 必写，保存后把歌词/封面自动写入音频文件标签
  /// （mp3/flac/wav/aiff/m4a），验签通过后删同名 sidecar；远端源需整首
  /// 下载＋上传。服务端歌/源不可写/格式不支持时自动退化为仅应用缓存。
  embed('内嵌到歌曲');

  const OnlineMetaSaveMode(this.label);
  final String label;

  static OnlineMetaSaveMode parse(String? v) =>
      OnlineMetaSaveMode.values.firstWhere((e) => e.name == v,
          orElse: () => OnlineMetaSaveMode.appCache);
}

/// 在线歌词来源（设置→歌曲，用户手动设定，无自动串源）。
enum OnlineMetaLyricSource {
  lrclib('LRCLIB'),
  qq('QQ音乐'),
  netease('网易云');

  const OnlineMetaLyricSource(this.label);
  final String label;

  static OnlineMetaLyricSource parse(String? v) =>
      OnlineMetaLyricSource.values.firstWhere((e) => e.name == v,
          orElse: () => OnlineMetaLyricSource.lrclib);
}

/// 在线封面来源（设置→歌曲，用户手动设定，无自动串源）。
enum OnlineMetaCoverSource {
  mbCaa('MB→CAA'),
  qq('QQ音乐'),
  netease('网易云');

  const OnlineMetaCoverSource(this.label);
  final String label;

  static OnlineMetaCoverSource parse(String? v) =>
      OnlineMetaCoverSource.values.firstWhere((e) => e.name == v,
          orElse: () => OnlineMetaCoverSource.mbCaa);
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

/// 加权随机「次数冷却」档位（设置→播放）：削峰补丁规则1。一首歌播放后，
/// 再次被抽中的前 N 次直接抛弃、第 N+1 次才作数；N 按权重分档——factor>1.0
/// 的歌用 [highLimit]，factor≤1.0 用 [lowLimit]。三档对应 0/0、1/2、2/3。
enum WeightedDrawCooldown {
  off('关', 0, 0),
  weak('弱', 1, 2),
  normal('正常', 2, 3);

  const WeightedDrawCooldown(this.label, this.highLimit, this.lowLimit);
  final String label;

  /// factor > 1.0 的歌曲应抛弃的连续抽中次数。
  final int highLimit;

  /// factor ≤ 1.0 的歌曲应抛弃的连续抽中次数。
  final int lowLimit;

  static WeightedDrawCooldown parse(String? v) =>
      WeightedDrawCooldown.values.firstWhere((e) => e.name == v,
          orElse: () => WeightedDrawCooldown.normal);

  /// 取 [factor] 对应的抛弃次数上限。
  int limitFor(double factor) => factor > 1.0 ? highLimit : lowLimit;
}

/// 客户端用户设置（直连模式 app_settings 表；settings.md §3）。
///
/// 已实现（settings.md §3.2/§3.3/§3.4）：
/// - 缓存来源模式 `cache_config_mode`（custom / follow_server）与自定义上限；
/// - 收藏自动缓存；播放页权重信息显示；忽略音频过滤；仅 Wi-Fi 扫描；
/// - 默认播放模式、断点续播开关（对应 DEVELOPER.md「数据模型」）；
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

  /// 多设备状态同步（阶段5，DEVELOPER.md「播放算法与同步协议」）：服务端 cursor（pull 的 since_cursor 基准）。
  static const String kSyncCursor = 'sync_cursor';

  /// 多设备状态同步总开关（关=仅本地，直连模式同样跳过）。
  static const String kSyncEnabled = 'sync_enabled';

  /// 上次同步成功时间（ISO-8601，服务端分区展示用）。
  static const String kLastSyncAt = 'last_sync_at';

  /// 大封面回填补读是否已执行（设备本地一次性迁移标记）。
  /// 刻意不进 [knownKeys]：它与本机索引数据绑定，不随设置导出/导入。
  static const String kCoverReenrichV1Done = 'cover_reenrich_v1_done';

  /// ID3v2.3 帧长回填补读是否已执行（设备本地一次性迁移标记）。
  /// 旧版帧长统一按 syncsafe 解，v2.3 大 APIC（如 BE=53178/syncsafe=10170）
  /// 会被截成半图丢弃、其后 USLT 也对不上，已标已读但无封面，需重置重读。
  /// 刻意不进 [knownKeys]，同 V1。
  static const String kCoverReenrichV2Done = 'cover_reenrich_v2_done';

  /// 元数据回填补读是否已执行（块序异常歌曲重读，设备本地一次性迁移标记）。
  /// 同上不进 [knownKeys]。
  static const String kMetaReenrichV2Done = 'meta_reenrich_v2_done';

  /// wav/aiff 尾块 `id3 ` 标签补读是否已回填过（一次性，本机标记）。
  static const String kRiffTailMetaV1Done = 'riff_tail_meta_v1_done';

  /// FLAC 前置 ID3v2 标签补读是否已回填过（一次性，本机标记）：旧版解析要求
  /// `fLaC` 在 offset 0，带前置 ID3v2 的文件（部分老工具写入）会读空、却已标已读。
  static const String kFlacId3PrefixMetaV1Done = 'flac_id3_prefix_meta_v1_done';

  /// 存量封面缩略图是否已补齐（一次性，本机标记）：老版本只存全尺寸原图，
  /// 列表解码大图是滑动卡顿来源；补齐后新增封面走补读即时生成，无需再扫。
  static const String kCoverThumbsV1Done = 'cover_thumbs_v1_done';

  /// 存量补推已执行的配对 client_id（设备本地标记，不进 [knownKeys]）：
  static const String kPlayModeDefault = 'play_mode_default';

  /// 随机播放模式下是否启用加权随机（默认开；关=普通随机/不放回）。
  static const String kWeightedRandomEnabled = 'weighted_random_enabled';
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
  static const String kScanIgnoreMinDurationSec =
      'scan_ignore_min_duration_sec';
  static const String kScanIgnoreMinSizeBytes = 'scan_ignore_min_size_bytes';
  static const String kScanWifiOnly = 'scan_wifi_only';
  static const String kScanAutoIntervalMin = 'scan_auto_interval_min';

  /// 淡入淡出（settings.md §3.2）：开/关与时长（ms）。
  static const String kFadeEnabled = 'fade_enabled';
  static const String kFadeDurationMs = 'fade_duration_ms';

  /// 应用内音量（settings.md §3.2）：0~100，独立于系统音量的软件增益。
  /// 设备本地偏好，不进 [knownKeys]，不随设置导出/导入。
  static const String kAppVolume = 'app_volume';

  /// 均衡器（settings.md §3.2）：仅 Android（just_audio 原生 AndroidEqualizer）。
  static const String kEqualizerEnabled = 'equalizer_enabled';
  static const String kEqBands = 'eq_bands';

  /// 音频焦点（settings.md §3.6）：Android 走 just_audio handleInterruptions，
  /// 鸿蒙走 AVPlayer audioInterrupt；来电/他应用抢占时自动暂停-恢复。
  static const String kAudioFocusEnabled = 'audio_focus_enabled';

  /// 静音暂停（Android/鸿蒙）：媒体音量归零时自动暂停。
  static const String kPauseOnZeroVolume = 'pause_on_zero_volume';

  /// 断连暂停（Android/鸿蒙）：当前播放输出设备断开时自动暂停。
  static const String kPauseOnDeviceDisconnect = 'pause_on_device_disconnect';

  /// 通知栏播放控制（settings.md §3.6）：Android 通知栏/后台播放。
  static const String kNotificationControls = 'notification_controls';

  /// 播放页切换过渡动画（settings.md §3.7 界面）：none / fade / slide / scale。
  static const String kPlayerTransition = 'player_transition';

  /// 压缩图像画质（设置 → 界面）：开=列表/卡片用 768 长边 JPEG82 缩略图；
  /// 关（默认）=直接显示封面原图，画质无损。播放页恒用原图，不受此开关影响。
  static const String kCoverThumbCompress = 'cover_thumb_compress';

  /// 自定义界面字体（设置 → 界面 → 文字）：字体家族名 / 应用字体目录内文件名 /
  /// 显示名。**设备本地**——字体文件复制到应用支持目录，不随设置导出/同步，
  /// 故不进 [knownKeys]；文件缺失或加载失败时回退系统字体。
  static const String kCustomFontFamily = 'custom_font_family';
  static const String kCustomFontFile = 'custom_font_file';
  static const String kCustomFontLabel = 'custom_font_label';

  /// 歌曲标题显示格式（settings.md §3.4 歌曲）：默认 song.artist - song.title。
  static const String kSongTitleFormat = 'song_title_format';

  /// 时长削弱（改进.txt 功能8）：加权抽样时按歌曲时长乘以分段削弱系数。
  static const String kCurveWeightEnabled = 'curve_weight_enabled';
  static const String kCurveWeightSegments = 'curve_weight_segments';

  /// 加权随机削峰（设置→播放）·次数冷却档位：`off`/`weak`/`normal`。
  static const String kWeightedDrawCooldown = 'weighted_draw_cooldown';

  /// 加权随机削峰（设置→播放）·曲数冷却比例（0~1，0=关）。
  static const String kWeightedCountCooldownRatio =
      'weighted_count_cooldown_ratio';

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

  /// 播放源详情歌曲排列方式（源内浏览页）。
  static const String kSortSourceSongs = 'sort_source_songs';

  /// 各页分类方式（全局）：无 / 文件夹（直接父级或逐级）/ 专辑。
  static const String kGroupPlaylistDetail = 'group_playlist_detail';
  static const String kGroupFavorites = 'group_favorites';
  static const String kGroupSongs = 'group_songs';
  static const String kGroupSource = 'group_source';

  /// 列表视图行为（设置→界面→视图行为）：长按组头展开/折叠（默认关）。
  ///
  /// 关 = 长按组头进入多选并选中整组，「全部展开/折叠」在分类菜单；
  /// 开 = 长按组头全部展开/折叠，「多选」在分类菜单。
  static const String kLongPressCollapseGroups = 'long_press_collapse_groups';

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

  /// 曲数冷却默认比例（列表长度的 20%）。
  static const double defaultWeightedCountCooldownRatio = 0.2;

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
  String get cacheConfigMode => index.settingsGet(kCacheConfigMode) ?? 'custom';
  set cacheConfigMode(String v) => index.settingsSet(kCacheConfigMode, v);

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

  // ---------- 多设备状态同步（阶段5，DEVELOPER.md「播放算法与同步协议」） ----------

  /// 服务端 cursor：pull 增量基准，SyncEngine 每次成功后推进。
  int get syncCursor =>
      int.tryParse(index.settingsGet(kSyncCursor) ?? '0') ?? 0;
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

  /// ID3v2.3 帧长回填补读标记：旧版帧长统一 syncsafe，v2.3 大 APIC 丢封面。
  bool get coverReenrichV2Done =>
      (index.settingsGet(kCoverReenrichV2Done) ?? '0') == '1';
  set coverReenrichV2Done(bool v) =>
      index.settingsSet(kCoverReenrichV2Done, v ? '1' : '0');

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

  /// FLAC 前置 ID3v2 标签回填补读标记（一次性，本机）；见 direct_source_manager。
  bool get flacId3PrefixMetaV1Done =>
      (index.settingsGet(kFlacId3PrefixMetaV1Done) ?? '0') == '1';
  set flacId3PrefixMetaV1Done(bool v) =>
      index.settingsSet(kFlacId3PrefixMetaV1Done, v ? '1' : '0');

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
  /// `weighted` 的显示名为「随机播放」，实际算法由 [weightedRandomEnabled] 决定。
  String get playModeDefault =>
      index.settingsGet(kPlayModeDefault) ?? defaultPlayMode;
  set playModeDefault(String v) => index.settingsSet(kPlayModeDefault, v);

  /// 随机播放模式下是否启用加权随机（默认开）。
  /// 关闭后为普通随机：按深层列表做不放回抽取（见 PlayerProvider 的
  /// shuffleCandidateIndices），此时次数/曲数冷却设置不生效。
  bool get weightedRandomEnabled =>
      (index.settingsGet(kWeightedRandomEnabled) ?? '1') == '1';
  set weightedRandomEnabled(bool v) =>
      index.settingsSet(kWeightedRandomEnabled, v ? '1' : '0');

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
  /// （随机播放也先抽样确定，切歌时复用同一结果），开关只决定是否预载。
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
  String get keepScreenOnDevice => index.settingsGet(kKeepScreenOnDevice) ?? '';
  set keepScreenOnDevice(String v) => index.settingsSet(kKeepScreenOnDevice, v);

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

  /// 转码响度均衡（off=关；8/10/14/16/23=统一到该 LUFS；默认关；
  /// 只在代理转码链路生效，直连/缓存不经过服务端）。
  static const String kTranscodeLoudnorm = 'transcode_loudnorm';

  String get transcodeLoudnorm {
    final v = (index.settingsGet(kTranscodeLoudnorm) ?? 'off').trim();
    if (v == '8' || v == '10' || v == '14' || v == '16' || v == '23') {
      return v;
    }
    return 'off';
  }

  set transcodeLoudnorm(String v) => index.settingsSet(kTranscodeLoudnorm, v);

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
  set scanWifiOnly(bool v) => index.settingsSet(kScanWifiOnly, v ? '1' : '0');

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
  set fadeDurationMs(int v) => index.settingsSet(kFadeDurationMs, v.toString());

  /// 应用内音量（0~100，默认 100）：独立于系统音量的软件增益。
  /// 非法/缺省回退 100，越界读取钳制到 [0, 100]。
  int get appVolume =>
      (int.tryParse(index.settingsGet(kAppVolume) ?? '') ?? 100).clamp(0, 100);
  set appVolume(int v) =>
      index.settingsSet(kAppVolume, v.clamp(0, 100).toString());

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

  // ---------- 播放分区·加权随机削峰（设置→播放） ----------

  /// 次数冷却档位（默认 `normal`=2/3）。削峰规则1：歌曲播放后，被抽中的前 N 次
  /// 直接抛弃、第 N+1 次才作数（N 分权重档，见 [WeightedDrawCooldown]）。
  WeightedDrawCooldown get weightedDrawCooldown =>
      WeightedDrawCooldown.parse(index.settingsGet(kWeightedDrawCooldown));
  set weightedDrawCooldown(WeightedDrawCooldown v) =>
      index.settingsSet(kWeightedDrawCooldown, v.name);

  /// 曲数冷却比例（默认 0.2，范围 0~1，`0`=关闭）。削峰规则2：位于「深层列表
  /// （持久化播放历史）末尾 `round(列表长度 × 本比例)` 条」内的抽中直接抛弃
  /// （跨重启/跨设备同步后仍生效）。非法值回退默认、越界钳制。
  double get weightedCountCooldownRatio {
    final raw = index.settingsGet(kWeightedCountCooldownRatio);
    final v = raw == null ? null : double.tryParse(raw);
    if (v == null || v.isNaN) return defaultWeightedCountCooldownRatio;
    return v.clamp(0.0, 1.0);
  }

  set weightedCountCooldownRatio(double v) => index.settingsSet(
      kWeightedCountCooldownRatio, v.clamp(0.0, 1.0).toString());

  // ---------- 界面分区（settings.md §3.7） ----------

  /// 压缩图像画质（默认关）：开时列表/卡片/迷你条用缩略图（省解码），
  /// 关时一律显示封面原图。
  bool get compressCoverImage =>
      (index.settingsGet(kCoverThumbCompress) ?? '0') == '1';
  set compressCoverImage(bool v) =>
      index.settingsSet(kCoverThumbCompress, v ? '1' : '0');

  /// 自定义字体家族名（空=系统默认）。与 [kCustomFontFile]、[kCustomFontLabel]
  /// 由 CustomFontService 统一维护，不要单独写。
  String get customFontFamily => index.settingsGet(kCustomFontFamily) ?? '';
  set customFontFamily(String v) => index.settingsSet(kCustomFontFamily, v);

  /// 自定义字体在应用字体目录内的文件名（空=未导入）。
  String get customFontFile => index.settingsGet(kCustomFontFile) ?? '';
  set customFontFile(String v) => index.settingsSet(kCustomFontFile, v);

  /// 自定义字体显示名（导入时的原文件名，不含扩展名）。
  String get customFontLabel => index.settingsGet(kCustomFontLabel) ?? '';
  set customFontLabel(String v) => index.settingsSet(kCustomFontLabel, v);

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
  void _setSort(String key, CollectionSort v) => index.settingsSet(key, v.name);

  CollectionSort get sortSongs => _sort(kSortSongs);
  set sortSongs(CollectionSort v) => _setSort(kSortSongs, v);

  CollectionSort get sortFavorites => _sort(kSortFavorites);
  set sortFavorites(CollectionSort v) => _setSort(kSortFavorites, v);

  CollectionSort get sortPlaylistDetail => _sort(kSortPlaylistDetail);
  set sortPlaylistDetail(CollectionSort v) => _setSort(kSortPlaylistDetail, v);

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

  CollectionSort get sortSourceSongs => _sort(kSortSourceSongs);
  set sortSourceSongs(CollectionSort v) => _setSort(kSortSourceSongs, v);

  SongGroupMode get groupPlaylistDetail =>
      SongGroupModeX.parse(index.settingsGet(kGroupPlaylistDetail));
  set groupPlaylistDetail(SongGroupMode v) =>
      index.settingsSet(kGroupPlaylistDetail, v.name);

  SongGroupMode get groupFavorites =>
      SongGroupModeX.parse(index.settingsGet(kGroupFavorites));
  set groupFavorites(SongGroupMode v) =>
      index.settingsSet(kGroupFavorites, v.name);

  SongGroupMode get groupSongs =>
      SongGroupModeX.parse(index.settingsGet(kGroupSongs));
  set groupSongs(SongGroupMode v) => index.settingsSet(kGroupSongs, v.name);

  /// 播放源页默认保持旧的逐级文件夹浏览；显式选「无」后按平铺记忆。
  SongGroupMode get groupSource => SongGroupModeX.parse(
      index.settingsGet(kGroupSource) ?? SongGroupMode.folder.name);
  set groupSource(SongGroupMode v) => index.settingsSet(kGroupSource, v.name);

  /// 长按组头展开/折叠（设置→界面→视图行为，默认关）。
  ///
  /// 关（A）：长按组头进入多选并选中整组；全部展开/折叠在分类菜单。
  /// 开（B）：长按组头全部展开/折叠；多选入口在分类菜单。
  bool get longPressCollapseGroups =>
      (index.settingsGet(kLongPressCollapseGroups) ?? '0') == '1';
  set longPressCollapseGroups(bool v) =>
      index.settingsSet(kLongPressCollapseGroups, v ? '1' : '0');

  /// 列表分组折叠状态（按集合持久化，[collectionKey] 如 `playlist:12` /
  /// `favorites` / `songs` / `source:webdav:nas`）：存折叠组名集合
  /// （逐项 URI 编码后以 `|` 连接；组名本身可含任意字符）。
  Set<String> groupCollapsed(String collectionKey) {
    final raw = index.settingsGet('group_collapsed_$collectionKey');
    if (raw == null) {
      // 兼容上个版本按歌单落的旧键（`playlist:<id>` 首次读取时迁移）；
      // 新键存在但为空串 = 用户已全部展开，不能再回落到旧键。
      if (collectionKey.startsWith('playlist:')) {
        final id = collectionKey.substring('playlist:'.length);
        final legacy = index.settingsGet('playlist_group_collapsed_$id');
        if (legacy != null && legacy.isNotEmpty) {
          return legacy.split('|').map(Uri.decodeComponent).toSet();
        }
      }
      return {};
    }
    if (raw.isEmpty) return {};
    return raw.split('|').map(Uri.decodeComponent).toSet();
  }

  void setGroupCollapsed(String collectionKey, Set<String> collapsed) {
    final v = collapsed.map(Uri.encodeComponent).join('|');
    index.settingsSet('group_collapsed_$collectionKey', v);
  }

  /// 源内「应用内新建过、可能还没有歌曲」的文件夹（逐级模式用于显示空文件夹）。
  Set<String> sourceCreatedFolders(String sourceKey) {
    final raw = index.settingsGet('source_created_folders_$sourceKey');
    if (raw == null || raw.isEmpty) return {};
    return raw.split('|').map(Uri.decodeComponent).toSet();
  }

  void addSourceCreatedFolder(String sourceKey, String path) {
    final set = sourceCreatedFolders(sourceKey)..add(path);
    index.settingsSet('source_created_folders_$sourceKey',
        set.map(Uri.encodeComponent).join('|'));
  }

  // ---------- 通知分区（settings.md §3.6） ----------

  bool get audioFocusEnabled =>
      (index.settingsGet(kAudioFocusEnabled) ?? '1') == '1';
  set audioFocusEnabled(bool v) =>
      index.settingsSet(kAudioFocusEnabled, v ? '1' : '0');

  bool get notificationControls =>
      (index.settingsGet(kNotificationControls) ?? '1') == '1';
  set notificationControls(bool v) =>
      index.settingsSet(kNotificationControls, v ? '1' : '0');

  /// 静音暂停（默认关）：媒体音量归零时自动暂停当前播放（仅 Android）。
  bool get pauseOnZeroVolume =>
      (index.settingsGet(kPauseOnZeroVolume) ?? '0') == '1';
  set pauseOnZeroVolume(bool v) =>
      index.settingsSet(kPauseOnZeroVolume, v ? '1' : '0');

  /// 断连暂停（默认关）：当前播放输出设备（蓝牙/有线耳机等）断开时自动暂停；
  /// 用户主动从蓝牙切到扬声器（设备仍在连）不触发（仅 Android）。
  bool get pauseOnDeviceDisconnect =>
      (index.settingsGet(kPauseOnDeviceDisconnect) ?? '0') == '1';
  set pauseOnDeviceDisconnect(bool v) =>
      index.settingsSet(kPauseOnDeviceDisconnect, v ? '1' : '0');

  // ---------- 备用源（本地偏好，不进 knownKeys，不随设置导出/同步） ----------

  /// 备用缺歌自动补齐（默认关）：主源播放成功后，后台抽查备用是否存在同 ref，
  /// 缺失则把主源当前曲流式复制过去（单首按需，不做全库静默全量）。
  static const String kFallbackAutoRepair = 'fallback_auto_repair';

  /// 在线元数据保存位置（设置→歌曲）：`appCache`=仅应用缓存（默认）；
  /// `sidecar`=同时写回源目录（歌词 `<stem>.lrc` + 封面 `cover.jpg`，同名覆盖）。
  static const String kOnlineMetaSaveMode = 'online_meta_save_mode';

  /// 自定义歌词目录（sidecar 模式＋本地源用）：空=写歌曲同目录；非空=写该目录
  /// `<歌名>.lrc`。目录不存在时回退不同步写盘（只写 DB）；远端源恒写歌曲同目录。
  static const String kOnlineMetaLyricDir = 'online_meta_lyric_dir';

  /// 在线歌词来源（`lrclib/qq/netease`，默认 LRCLIB；无自动串源）。
  static const String kOnlineMetaLyricSource = 'online_meta_lyric_source';

  /// 在线封面来源（`mbCaa/qq/netease`，默认 MB→CAA；无自动串源）。
  static const String kOnlineMetaCoverSource = 'online_meta_cover_source';

  bool get fallbackAutoRepair =>
      (index.settingsGet(kFallbackAutoRepair) ?? '0') == '1';
  set fallbackAutoRepair(bool v) =>
      index.settingsSet(kFallbackAutoRepair, v ? '1' : '0');

  /// 手动线路偏好（auto/primary/fb0/fb1，默认 auto）：按源 key 存。
  static String _lineKey(String sourceKey) => 'source_line:$sourceKey';

  String getSourceLine(String sourceKey) =>
      index.settingsGet(_lineKey(sourceKey)) ?? 'auto';
  setSourceLine(String sourceKey, String line) =>
      index.settingsSet(_lineKey(sourceKey), line);

  // ---------- 在线元数据（设置→歌曲，纯前端 LRCLIB/MB-CAA） ----------

  OnlineMetaSaveMode get onlineMetaSaveMode =>
      OnlineMetaSaveMode.parse(index.settingsGet(kOnlineMetaSaveMode));
  set onlineMetaSaveMode(OnlineMetaSaveMode v) =>
      index.settingsSet(kOnlineMetaSaveMode, v.name);

  String get onlineMetaLyricDir => index.settingsGet(kOnlineMetaLyricDir) ?? '';
  set onlineMetaLyricDir(String v) => index.settingsSet(kOnlineMetaLyricDir, v);

  OnlineMetaLyricSource get onlineMetaLyricSource =>
      OnlineMetaLyricSource.parse(index.settingsGet(kOnlineMetaLyricSource));
  set onlineMetaLyricSource(OnlineMetaLyricSource v) =>
      index.settingsSet(kOnlineMetaLyricSource, v.name);

  OnlineMetaCoverSource get onlineMetaCoverSource =>
      OnlineMetaCoverSource.parse(index.settingsGet(kOnlineMetaCoverSource));
  set onlineMetaCoverSource(OnlineMetaCoverSource v) =>
      index.settingsSet(kOnlineMetaCoverSource, v.name);

  static const String kShortcutWindowBindings = 'shortcut_window_bindings';
  static const String kShortcutGlobalBindings = 'shortcut_global_bindings';

  String get shortcutWindowBindings =>
      index.settingsGet(kShortcutWindowBindings) ?? '';
  set shortcutWindowBindings(String v) =>
      index.settingsSet(kShortcutWindowBindings, v);

  String get shortcutGlobalBindings =>
      index.settingsGet(kShortcutGlobalBindings) ?? '';
  set shortcutGlobalBindings(String v) =>
      index.settingsSet(kShortcutGlobalBindings, v);

  /// 全部已知键（供设置导入导出筛选，settings.md §3.5）。
  static const List<String> knownKeys = [
    kCacheMaxBytes,
    kCacheSongLimit,
    kCacheConfigMode,
    kTranscodeEnabled,
    kTranscodeBitrate,
    kTranscodeLoudnorm,
    kAutoCacheFavorites,
    kAllowInsecureHttp,
    kAllowSelfSigned,
    kSyncCursor,
    kSyncEnabled,
    kLastSyncAt,
    kPlayModeDefault,
    kWeightedRandomEnabled,
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
    kWeightedDrawCooldown,
    kWeightedCountCooldownRatio,
    kAudioFocusEnabled,
    kNotificationControls,
    kPauseOnZeroVolume,
    kPauseOnDeviceDisconnect,
    kPlayerTransition,
    kCoverThumbCompress,
    kSongTitleFormat,
    kViewModePlaylists,
    kViewModeSources,
    kViewModeAlbums,
    kViewModeArtists,
    kOnlineMetaSaveMode,
    kOnlineMetaLyricDir,
    kOnlineMetaLyricSource,
    kOnlineMetaCoverSource,
    kSortSongs,
    kSortFavorites,
    kSortPlaylistDetail,
    kSortQueue,
    kSortAlbums,
    kSortArtists,
    kSortPlaylists,
    kSortSources,
    kSortSourceSongs,
    kGroupPlaylistDetail,
    kGroupFavorites,
    kGroupSongs,
    kGroupSource,
    kLongPressCollapseGroups,
    kShortcutWindowBindings,
    kShortcutGlobalBindings,
  ];
}
