/// 可参与多设备同步的设置键（v1：播放偏好 + 媒体库规则；v2：界面偏好 + 主题外观）。
///
/// 这里刻意使用协议字符串而不是直接引用 `AppSettings` 常量，避免
/// `AppSettings -> SyncableSettings -> AppSettings` 的循环导入；
/// `settings_sync_model_test.dart` 会校验非主题键都存在于 `AppSettings.knownKeys`。
/// 主题键存在 `ThemeProvider` 的 secure storage，不在 `app_settings`。
abstract final class SyncableSettings {
  static const Set<String> playbackKeys = {
    'play_mode_default',
    'resume_on_startup',
    'preload_next',
    'sleep_play_through_default',
    'sleep_default_duration_minutes',
    'sleep_default_count',
    'lyric_focus_idle_sec',
    'weighted_random_enabled',
    'weighted_draw_cooldown',
    'weighted_count_cooldown_ratio',
    'curve_weight_enabled',
    'curve_weight_segments',
    'fade_enabled',
    'fade_duration_ms',
  };

  static const Set<String> libraryKeys = {
    'scan_ignore_min_duration_sec',
    'scan_ignore_min_size_bytes',
    'online_meta_lyric_source',
    'online_meta_cover_source',
    'online_meta_save_mode',
    'artist_resolve_auto',
    'fallback_auto_repair',
  };

  static const Set<String> interfaceKeys = {
    'song_title_format',
    'zh_variant',
    'player_transition',
    'player_show_weight',
    'player_auto_hide_idle_sec',
    'long_press_collapse_groups',
  };

  /// 主题键由 `ThemeProvider` 读写（secure storage），SyncEngine 走外部桥接。
  static const Set<String> themeKeys = {
    'theme_mode',
    'theme_accent',
    'theme_background',
  };

  static final Set<String> keys = {
    ...playbackKeys,
    ...libraryKeys,
    ...interfaceKeys,
    ...themeKeys,
  };

  static bool isSyncable(String key) => keys.contains(key);
  static bool isPlayback(String key) => playbackKeys.contains(key);
  static bool isLibrary(String key) => libraryKeys.contains(key);
  static bool isInterface(String key) => interfaceKeys.contains(key);
  static bool isTheme(String key) => themeKeys.contains(key);
}
