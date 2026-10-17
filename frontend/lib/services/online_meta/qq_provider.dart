import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'online_meta_models.dart';

/// QQ音乐源（免费无登录：双端点互备，免 Cookie / 免签名）。
///
/// 背景：MusicPlayer2 用的旧搜索口 `soso/fcgi-bin/client_search_cp` 已死
/// （实测恒 HTTP 500），搜不到 songmid 整条链路即废——这与其 QQ 功能长期
/// 不可用一致。本实现改走下列端点（均已实测可用）：
///
/// - 搜索主：`GET c.y.qq.com/soso/fcgi-bin/search_for_qq_cp?w=&n=&p=&format=json`
///   （字段与旧口同形：songmid/songname/singer[]/albummid/albumname/interval）
/// - 搜索备：`POST u.y.qq.com/cgi-bin/musicu.fcg` `music.search.SearchCgiService`
///   `DoSearchForQQMusicDesktop`（匿名高频后可能回 `req.code 2001` 要求登录，
///   故仅作兜底，不对空结果触发）
/// - 歌词主：同上 musicu `music.musichallSong.PlayLyricInfo.GetPlayLyricInfo`
///   （只需 songMID，加 `trans:1` 取译文；`lyric`/`trans` 均为明文 base64
///   LRC，`crypt=0`——无需洛雪那套 QRC 解密）
/// - 歌词备：`GET c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?...&nobase64=1`
/// - 封面：搜索顺手缓存 songmid→albumMid，取图直拼
///   `y.gtimg.cn/music/photo_new/T002R800x800M000{mid}.jpg`；缓存未命中回落
///   `GET c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg?songmid=` 取 album.mid
class QqProvider {
  static const String apiBase = 'https://c.y.qq.com';
  static const String musicuUrl = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36';
  static const String referer = 'https://y.qq.com/';

  final Dio dio;

