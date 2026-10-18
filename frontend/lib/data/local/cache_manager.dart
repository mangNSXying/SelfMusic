import '../../models/song.dart';
import '../sources/music_source.dart';
import '../sources/sftp_direct_source.dart';
import '../sources/smb_direct_source.dart';
import '../sources/transcode_variant.dart';
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
    if (src is SftpDirectSource) return src.cacheKeyFor(s);
    if (src is SmbDirectSource) return src.cacheKeyFor(s);
    return null;
  }

  /// 转码变体缓存 key：转码设置下与原文件缓存并存（同一首歌不同码率/响度
  /// 各一份），供预载与装载按当前设置取用；条件不满足返回 null（走原文件）。
  String? transcodeCacheKeyOf(MusicSource src, Song s,
      {required int bitrate, required String loudnorm}) {
    final base = cacheKeyOf(src, s);
    if (base == null) return null;
    return transcodeVariantKey(base, bitrate, loudnorm);
  }

  /// 播放/访问歌曲时刷新其缓存访问时间。
  void touch(MusicSource src, Song s) {
    final k = cacheKeyOf(src, s);
    if (k != null) index.touchCache(k);
  }

  /// 删歌时清缓存：原文件行 + 所有转码变体行。变体 key 由原 key 确定派生
  /// （码率 {192,256,320} × 响度 {off,14,16,23}，与设置页选项/服务端允许集
  /// 同步），无需额外索引列；不存在的行删除即空操作。
  Future<void> deleteSongCache(MusicSource src, Song s) async {
    final base = cacheKeyOf(src, s);
    if (base == null) return;
    try {
      await index.deleteCache(base);
    } catch (_) {}
    for (final b in [192, 256, 320]) {
      for (final n in ['off', '14', '16', '23']) {
        try {
          await index.deleteCache(transcodeVariantKey(base, b, n));
        } catch (_) {}
      }
    }
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
      await evictIfNeeded();
    } catch (_) {
      // 缓存失败静默：不影响收藏行为，下次播放直连歌仍可手动缓存。
    }
  }

  /// 超出上限时按最近最少使用淘汰（跳过正在播放条目）。
  /// 上限取「生效值」（custom=本地；follow_server=服务端建议，settings.md §3.3）。
  ///
  /// 逐行删除、单行失败（文件被占用/权限）跳过继续：删不掉的那份留给下一轮，
  /// 不能中断整轮，也不能让异常上抛——淘汰是后台维护动作，调用方（手动缓存、
  /// 收藏、预载）只关心自己的下载，删除失败会误报「缓存失败」。
  Future<void> evictIfNeeded() async {
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
      try {
        await index.deleteCache(row.cacheKey);
      } catch (_) {
        // 行与文件都还在，计数不能减；跳过这一行继续处理更旧的。
        continue;
      }
      total -= row.size;
      remaining -= 1;
    }
  }

  String _accessAt(CachedRow r) =>
      r.lastAccessedAt ?? r.cachedAt ?? '';
}