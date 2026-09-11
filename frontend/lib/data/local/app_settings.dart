import 'local_index.dart';

/// 客户端用户设置（直连模式 app_settings 表，stage2.md §1.4）。
///
/// 本轮已实现：缓存上限 / 歌曲上限 / 收藏自动缓存；
/// 规划中的设置项见 DESIGN.md §6.7「客户端用户设置（规划）」。
class AppSettings {
  static const String kCacheMaxBytes = 'cache_max_bytes';
  static const String kCacheSongLimit = 'cache_song_limit';
  static const String kAutoCacheFavorites = 'auto_cache_favorites';

  /// 默认缓存总上限（512 MB）。
  static const int defaultCacheMaxBytes = 512 * 1024 * 1024;
  static const int defaultCacheSongLimit = 200;

  final LocalIndex index;
  AppSettings(this.index);

  int get cacheMaxBytes =>
      int.tryParse(index.settingsGet(kCacheMaxBytes) ?? '') ??
      defaultCacheMaxBytes;
  set cacheMaxBytes(int v) => index.settingsSet(kCacheMaxBytes, v.toString());

  int get cacheSongLimit =>
      int.tryParse(index.settingsGet(kCacheSongLimit) ?? '') ??
      defaultCacheSongLimit;
  set cacheSongLimit(int v) => index.settingsSet(kCacheSongLimit, v.toString());

  bool get autoCacheFavorites =>
      (index.settingsGet(kAutoCacheFavorites) ?? '1') == '1';
  set autoCacheFavorites(bool v) =>
      index.settingsSet(kAutoCacheFavorites, v ? '1' : '0');
}