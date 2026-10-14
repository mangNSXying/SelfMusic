import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'online_meta_models.dart';

/// MusicBrainz 录音搜索 + Cover Art Archive 封面链。
///
/// - MB 只给元数据（recording/release MBID + 规范标题），无歌词、无图片字节；
/// - CAA 必须拿 release MBID 再取：`GET /release/{mbid}/front[-500]` → 307 跳 archive.org。
/// - MB 硬限流 1 req/s：本类自带最小间隔节流（与 ArtistResolver 同口径 1010ms）。
class MusicBrainzCoverProvider {
  static const String mbBase = 'https://musicbrainz.org/ws/2';
  static const String caaBase = 'https://coverartarchive.org';
  static const String userAgent =
      'SelfMusic/1.0.1 (self-hosted music player; contact via project homepage)';

  final Dio mb;
  final Dio caa;
  int _nextAllowedAtMs = 0;

  MusicBrainzCoverProvider({Dio? mbDio, Dio? caaDio})
      : mb = mbDio ??
            Dio(BaseOptions(
              baseUrl: mbBase,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {'User-Agent': userAgent, 'Accept': 'application/json'},
            )),
        caa = caaDio ??
            Dio(BaseOptions(
              baseUrl: caaBase,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'User-Agent': userAgent},
              // CAA 全是 307 跳转到 archive.org，允许跟随。
              followRedirects: true,
              maxRedirects: 5,
            ));

  Future<void> _throttle() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _nextAllowedAtMs) {
      await Future.delayed(Duration(milliseconds: _nextAllowedAtMs - now));
    }
    _nextAllowedAtMs = DateTime.now().millisecondsSinceEpoch + 1010;
  }

  /// 录音搜索：`recording:"title" AND artist:"name"`，回退纯标题。
  Future<List<MbRecordingCandidate>> searchRecording({
    required String title,
    String? artist,
    int limit = 5,
  }) async {
    final t = title.trim();
    if (t.isEmpty) return const [];
    final esc = t.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    String q;
    final a = (artist ?? '').trim();
    if (a.isNotEmpty) {
      final ea = a.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      q = 'recording:"$esc" AND artist:"$ea"';
    } else {
      q = 'recording:"$esc"';
    }
    await _throttle();
    final resp = await mb.get('/recording/', queryParameters: {
      'query': q,
      'fmt': 'json',
      'limit': '${limit.clamp(1, 10)}',
      'dismax': 'true',
    });
    final data = resp.data;
    if (data is! Map<String, dynamic>) return const [];
    final list = data['recordings'];
    if (list is! List) return const [];
    final out = <MbRecordingCandidate>[];
    for (final r in list) {
      if (r is! Map<String, dynamic>) continue;
      final id = (r['id'] as String?) ?? '';
      if (id.isEmpty) continue;
      final rtitle = (r['title'] as String?) ?? '';
      var artistName = '';
      final credits = r['artist-credit'];
      if (credits is List && credits.isNotEmpty) {
        final names = <String>[];
        for (final c in credits) {
          if (c is Map<String, dynamic>) {
            final n = (c['name'] as String?) ??
                (c['artist'] is Map
                    ? (c['artist'] as Map)['name'] as String?
                    : null);
            if (n != null && n.isNotEmpty) names.add(n);
          } else if (c is String && c.isNotEmpty) {
            // joinphrase 等非实体片段跳过。
          }
        }
        artistName = names.join(', ');
      }
      String? relId;
      String? relTitle;
      final releases = r['releases'];
      if (releases is List && releases.isNotEmpty) {
        final first = releases.first;
        if (first is Map<String, dynamic>) {
          relId = first['id'] as String?;
          relTitle = (first['title'] as String?) ?? (first['name'] as String?);
        }
      }
      out.add(MbRecordingCandidate(
        recordingId: id,
        title: rtitle,
        artist: artistName,
        releaseId: relId,
        releaseTitle: relTitle,
        score: (r['score'] as num?)?.toInt() ?? 0,
      ));
    }
    return out;
  }

  /// 按 release MBID 取封面字节（先试 500 缩略图省流量，404 回退原图）。
  /// 无封面时返回 null（不抛 404）。
  Future<Uint8List?> fetchFrontBytes(String releaseMbid) async {
    final id = releaseMbid.trim();
    if (id.isEmpty) return null;
    for (final path in ['/release/$id/front-500', '/release/$id/front']) {
      try {
        final resp = await caa.get<List<int>>(path,
            options: Options(responseType: ResponseType.bytes));
        final code = resp.statusCode ?? 0;
        if (code == 404) continue;
        final data = resp.data;
        if (data == null || data.isEmpty) continue;
        return Uint8List.fromList(data);
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) continue;
        rethrow;
      }
    }
    return null;
  }
}
