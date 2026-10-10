import '../../models/song.dart';
import '../sources/music_source.dart';
import '../sources/webdav_direct_source.dart';
import 'app_settings.dart';
import 'local_index.dart';

/// 离线缓存管理（stage2.md §6）：
/// 收藏直连歌自动缓存 + 按 LRU（last_accessed_at）淘汰 + 上下限。
class CacheManager {
  final LocalIndex index;
  final AppSettings settings;

  /// 正在播放的缓存 key（淘汰时跳过，避免中断当前播放）。
  String? currentCacheKey;

  /// 预载的下一首缓存 key（淘汰时同样跳过，避免刚预载就被清掉）。
  String? preloadCacheKey;

  CacheManager(this.index, this.settings);

  /// 计算某（直连）源歌曲的缓存 key；不支持的源返回 null。
  String? cacheKeyOf(MusicSource src, Song s) {
    if (src is WebdavDirectSource) return src.cacheKeyFor(s);
    return null;
  }

  /// 播放/访问歌曲时刷新其缓存访问时间。
  void touch(MusicSource src, Song s) {
    final k = cacheKeyOf(src, s);
    if (k != null) index.touchCache(k);
  }

  /// 收藏直连歌时自动后台缓存（需开启 autoCacheFavorites）。
  Future<void> autoCacheIfNeeded(MusicSource? src, Song s,
      {required bool becameFavorite}) async {
    if (src == null || !s.isDirect) return;
    if (!becameFavorite || !settings.autoCacheFavorites) return;
    try {
      await src.cacheSong(s);
      final k = cacheKeyOf(src, s);
      if (k != null) index.touchCache(k);
      evictIfNeeded();
    } catch (_) {
      // 缓存失败静默：不影响收藏行为，下次播放直连歌仍可手动缓存。
    }
  }

  /// 超出上限时按最近最少使用淘汰（跳过正在播放条目）。
  /// 上限取「生效值」（custom=本地；follow_server=服务端建议，settings.md §3.3）。
  void evictIfNeeded() {
    final maxBytes = settings.effectiveCacheMaxBytes;
    final maxSongs = settings.effectiveCacheSongLimit;
    if (maxBytes <= 0 && maxSongs <= 0) return;
    final rows = index.listCache();
    rows.sort((a, b) => _accessAt(a).compareTo(_accessAt(b)));
    var total = rows.fold<int>(0, (sum, r) => sum + r.size);
    var remaining = rows.length;
    for (final row in rows) {
      final over = (maxSongs > 0 && remaining > maxSongs) ||
          (maxBytes > 0 && total > maxBytes);
      if (!over) break;
      // 正在播放与已预载的下一首都保留，避免中断播放 / 预载白做。
      if ((currentCacheKey != null && row.cacheKey == currentCacheKey) ||
          (preloadCacheKey != null && row.cacheKey == preloadCacheKey)) {
        continue;
      }
      index.deleteCache(row.cacheKey);
      total -= row.size;
      remaining -= 1;
    }
  }

  String _accessAt(CachedRow r) =>
      r.lastAccessedAt ?? r.cachedAt ?? '';
}