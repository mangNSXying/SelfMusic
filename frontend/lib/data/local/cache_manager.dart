import '../../models/song.dart';
import '../sources/music_source.dart';
import '../sources/sftp_direct_source.dart';
import '../sources/smb_direct_source.dart';
import '../sources/transcode_variant.dart';
import '../sources/webdav_direct_source.dart';
import 'app_settings.dart';
import 'local_index.dart';

/// 离线缓存管理（stage2.md §6）：
/// 收藏直连歌自动缓存 + 按歌曲数据淘汰（中位进度 → 播放次数 → LRU）+ 上下限。
///
/// 缓存与预载分离：只有 [CacheEntryKind.user] 算“已缓存”并计入歌曲上限；
/// 预载原文件/转码变体是预载产物，只在字节上限与淘汰排序中参与。
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

  /// 某首歌的全部转码变体 key（码率 {192,256,320} × 响度
  /// {off,8,10,14,16,23}，与设置页选项/服务端允许集同步）。
  Iterable<String> _variantKeysOf(String base) sync* {
    for (final b in const [192, 256, 320]) {
      for (final n in const ['off', '8', '10', '14', '16', '23']) {
        yield transcodeVariantKey(base, b, n);
      }
    }
  }

  /// 删歌时清缓存：原文件行 + 所有转码变体行。
  Future<void> deleteSongCache(MusicSource src, Song s) async {
    final base = cacheKeyOf(src, s);
    if (base == null) return;
    try {
      await index.deleteCache(base);
    } catch (_) {}
    for (final k in _variantKeysOf(base)) {
      try {
        await index.deleteCache(k);
      } catch (_) {}
    }
  }

  /// 用户缓存成功后清理该歌的转码变体：缓存优先后它们永远不会再被用到。
  /// 当前正在播放/预载的变体跳过，避免动到在用的文件。
  Future<void> deleteVariantsOf(MusicSource src, Song s) async {
    final base = cacheKeyOf(src, s);
    if (base == null) return;
    for (final k in _variantKeysOf(base)) {
      if (k == currentCacheKey || k == preloadCacheKey) continue;
      try {
        await index.deleteCache(k);
      } catch (_) {}
    }
  }

  /// 收藏直连歌时自动后台缓存（需开启 autoCacheFavorites）。
  Future<void> autoCacheIfNeeded(MusicSource? src, Song s,
      {required bool becameFavorite}) async {
    if (src == null || !s.isDirect) return;
    if (!becameFavorite || !settings.autoCacheFavorites) return;
    try {
      await src.cacheSong(s, kind: CacheEntryKind.user);
      final k = cacheKeyOf(src, s);
      if (k != null) {
        // 已有预载原文件时 cacheSong 会短路：升级为真正的用户缓存。
        await index.setCacheKind(k, CacheEntryKind.user);
        index.touchCache(k);
      }
      await deleteVariantsOf(src, s);
      await evictIfNeeded(protectKey: k);
    } catch (_) {
      // 缓存失败静默：不影响收藏行为，下次播放直连歌仍可手动缓存。
    }
  }

  /// 超出上限时按歌曲数据淘汰：中位进度低者先淘汰（无样本最弱），
  /// 再按播放次数低者先淘汰，最后才用 LRU 兜底。收藏歌曲豁免。
  ///
  /// 上限取「生效值」（custom=本地；follow_server=服务端建议，settings.md §3.3）。
  /// 歌曲上限只统计 [CacheEntryKind.user]；字节上限统计全部缓存文件。
  ///
  /// 逐行删除、单行失败（文件被占用/权限）跳过继续：删不掉的那份留给下一轮，
  /// 不能中断整轮，也不能让异常上抛——淘汰是后台维护动作，调用方（手动缓存、
  /// 收藏、预载）只关心自己的下载，删除失败会误报「缓存失败」。
  Future<void> evictIfNeeded({String? protectKey}) async {
    final maxBytes = settings.effectiveCacheMaxBytes;
    final maxSongs = settings.effectiveCacheSongLimit;
    if (maxBytes <= 0 && maxSongs <= 0) return;
    final rows = index.listCache();
    if (rows.isEmpty) return;
    final stats = index.cacheSongStats();

    // 按歌曲分组：同一首的原文件与变体共享播放数据；无归属的旧行各自一组。
    final rowGroups = <String, List<CachedRow>>{};
    final mapped = <String, ({String sourceKey, String songRef})>{};
    for (final r in rows) {
      final sourceKey = r.sourceKey;
      final songRef = r.songRef;
      final hasSong = sourceKey != null && songRef != null;
      final key =
          hasSong ? 's\u0000$sourceKey\u0000$songRef' : 'l\u0000${r.cacheKey}';
      rowGroups.putIfAbsent(key, () => []).add(r);
      if (hasSong) {
        mapped[key] = (sourceKey: sourceKey, songRef: songRef);
      }
    }
    final groups = <_CacheGroup>[];
    rowGroups.forEach((key, groupRows) {
      final m = mapped[key];
      final st = m == null
          ? null
          : stats[LocalIndex.cacheSongKey(m.sourceKey, m.songRef)];
      groups.add(_CacheGroup(key, groupRows, st));
    });

    var total = groups.fold<int>(0, (sum, g) => sum + g.size);
    var userSongs = groups.where((g) => g.hasUser).length;
    final deleted = <String>{};

    Future<bool> deleteRow(CachedRow r) async {
      try {
        await index.deleteCache(r.cacheKey);
      } catch (_) {
        return false;
      }
      deleted.add(r.cacheKey);
      total -= r.size;
      if (r.kind == CacheEntryKind.user) userSongs -= 1;
      return true;
    }

    // 第一轮：歌曲上限，只淘汰用户缓存，按歌曲数据从弱到强。
    if (maxSongs > 0 && userSongs > maxSongs) {
      groups.sort(_compareGroups);
      for (final g in groups) {
        if (userSongs <= maxSongs) break;
        if (!g.hasUser || g.isFavorite || _isProtected(g, protectKey)) continue;
        for (final r in _deletionOrder(g.rows)) {
          if (userSongs <= maxSongs) break;
          if (deleted.contains(r.cacheKey)) continue;
          await deleteRow(r);
        }
      }
    }

    // 第二轮：字节上限，全部缓存文件参与；组内先删变体/预载，原缓存最后。
    if (maxBytes > 0 && total > maxBytes) {
      groups.sort(_compareGroups);
      for (final g in groups) {
        if (total <= maxBytes) break;
        if (g.isFavorite || _isProtected(g, protectKey)) continue;
        for (final r in _deletionOrder(g.rows)) {
          if (total <= maxBytes) break;
          if (deleted.contains(r.cacheKey)) continue;
          await deleteRow(r);
        }
      }
    }
  }

  bool _isProtected(_CacheGroup g, String? protectKey) => g.rows.any((r) =>
      r.cacheKey == currentCacheKey ||
      r.cacheKey == preloadCacheKey ||
      (protectKey != null && r.cacheKey == protectKey));

  /// 升序：中位进度（null 最弱）→ 播放次数 → 播放时长（时长未知时兜底）
  /// → LRU → 分组 key（保证顺序确定）。
  int _compareGroups(_CacheGroup a, _CacheGroup b) {
    var c = (a.medianPercent ?? -1.0).compareTo(b.medianPercent ?? -1.0);
    if (c != 0) return c;
    c = a.playCount.compareTo(b.playCount);
    if (c != 0) return c;
    c = a.playSec.compareTo(b.playSec);
    if (c != 0) return c;
    c = a.lastAccess.compareTo(b.lastAccess);
    if (c != 0) return c;
    return a.sortKey.compareTo(b.sortKey);
  }

  /// 组内删除顺序：预载变体 → legacy → 预载原文件 → 用户缓存。
  List<CachedRow> _deletionOrder(List<CachedRow> rows) {
    final copy = List<CachedRow>.of(rows);
    copy.sort((a, b) {
      final c = _kindDeleteRank(a.kind).compareTo(_kindDeleteRank(b.kind));
      if (c != 0) return c;
      return (a.lastAccessedAt ?? a.cachedAt ?? '')
          .compareTo(b.lastAccessedAt ?? b.cachedAt ?? '');
    });
    return copy;
  }

  int _kindDeleteRank(CacheEntryKind k) => switch (k) {
        CacheEntryKind.preloadVariant => 0,
        CacheEntryKind.legacy => 1,
        CacheEntryKind.preloadOrigin => 2,
        CacheEntryKind.user => 3,
      };
}

class _CacheGroup {
  _CacheGroup(this.sortKey, this.rows, CacheSongStats? stats)
      : size = rows.fold(0, (sum, r) => sum + r.size),
        lastAccess = rows.fold('', (latest, r) {
          final at = r.lastAccessedAt ?? r.cachedAt ?? '';
          return at.compareTo(latest) > 0 ? at : latest;
        }),
        hasUser = rows.any((r) => r.kind == CacheEntryKind.user),
        isFavorite = stats?.isFavorite ?? false,
        medianPercent = stats?.medianPercent,
        playSec = stats?.playSec ?? 0,
        playCount = (stats != null &&
                stats.durationSec != null &&
                stats.durationSec! > 0 &&
                stats.playSec > 0)
            ? stats.playSec / stats.durationSec!
            : 0;

  final String sortKey;
  final List<CachedRow> rows;
  final int size;
  final String lastAccess;
  final bool hasUser;
  final bool isFavorite;
  final double? medianPercent;
  final int playSec;
  final double playCount;
}
