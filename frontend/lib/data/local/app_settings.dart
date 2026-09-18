import 'dart:convert';

import 'local_index.dart';

/// 客户端缓存配置来源（settings.md §3.3）。
enum CacheConfigMode {
  custom('自定义'),
  followServer('跟随服务端');

  const CacheConfigMode(this.label);
  final String label;

  static CacheConfigMode parse(String? v) =>
      v == 'follow_server' ? followServer : custom;

  String get storeValue =>
      this == followServer ? 'follow_server' : 'custom';
}

/// 客户端用户设置（直连模式 app_settings 表；settings.md §3）。
///
/// 已实现（settings.md §3.1/§3.3/§3.4）：
/// - 缓存来源模式 `cache_config_mode`（custom / follow_server，后者暂灰显）与自定义上限；
/// - 收藏自动缓存；播放页权重信息显示；忽略音频过滤；仅 Wi-Fi 扫描；
/// - 默认播放模式、断点续播开关（对应 DESIGN §6.7）。
class AppSettings {
  static const String kCacheMaxBytes = 'cache_max_bytes';
  static const String kCacheSongLimit = 'cache_song_limit';
  static const String kAutoCacheFavorites = 'auto_cache_favorites';
  static const String kCacheConfigMode = 'cache_config_mode';
  static const String kPlayModeDefault = 'play_mode_default';
  static const String kResumeOnStartup = 'resume_on_startup';
  static const String kPlayerShowWeight = 'player_show_weight';
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

  /// 默认缓存总上限（512 MB）。
  static const int defaultCacheMaxBytes = 512 * 1024 * 1024;
  static const int defaultCacheSongLimit = 200;

  static const String defaultPlayMode = 'sequence';

  /// 均衡器默认频段增益（5 段，dB）。
  static const List<double> defaultEqBands = [0, 0, 0, 0, 0];

  final LocalIndex index;
  AppSettings(this.index);

  // ---------- 缓存（settings.md §3.3） ----------

  CacheConfigMode get cacheConfigMode =>
      CacheConfigMode.parse(index.settingsGet(kCacheConfigMode));
  set cacheConfigMode(CacheConfigMode v) =>
      index.settingsSet(kCacheConfigMode, v.storeValue);

  int get cacheMaxBytes =>
      int.tryParse(index.settingsGet(kCacheMaxBytes) ?? '') ??
      defaultCacheMaxBytes;
  set cacheMaxBytes(int v) => index.settingsSet(kCacheMaxBytes, v.toString());

  int get cacheSongLimit =>
      int.tryParse(index.settingsGet(kCacheSongLimit) ?? '') ??
      defaultCacheSongLimit;
  set cacheSongLimit(int v) => index.settingsSet(kCacheSongLimit, v.toString());

  /// 服务端建议值（阶段 6 下发后由客户端填入；未下发前为空，此时跟随模式回退自定义值）。
  int? serverCacheMaxBytes;
  int? serverCacheSongLimit;

  /// 生效缓存上限：custom → 本地值；follow_server → 服务端建议值（不可达/未下发回退本地）。
  int get effectiveCacheMaxBytes =>
      cacheConfigMode == CacheConfigMode.followServer
          ? (serverCacheMaxBytes ?? cacheMaxBytes)
          : cacheMaxBytes;

  int get effectiveCacheSongLimit =>
      cacheConfigMode == CacheConfigMode.followServer
          ? (serverCacheSongLimit ?? cacheSongLimit)
          : cacheSongLimit;

  // ---------- 收藏自动缓存（settings.md §3.1） ----------

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
    kCacheConfigMode,
    kPlayModeDefault,
    kResumeOnStartup,
    kPlayerShowWeight,
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
  ];
}