  /// 搜索期缓存：songmid → albumMid（取封面时省一步详情请求）。
  final Map<String, String> _albumMidBySong = {};

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
  ///
  /// 主口异常/非 0 码时自动换 musicu 备；「歌手+标题」空结果时仅标题重试
  /// （实测个别冷门组合词会漏、单标题能中）。空结果不触发备胎（省风控额度）。
  Future<List<OnlineLyricCandidate>> searchTracks({
    required String title,
    String? artist,
    String? album,
    int limit = 10,
  }) async {
    final t = title.trim();
    if (t.isEmpty) return const [];
    final a = (artist ?? '').trim();
    final n = limit.clamp(1, 20);

    try {
      return await _searchLegacyWithRetry(t, a, n);
    } catch (_) {
      // 主口不可用（其姊妹口 client_search_cp 已恒 500），换备胎。
    }
    try {
      return await _searchMusicuWithRetry(t, a, n);
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        throw StateError('QQ音乐拒绝请求（HTTP 403），稍后重试或切换来源');
      }
      rethrow;
    }
  }

  // ---------- 搜索：主口 ----------

  Future<List<OnlineLyricCandidate>> _searchLegacyWithRetry(
      String title, String artist, int limit) async {
    final kw = artist.isEmpty ? title : '$artist $title';
    var list = await _searchLegacy(kw, limit);
    if (list.isEmpty && artist.isNotEmpty) {
      list = await _searchLegacy(title, limit);
    }
    return list;
  }

  Future<List<OnlineLyricCandidate>> _searchLegacy(String kw, int limit) async {
    final resp = await dio.get(
      '$apiBase/soso/fcgi-bin/search_for_qq_cp',
      queryParameters: {'w': kw, 'p': '1', 'n': '$limit', 'format': 'json'},
    );
    final data = _asMap(resp.data);
    if (data == null) {
      throw const FormatException('QQ音乐搜索响应异常');
    }
    final code = data['code'];
    if (code is num && code != 0) {
      throw StateError('QQ音乐搜索失败（code $code）');
    }
    final song = data['data'] is Map ? (data['data'] as Map)['song'] : null;
    final list = song is Map ? song['list'] : null;
    if (list is! List) throw const FormatException('QQ音乐搜索响应异常');
    return _parseLegacyList(list, limit);
  }

  List<OnlineLyricCandidate> _parseLegacyList(List raw, int limit) {
    final out = <OnlineLyricCandidate>[];
    for (final e in raw) {
      if (e is! Map<String, dynamic>) continue;
      final mid = _str(e['songmid']);
      final name = _str(e['songname']);
      if (mid.isEmpty || name.isEmpty) continue;
      _cacheAlbumMid(mid, _str(e['albummid']));
      final interval = (e['interval'] as num?)?.toDouble();
      out.add(OnlineLyricCandidate(
        onlineId: mid,
        source: OnlineMetaSource.qq,
        trackName: name,
        artistName: _namesOf(e['singer']),
        albumName: _str(e['albumname']),
        durationSec: interval == null || interval <= 0 ? null : interval,
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  // ---------- 搜索：musicu 备 ----------

  Future<List<OnlineLyricCandidate>> _searchMusicuWithRetry(
      String title, String artist, int limit) async {
    final kw = artist.isEmpty ? title : '$artist $title';
    var list = await _searchMusicu(kw, limit);
    if (list.isEmpty && artist.isNotEmpty) {
      list = await _searchMusicu(title, limit);
    }
    return list;
  }

  Future<List<OnlineLyricCandidate>> _searchMusicu(String kw, int limit) async {
    final resp = await dio.post(
      musicuUrl,
      data: {
        'comm': {'ct': '19', 'cv': '1859', 'uin': '0'},
        'req': {
          'method': 'DoSearchForQQMusicDesktop',
          'module': 'music.search.SearchCgiService',
          'param': {
            'num_per_page': limit,
            'page_num': 1,
            'query': kw,
            'search_type': 0,
          },
        },
      },
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = _asMap(resp.data);
    if (data == null) {
      throw const FormatException('QQ音乐搜索响应异常');
    }
    final req = data['req'];
    if (req is! Map) throw const FormatException('QQ音乐搜索响应异常');
    final code = req['code'];
    if (code != 0) {
      if (code == 2001) {
        throw StateError('QQ音乐搜索被要求登录（风控限流），稍后重试或切换来源');
      }
      throw StateError('QQ音乐搜索失败（code $code），稍后重试或切换来源');
    }
    final body = req['data'] is Map ? (req['data'] as Map)['body'] : null;
    final song = body is Map ? body['song'] : null;
    final list = song is Map ? song['list'] : null;
    if (list is! List) throw const FormatException('QQ音乐搜索响应异常');
    final out = <OnlineLyricCandidate>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      final mid = _str(e['mid']);
      final name = _str(e['name']);
      if (mid.isEmpty || name.isEmpty) continue;
      final albumField = e['album'];
      if (albumField is Map) _cacheAlbumMid(mid, _str(albumField['mid']));
      final interval = (e['interval'] as num?)?.toDouble();
      out.add(OnlineLyricCandidate(
        onlineId: mid,
        source: OnlineMetaSource.qq,
        trackName: name,
        artistName: _namesOf(e['singer']),
        albumName: albumField is Map ? _str(albumField['name']) : '',
        durationSec: interval == null || interval <= 0 ? null : interval,
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  // ---------- 歌词 ----------

  /// 取歌词：musicu（base64 主）→ 旧接口（明文备）。
  /// `lyric` → 同步（无时间轴时退为纯文本），`trans` → 译文。
  Future<({String? syncedLyrics, String? plainLyrics})> fetchLyric(
      String songmid) async {
    final mid = songmid.trim();
    if (mid.isEmpty) return (syncedLyrics: null, plainLyrics: null);

    Object? primaryError;
    try {
      final r = await _lyricMusicu(mid);
      if (r != null) return r;
    } catch (e) {
      primaryError = e;
    }
    try {
      return await _lyricLegacy(mid);
    } catch (e) {
      // 两条腿都失败：优先抛首错（网络语义），由调用方给「取词失败」提示。
      throw primaryError ?? e;
    }
  }

  Future<({String? syncedLyrics, String? plainLyrics})?> _lyricMusicu(
      String mid) async {
    final resp = await dio.post(
      musicuUrl,
      data: {
        'comm': {'ct': '19', 'cv': '1859', 'uin': '0'},
        'req': {
          'method': 'GetPlayLyricInfo',
          'module': 'music.musichallSong.PlayLyricInfo',
          'param': {'songMID': mid, 'trans': 1},
        },
      },
      options: Options(contentType: Headers.jsonContentType),
    );
    final data = _asMap(resp.data);
    if (data == null) return null;
    final req = data['req'];
    if (req is! Map || req['code'] != 0) return null;
    final d = req['data'];
    if (d is! Map) return null;
    // 加密歌词（crypt≠0）需 QRC 解密，本实现不覆盖：交给旧接口备胎。
    final crypt = d['crypt'];
    if (crypt is num && crypt != 0) return null;
    final lyric = _b64(d['lyric']);
    if (lyric.isEmpty) return null;
    return _mapLyric(lyric, _b64(d['trans']));
  }

  Future<({String? syncedLyrics, String? plainLyrics})> _lyricLegacy(
      String mid) async {
    final resp = await dio.get(
      '$apiBase/lyric/fcgi-bin/fcg_query_lyric_new.fcg',
      queryParameters: {
        'songmid': mid,
        'format': 'json',
        'nobase64': '1',
        'g_tk': '5381',
      },
    );
    final data = _asMap(resp.data);
    if (data == null) {
      return (syncedLyrics: null, plainLyrics: null);
    }
    final lyric = _decodeMaybe(_str(data['lyric']));
    final trans = _decodeMaybe(_str(data['trans']));
    return _mapLyric(lyric, trans);
  }

  /// 同步/纯文本映射（与网易云同口径）：有 LRC 时间轴取同步，译文入
  /// `plainLyrics`（保存时同步优先，现库无译文轨）。
  static ({String? syncedLyrics, String? plainLyrics}) _mapLyric(
      String lyric, String trans) {
    final hasSync = lyric.isNotEmpty && lyric.contains('[');
    return (
      syncedLyrics: hasSync ? lyric : null,
      plainLyrics: hasSync
          ? (trans.isEmpty ? null : trans)
          : (lyric.isEmpty ? (trans.isEmpty ? null : trans) : lyric),
    );
  }

  // ---------- 封面 ----------

  /// 取封面字节：搜索缓存 albumMid 直连 CDN；未命中回落单曲详情两步。
  /// 无封面返回 null（不抛错）；网络错误向上抛（403/404 视为无图）。
  Future<Uint8List?> fetchCoverBytes(String songmid) async {
    final mid = songmid.trim();
    if (mid.isEmpty) return null;
    final cached = _albumMidBySong[mid];
    if (cached != null && cached.isNotEmpty) {
      final b = await _fetchGtimgCover(cached);
      if (b != null) return b;
    }
    final albumMid = await _albumMidViaDetail(mid);
    if (albumMid == null || albumMid.isEmpty || albumMid == '空') return null;
    return _fetchGtimgCover(albumMid);
  }

  Future<String?> _albumMidViaDetail(String songmid) async {
    final resp = await dio.get(
      '$apiBase/v8/fcg-bin/fcg_play_single_song.fcg',
      queryParameters: {'songmid': songmid, 'format': 'json'},
    );
    final data = _asMap(resp.data);
    if (data == null) return null;
    final list = data['data'];
    if (list is! List || list.isEmpty) return null;
    final first = list.first;
    if (first is! Map) return null;
    final album = first['album'];
    final mid = album is Map ? _str(album['mid']) : '';
    return mid.isEmpty ? null : mid;
  }

  Future<Uint8List?> _fetchGtimgCover(String albumMid) async {
    const base = 'https://y.gtimg.cn/music/photo_new/T002R800x800M000';
    try {
      final img = await dio.get<List<int>>('$base$albumMid.jpg',
          options: Options(responseType: ResponseType.bytes));
      final bytes = img.data;
      if (bytes == null || bytes.isEmpty) return null;
      return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 404 || code == 403) return null; // 该专辑无图，非故障。
      rethrow;
    }
  }

  // ---------- helpers ----------

  void _cacheAlbumMid(String songmid, String albumMid) {
    if (albumMid.isEmpty || albumMid == '空') return;
    _albumMidBySong[songmid] = albumMid;
  }

  static String _str(Object? v) => v is String ? v.trim() : '';

  /// QQ 各 CGI 的 `Content-Type` 常为 `application/x-javascript` 或
  /// `text/plain`，Dio 不自动解 JSON——String 时手解一次（mock/标准 JSON
  /// 已是 Map，直接透传）。
  static Map<String, dynamic>? _asMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is String && data.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {}
    }
    return null;
  }

  static String _namesOf(Object? singers) {
    if (singers is! List) return '';
    final names = <String>[];
    for (final s in singers) {
      final n = s is Map ? _str(s['name']) : '';
      if (n.isNotEmpty) names.add(n);
    }
    return names.join('/');
  }

  /// musicu 的 `lyric`/`trans` 为 base64（明文 LRC）；解码失败原文返回
  /// （防御口径变化）。
  static String _b64(Object? v) {
    final raw = _str(v);
    if (raw.isEmpty) return '';
    try {
      return utf8.decode(base64.decode(base64.normalize(raw))).trim();
    } catch (_) {
      return raw;
    }
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
