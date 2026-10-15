import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'online_meta_models.dart';

/// 网易云源（免费无Key，直调公开 `api/*`；逻辑对标 MusicPlayer2
/// `NeteaseLyricDownload`，全走 https——已实测与 http 同行为）。
///
/// 端点（均已实测可用，无 Cookie/特殊 UA 要求）：
/// - 搜索：`GET music.163.com/api/search/get/?s=&limit=&type=1&offset=0`
///   （MusicPlayer2 用 POST 空 body；实测 GET 同样通，用 GET 更简单）
/// - 歌词：`GET music.163.com/api/song/lyric?os=osx&id=&lv=-1&kv=-1&tv=-1`
///   （`lrc.lyric` 同步 / `tlyric.lyric` 译文；Dio JSON 自动反转义，
///   MusicPlayer2 的手动 `\\r\\n` 手术不需要）
/// - 封面：`GET music.163.com/api/song/detail/?id=&ids=[id]`
///   取 `songs[0].album.picUrl`（拼 `?param=800y800` 省流量）
class NeteaseProvider {
  static const String apiBase = 'https://music.163.com';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';

  final Dio dio;

  NeteaseProvider({Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'User-Agent': userAgent,
                'Accept': 'application/json',
              },
            ));

  /// 曲目搜索（不带歌词正文，取词走 [fetchLyric]）。
  Future<List<OnlineLyricCandidate>> searchTracks({
    required String title,
    String? artist,
    String? album,
    int limit = 10,
  }) async {
    final t = title.trim();
    if (t.isEmpty) return const [];
    final a = (artist ?? '').trim();
    final kw = a.isEmpty ? t : '$a $t';
    try {
      final resp = await dio.get(
        '$apiBase/api/search/get/',
        queryParameters: {
          's': kw,
          'limit': '${limit.clamp(1, 20)}',
          'type': '1',
          'offset': '0',
        },
      );
      final data = resp.data;
      if (data is! Map<String, dynamic>) return const [];
      _throwIfBlocked(data, '搜索');
      final result = data['result'];
      final songs = result is Map ? result['songs'] : null;
      if (songs is! List) return const [];
      final out = <OnlineLyricCandidate>[];
      for (final e in songs) {
        if (e is! Map<String, dynamic>) continue;
        final id = e['id'];
        final name = (e['name'] as String?)?.trim() ?? '';
        if (id == null || name.isEmpty) continue;
        final artists = e['artists'];
        final names = <String>[];
        if (artists is List) {
          for (final ar in artists) {
            final n = ar is Map ? (ar['name'] as String?)?.trim() : null;
            if (n != null && n.isNotEmpty) names.add(n);
          }
        }
        final alb = e['album'];
        final albumName =
            alb is Map ? (alb['name'] as String?)?.trim() ?? '' : '';
        final durationMs = (e['duration'] as num?)?.toDouble();
        out.add(OnlineLyricCandidate(
          onlineId: '$id',
          source: OnlineMetaSource.netease,
          trackName: name,
          artistName: names.join('/'),
          albumName: albumName,
          durationSec: durationMs == null || durationMs <= 0
              ? null
              : durationMs / 1000,
        ));
        if (out.length >= limit) break;
      }
      return out;
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        throw StateError('网易云拒绝请求（HTTP 403），稍后重试或切换来源');
      }
      rethrow;
    }
  }

  /// 取歌词：`lrc.lyric` → 同步，`tlyric.lyric` → 译文。
  Future<({String? syncedLyrics, String? plainLyrics})> fetchLyric(
      String onlineId) async {
    final id = onlineId.trim();
    if (id.isEmpty) return (syncedLyrics: null, plainLyrics: null);
    final resp = await dio.get(
      '$apiBase/api/song/lyric',
      queryParameters: {
        'os': 'osx',
        'id': id,
        'lv': '-1',
        'kv': '-1',
        'tv': '-1',
      },
    );
    final data = resp.data;
    if (data is! Map<String, dynamic>) {
      return (syncedLyrics: null, plainLyrics: null);
    }
    _throwIfBlocked(data, '歌词');
    final lrc = data['lrc'] is Map
        ? ((data['lrc'] as Map)['lyric'] as String?)?.trim() ?? ''
        : '';
    final tlyric = data['tlyric'] is Map
        ? ((data['tlyric'] as Map)['lyric'] as String?)?.trim() ?? ''
        : '';
    final hasSync = lrc.isNotEmpty && lrc.contains('[');
    return (
      syncedLyrics: hasSync ? lrc : null,
      plainLyrics: hasSync
          ? (tlyric.isEmpty ? null : tlyric)
          : (lrc.isEmpty ? (tlyric.isEmpty ? null : tlyric) : lrc),
    );
  }

  /// 取封面字节（详情 → album.picUrl，拼 `?param=800y800`）。
  /// 无封面返回 null（不抛错，由调用方提示换候选）。
  Future<Uint8List?> fetchCoverBytes(String onlineId) async {
    final id = onlineId.trim();
    if (id.isEmpty) return null;
    final resp = await dio.get(
      '$apiBase/api/song/detail/',
      queryParameters: {'id': id, 'ids': '[$id]'},
    );
    final data = resp.data;
    if (data is! Map<String, dynamic>) return null;
    _throwIfBlocked(data, '封面');
    final songs = data['songs'];
    if (songs is! List || songs.isEmpty) return null;
    final first = songs.first;
    if (first is! Map) return null;
    final alb = first['album'];
    final picUrl = alb is Map ? (alb['picUrl'] as String?)?.trim() : null;
    if (picUrl == null || picUrl.isEmpty) return null;
    final url = picUrl.contains('?') ? picUrl : '$picUrl?param=800y800';
    final img = await dio.get<List<int>>(url,
        options: Options(responseType: ResponseType.bytes));
    final bytes = img.data;
    if (bytes == null || bytes.isEmpty) return null;
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }

  /// 网易反爬/下架码：`code` 非 200（-460 作弊/404 无版权）转中文错。
  static void _throwIfBlocked(Map<String, dynamic> data, String what) {
    final code = data['code'];
    if (code is num && code != 200) {
      throw StateError('网易云$what失败（code ${code.toInt()}），稍后重试或切换来源');
    }
  }
}
