import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../../data/local/app_settings.dart';
import '../secret_store.dart';
import 'online_music_models.dart';

/// 在线音乐 sidecar 客户端（L1：搜索 + 下载）。
///
/// 所有 `/v1/*` 请求带 Bearer token；搜索走 SSE，结果逐条回调。
class OnlineMusicService {
  final AppSettings settings;
  final SecretStore secrets;
  final Dio _dio;

  OnlineMusicService({
    required this.settings,
    SecretStore? secrets,
    Dio? dio,
  })  : secrets = secrets ?? SecretStore(),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
            )) {
    // 与 ApiClient 同口径：设置 → 服务端 → 信任自签名证书。
    // 注入的 Dio（测试/自定义 adapter）保持原样。
    if (dio == null) {
      _dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..badCertificateCallback =
              (cert, host, port) => settings.allowSelfSigned,
      );
    }
  }

  /// 用户输入 `192.168.1.2:18090` 时补 `http://`；去掉尾部斜杠。
  static String normalizeBaseUrl(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return '';
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'http://$v';
    }
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    return v;
  }

  String get baseUrl => normalizeBaseUrl(settings.onlineMusicBaseUrl);

  bool get configured => baseUrl.isNotEmpty;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl;
    if (base.isEmpty) {
      throw const OnlineMusicException('未配置在线音乐 sidecar 地址');
    }
    final uri = Uri.tryParse('$base$path');
    if (uri == null) {
      throw const OnlineMusicException('sidecar 地址格式不正确');
    }
    return query == null ? uri : uri.replace(queryParameters: query);
  }

  Future<Map<String, String>> _headers() async {
    final token = (await secrets.onlineMusicToken())?.trim() ?? '';
    if (token.isEmpty) {
      throw const OnlineMusicException('未配置在线音乐 token');
    }
    return {'Authorization': 'Bearer $token'};
  }

  OnlineMusicException _fromDio(DioException err) {
    final status = err.response?.statusCode;
    final data = err.response?.data;
    var message = '';
    if (data is Map) {
      final detail = data['detail'];
      final error = data['error'];
      if (detail is String) message = detail;
      if (message.isEmpty && error is Map && error['message'] is String) {
        message = error['message'] as String;
      }
    }
    if (message.isEmpty) {
      message = switch (status) {
        401 => 'sidecar token 无效',
        404 => 'sidecar 接口不存在',
        410 => '曲目已过期，请重新搜索',
        409 => '任务尚未完成',
        _ => '连接 sidecar 失败：${err.message ?? err.type.name}',
      };
    }
    return OnlineMusicException(message, statusCode: status);
  }

  Future<List<OnlineSourceInfo>> fetchSources() async {
    try {
      final resp = await _dio.getUri<Map<String, dynamic>>(
        _uri('/v1/sources'),
        options: Options(headers: await _headers()),
      );
      final data = resp.data ?? const <String, dynamic>{};
      final raw = data['sources'];
      if (raw is! List) return const [];
      return [
        for (final item in raw)
          if (item is Map<String, dynamic>) OnlineSourceInfo.fromJson(item),
      ];
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Stream<OnlineSearchEvent> search({
    required String query,
    required List<String> sources,
    int limit = 10,
    CancelToken? cancelToken,
  }) async* {
    final headers = await _headers();
    final uri = _uri('/v1/search', {
      'q': query,
      'sources': sources.join(','),
      'limit': '$limit',
    });
    Response<ResponseBody> resp;
    try {
      resp = await _dio.getUri<ResponseBody>(
        uri,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(minutes: 5),
        ),
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      throw _fromDio(e);
    }
    if (resp.statusCode != 200 || resp.data == null) {
      throw OnlineMusicException(
        '搜索失败（HTTP ${resp.statusCode ?? '?'}）',
        statusCode: resp.statusCode,
      );
    }

    try {
      await for (final event
          in parseSseStream(resp.data!.stream.cast<List<int>>())) {
        yield event;
      }
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  /// 解析 sidecar 的 SSE 流（测试可直接喂内存流）。
  static Stream<OnlineSearchEvent> parseSseStream(
      Stream<List<int>> bytes) async* {
    var event = '';
    final dataLines = <String>[];
    final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) {
        final parsed = _parseEvent(event, dataLines.join('\n'));
        event = '';
        dataLines.clear();
        if (parsed != null) yield parsed;
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trimLeft());
      }
    }
    final parsed = _parseEvent(event, dataLines.join('\n'));
    if (parsed != null) yield parsed;
  }

  static OnlineSearchEvent? _parseEvent(String event, String data) {
    if (event.isEmpty || data.isEmpty) return null;
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map<String, dynamic>) return null;
      json = decoded;
    } catch (_) {
      return null;
    }
    switch (event) {
      case 'source_start':
        return OnlineSourceStart(
          (json['source'] as String?) ?? '',
          (json['source_label'] as String?) ?? '',
        );
      case 'source_done':
        return OnlineSourceDone(
          (json['source'] as String?) ?? '',
          (json['count'] as num?)?.toInt() ?? 0,
          json['timed_out'] == true,
        );
      case 'source_error':
        return OnlineSourceError(
          (json['source'] as String?) ?? '',
          (json['message'] as String?) ?? '该音乐源不可用',
        );
      case 'result':
        return OnlineTrackEvent(OnlineTrack.fromJson(json));
      case 'done':
        return OnlineSearchDone((json['count'] as num?)?.toInt() ?? 0);
      default:
        return null;
    }
  }

  Future<OnlineFetchJob> createFetch(String trackToken) async {
    try {
      final resp = await _dio.postUri<Map<String, dynamic>>(
        _uri('/v1/fetch'),
        data: {'track_token': trackToken},
        options: Options(headers: await _headers()),
      );
      return OnlineFetchJob.fromJson(resp.data ?? const {});
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Future<OnlineFetchJob> fetchStatus(String jobId) async {
    try {
      final resp = await _dio.getUri<Map<String, dynamic>>(
        _uri('/v1/fetch/$jobId'),
        options: Options(headers: await _headers()),
      );
      return OnlineFetchJob.fromJson(resp.data ?? const {});
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Future<void> downloadFile(
    String jobId,
    String savePath, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      await _dio.downloadUri(
        _uri('/v1/fetch/$jobId/file'),
        savePath,
        options: Options(headers: await _headers()),
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
      );
    } on DioException catch (e) {
      throw _fromDio(e);
    }
  }

  Future<String?> fetchLyric(String jobId) async {
    try {
      final resp = await _dio.getUri<String>(
        _uri('/v1/fetch/$jobId/lyric'),
        options: Options(
          headers: await _headers(),
          responseType: ResponseType.plain,
        ),
      );
      return resp.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      throw _fromDio(e);
    }
  }
}
