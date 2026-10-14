import 'package:dio/dio.dart';

import 'online_meta_models.dart';

/// LRCLIB 歌词源（免费无Key，仅歌词，无封面）。
///
/// 端点（实测）：
/// - 精确：`GET /api/get?artist_name=&track_name=&album_name=&duration=`
/// - 模糊：`GET /api/search?q=&track_name=&artist_name=&album_name=`
class LrclibProvider {
  static const String base = 'https://lrclib.net';
  static const String userAgent =
      'SelfMusic/1.0.1 (self-hosted music player; contact via project homepage)';

  final Dio dio;

  LrclibProvider({Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              baseUrl: base,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
            ));

  /// 精确取一首（duration 传秒，用于时长匹配；失败/404 返回 null）。
  Future<OnlineLyricCandidate?> fetchExact({
    required String artist,
    required String track,
    String? album,
    int? durationSec,
  }) async {
    final t = track.trim();
    final a = artist.trim();
    if (t.isEmpty || a.isEmpty) return null;
    try {
      final resp = await dio.get('/api/get', queryParameters: {
        'artist_name': a,
        'track_name': t,
        if (album != null && album.trim().isNotEmpty)
          'album_name': album.trim(),
        if (durationSec != null && durationSec > 0) 'duration': '$durationSec',
      });
      if (resp.statusCode == 404) return null;
      final data = resp.data;
      if (data is! Map<String, dynamic>) return null;
      return _parse(data, 0);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// 模糊搜索（返回至多 [limit] 个有正文的候选）。
  Future<List<OnlineLyricCandidate>> search({
    String? query,
    String? track,
    String? artist,
    String? album,
    int limit = 10,
  }) async {
    final q = (query ?? '').trim();
    final t = (track ?? '').trim();
    final a = (artist ?? '').trim();
    if (q.isEmpty && t.isEmpty && a.isEmpty) return const [];
    try {
      final resp = await dio.get('/api/search', queryParameters: {
        if (q.isNotEmpty) 'q': q,
        if (t.isNotEmpty) 'track_name': t,
        if (a.isNotEmpty) 'artist_name': a,
        if (album != null && album.trim().isNotEmpty)
          'album_name': album.trim(),
      });
      final data = resp.data;
      if (data is! List) return const [];
      final out = <OnlineLyricCandidate>[];
      for (final e in data) {
        if (e is! Map<String, dynamic>) continue;
        final c = _parse(e, out.length);
        if (c == null || !c.hasContent) continue;
        out.add(c);
        if (out.length >= limit) break;
      }
      return out;
    } on DioException {
      rethrow;
    }
  }

  OnlineLyricCandidate? _parse(Map<String, dynamic> j, int index) {
    final synced = (j['syncedLyrics'] as String?)?.trim();
    final plain = (j['plainLyrics'] as String?)?.trim();
    if ((synced == null || synced.isEmpty) &&
        (plain == null || plain.isEmpty)) {
      return null;
    }
    return OnlineLyricCandidate(
      id: (j['id'] as num?)?.toInt() ?? index,
      trackName: (j['trackName'] as String?) ?? (j['name'] as String?) ?? '',
      artistName: (j['artistName'] as String?) ?? '',
      albumName: (j['albumName'] as String?) ?? '',
      durationSec: (j['duration'] as num?)?.toDouble(),
      syncedLyrics: synced?.isEmpty == true ? null : synced,
      plainLyrics: plain?.isEmpty == true ? null : plain,
      instrumental: (j['instrumental'] as bool?) ?? false,
    );
  }
}
