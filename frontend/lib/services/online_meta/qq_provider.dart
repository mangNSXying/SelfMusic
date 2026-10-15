import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'online_meta_models.dart';

/// QQ音乐源（免费无Key，仅直调公开 CGI；逻辑对标 MusicPlayer2
/// `QQMusicLyricDownload`）。
///
/// 端点：
/// - 搜索：`GET c.y.qq.com/soso/fcgi-bin/client_search_cp?p=&n=&w=&format=json`
/// - 歌词：`GET c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=&format=json&nobase64=1`
///   （必须带 `Referer: https://y.qq.com/` + 桌面 UA，否则 403）
/// - 封面：`GET c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?songmid=&format=json`
///   取 `data[0].album.mid` → `y.gtimg.cn/...T002R800x800M000{mid}.jpg`
class QqProvider {
  static const String apiBase = 'https://c.y.qq.com';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
  static const String referer = 'https://y.qq.com/';

  final Dio dio;

  QqProvider({Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'User-Agent': userAgent,
                'Referer': referer,
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
        '$apiBase/soso/fcgi-bin/client_search_cp',
        queryParameters: {
          'p': '1',
          'n': '${limit.clamp(1, 20)}',
          'w': kw,
          'format': 'json',
        },
      );
      final data = resp.data;
      if (data is! Map<String, dynamic>) return const [];
      final list = data['data'] is Map
          ? (data['data'] as Map)['song'] is Map
              ? ((data['data'] as Map)['song'] as Map)['list']
              : null
          : null;
      if (list is! List) return const [];
      final out = <OnlineLyricCandidate>[];
      for (final e in list) {
        if (e is! Map<String, dynamic>) continue;
        final mid = (e['songmid'] as String?)?.trim() ?? '';
        final name = (e['songname'] as String?)?.trim() ?? '';
        if (mid.isEmpty || name.isEmpty) continue;
        final singers = e['singer'];
        final names = <String>[];
        if (singers is List) {
          for (final s in singers) {
            final n = s is Map ? (s['name'] as String?)?.trim() : null;
            if (n != null && n.isNotEmpty) names.add(n);
          }
        }
        final interval = (e['interval'] as num?)?.toDouble();
        out.add(OnlineLyricCandidate(
          onlineId: mid,
          source: OnlineMetaSource.qq,
          trackName: name,
          artistName: names.join('/'),
          albumName: (e['albumname'] as String?)?.trim() ?? '',
          durationSec: interval == null || interval <= 0 ? null : interval,
        ));
        if (out.length >= limit) break;
      }
      return out;
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        throw StateError('QQ音乐拒绝请求（HTTP 403），稍后重试或切换来源');
      }
      rethrow;
    }
  }

  /// 取歌词：`lyric` → 同步（无时间轴时退为纯文本），`trans` → 译文。
  /// `nobase64=1` 正常返回明文；个别返回 base64 时自动解一次。
  Future<({String? syncedLyrics, String? plainLyrics})> fetchLyric(
      String songmid) async {
    final mid = songmid.trim();
    if (mid.isEmpty) return (syncedLyrics: null, plainLyrics: null);
    final resp = await dio.get(
      '$apiBase/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
      queryParameters: {'songmid': mid, 'format': 'json', 'nobase64': '1'},
    );
    final data = resp.data;
    if (data is! Map<String, dynamic>) {
      return (syncedLyrics: null, plainLyrics: null);
    }
    final lyric = _decodeMaybe((data['lyric'] as String?)?.trim() ?? '');
    final trans = _decodeMaybe((data['trans'] as String?)?.trim() ?? '');
    final hasSync = lyric.isNotEmpty && lyric.contains('[');
    return (
      syncedLyrics: hasSync ? lyric : null,
      plainLyrics: hasSync
          ? (trans.isEmpty ? null : trans)
          : (lyric.isEmpty ? (trans.isEmpty ? null : trans) : lyric),
    );
  }

  /// 取封面字节（两步：单曲信息 → album.mid → gtimg 800 图）。
  /// 无封面返回 null（不抛错，由调用方提示换候选）。
  Future<Uint8List?> fetchCoverBytes(String songmid) async {
    final mid = songmid.trim();
    if (mid.isEmpty) return null;
    final resp = await dio.get(
      '$apiBase/v8/fcg-bin/fcg_play_single_song.fcg',
      queryParameters: {'songmid': mid, 'format': 'json'},
    );
    final data = resp.data;
    if (data is! Map<String, dynamic>) return null;
    final list = data['data'];
    if (list is! List || list.isEmpty) return null;
    final first = list.first;
    if (first is! Map) return null;
    final album = first['album'];
    final albumMid =
        album is Map ? (album['mid'] as String?)?.trim() : null;
    if (albumMid == null || albumMid.isEmpty) return null;
    final url =
        'https://y.gtimg.cn/music/photo_new/T002R800x800M000$albumMid.jpg';
    final img = await dio.get<List<int>>(url,
        options: Options(responseType: ResponseType.bytes));
    final bytes = img.data;
    if (bytes == null || bytes.isEmpty) return null;
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }

  /// 疑似 base64（无 `[`/换行、纯 base64 字符集）时解一次；失败原样返回。
  static String _decodeMaybe(String s) {
    if (s.isEmpty || s.contains('[') || s.contains('\n')) return s;
    if (!RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(s)) return s;
    try {
      final decoded = utf8.decode(base64.decode(base64.normalize(s)));
      if (decoded.contains('[')) return decoded;
      return decoded.trim().isNotEmpty ? decoded : s;
    } catch (_) {
      return s;
    }
  }
}
