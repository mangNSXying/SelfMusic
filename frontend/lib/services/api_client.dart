import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 表示会话已过期且无法续签，需重新配对。
class SessionExpiredException implements Exception {
  final String message;
  SessionExpiredException([this.message = 'refresh token expired']);
  @override
  String toString() => message;
}

class ApiClient {
  // 编译期默认后端地址（可通过 --dart-define 覆盖）。空串表示未配置，
  // 实际地址由「服务端」设置中的运行时 ServerSettings 提供（[setBaseUrl]）。
  static const _baseUrlEnv = String.fromEnvironment('API_BASE_URL', defaultValue: '');

  static const kAccess = 'device_token';
  static const kRefresh = 'refresh_token';
  static const kClientId = 'client_id';

  final Dio dio;
  final FlutterSecureStorage storage;

  Future<bool>? _inflightRefresh;
  void Function()? onSessionExpired;

  /// 把 [url] 规整为合法的绝对 URL：缺少 scheme 时补 `http://`，并去掉末尾 `/`，
  /// 避免用户传入 `192.168.3.25:18089` 这类无协议地址导致 dio 报错。
  static String normalizeBaseUrl(String url) {
    var s = url.trim();
    if (s.isEmpty) return s;
    if (!s.contains('://')) {
      s = 'http://$s';
    }
    return s.endsWith('/') ? s.substring(0, s.length - 1) : s;
  }

  ApiClient({Dio? dio, FlutterSecureStorage? storage})
      : dio = dio ??
            Dio(BaseOptions(
              baseUrl: normalizeBaseUrl(_baseUrlEnv),
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
            )),
        storage = storage ?? const FlutterSecureStorage() {
    this.dio.interceptors.add(InterceptorsWrapper(
      onRequest: (opts, h) async {
        final token = await getAccessToken();
        if (token != null && token.isNotEmpty) {
          opts.headers['Authorization'] = 'Bearer $token';
        }
        h.next(opts);
      },
      onError: (err, h) async {
        // 仅对会触发续签的请求（有 Bearer 头）且是 401 且带过期标记时续签
        final req = err.requestOptions;
        final hasToken = req.headers['Authorization'] != null;
        final expired = err.response?.headers.value('X-Token-Expired') == 'true';
        if (err.response?.statusCode == 401 && hasToken && expired) {
          try {
            final refreshed = await _refresh();
            if (refreshed) {
              final newToken = await getAccessToken();
              req.headers['Authorization'] = 'Bearer $newToken';
              final resp = await _retry(req);
              return h.resolve(resp);
            }
          } on SessionExpiredException {
            await clearTokens();
            onSessionExpired?.call();
          }
        }
        h.next(err);
      },
    ));
  }

  String get baseUrl => dio.options.baseUrl;

  /// 运行时可改后端地址（规整为绝对 URL），空串表示未配置。
  void setBaseUrl(String url) {
    dio.options.baseUrl = normalizeBaseUrl(url);
  }

  Future<String?> getAccessToken() => storage.read(key: kAccess);
  Future<String?> getRefreshToken() => storage.read(key: kRefresh);
  Future<String?> getClientId() => storage.read(key: kClientId);
  Future<String?> getToken() => storage.read(key: kAccess);

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required String clientId,
  }) async {
    await storage.write(key: kAccess, value: accessToken);
    await storage.write(key: kRefresh, value: refreshToken);
    await storage.write(key: kClientId, value: clientId);
  }

  Future<void> clearTokens() async {
    await storage.delete(key: kAccess);
    await storage.delete(key: kRefresh);
    await storage.delete(key: kClientId);
  }

  // 原子化“单飞”刷新：并发请求共享同一次 refresh，避免重复轮换。
  Future<bool> _refresh() {
    final inflight = _inflightRefresh;
    if (inflight != null) return inflight;
    final f = _doRefresh();
    _inflightRefresh = f;
    return f.whenComplete(() => _inflightRefresh = null);
  }

  Future<bool> _doRefresh() async {
    final refreshToken = await getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw SessionExpiredException();
    }
    Response<dynamic> resp;
    try {
      resp = await dio.post('/api/v1/auth/refresh', data: {
        'refresh_token': refreshToken,
      });
    } catch (e) {
      // 刷新失败（refresh token 无效/过期等）一律视为会话过期，须重新配对。
      throw SessionExpiredException(e.toString());
    }
    final data = resp.data['data'] as Map<String, dynamic>;
    final access = data['access_token'] as String;
    final refresh = data['refresh_token'] as String;
    final clientId = (data['client_id'] ?? await getClientId()) as String;
    await saveTokens(accessToken: access, refreshToken: refresh, clientId: clientId);
    return true;
  }

  Future<Response<dynamic>> _retry(RequestOptions req) async {
    final dioForRetry =
        Dio(BaseOptions(baseUrl: dio.options.baseUrl, connectTimeout: dio.options.connectTimeout, receiveTimeout: dio.options.receiveTimeout));
    return dioForRetry.fetch(req);
  }

  // ---------- 设置同步 / 配对密钥（settings.md §3.5 / DESIGN 暂缓项） ----------

  /// 拉取服务端缓存建议值（settings.md §5 / §3.3 follow_server）。
  Future<Map<String, dynamic>?> fetchServerConfig() async {
    if (dio.options.baseUrl.isEmpty) return null;
    try {
      final resp = await dio.get('/api/v1/admin/config');
      return (resp.data['data'] as Map<String, dynamic>?) ?? {};
    } catch (_) {
      return null;
    }
  }

  /// 拉取当前配对密钥（DESIGN §8「暂缓项」）。
  Future<String?> fetchPairingToken() async {
    if (dio.options.baseUrl.isEmpty) return null;
    try {
      final resp = await dio.get('/api/v1/admin/pairing-token');
      return (resp.data['data'] as Map<String, dynamic>?)?['pairing_token'] as String?;
    } catch (_) {
      return null;
    }
  }
}
