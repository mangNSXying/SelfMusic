import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/harmonyos/secure_storage_ohos.dart'
    show createSecureStorage;

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

  /// 校验端点为「安全链路策略」允许的形式；返回错误提示，合法返回 null。
  ///
  /// - 空串：允许（表示未配置）。
  /// - 无 scheme：允许（归一化时会补默认 `https://`）。
  /// - 显式 `http://`：仅当 [allowHttp]（「允许不安全 HTTP」开关）为真时允许。
  /// - 其余 scheme（https 等）：允许。
  static String? validateEndpointUrl(String url, {required bool allowHttp}) {
    final s = url.trim();
    if (s.isEmpty) return null;
    final i = s.indexOf('://');
    if (i > 0) {
      final scheme = s.substring(0, i).toLowerCase();
      if (scheme == 'http' && !allowHttp) {
        return '明文 HTTP 已被默认关闭；如确需使用，请在「允许不安全 HTTP」中启用，或改用 https://';
      }
    }
    return null;
  }

  /// 把 [url] 规整为合法的绝对 URL：缺少 scheme 时补 `https://`（默认安全链路），
  /// 并去掉末尾 `/`，避免用户传入 `192.168.3.25:18443` 这类无协议地址导致 dio 报错。
  /// 需要明文 HTTP 时用户须显式写 `http://`（受「允许不安全 HTTP」开关约束，见 settings.md §3.3）。
  static String normalizeBaseUrl(String url) {
    var s = url.trim();
    if (s.isEmpty) return s;
    if (!s.contains('://')) {
      s = 'https://$s';
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
        storage = storage ?? createSecureStorage() {
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

  bool _allowSelfSigned = false;

  /// 信任自签名证书开关（settings.md §3.3）：为 true 时本 dio 的 TLS 请求接受
  /// 任意证书（dart:io [HttpClient.badCertificateCallback]）。替换 adapter 仅对
  /// 之后发出的请求生效，适合在启动阶段按 [AppSettings.allowSelfSigned] 配置一次。
  void setSelfSignedPolicy(bool allow) {
    _allowSelfSigned = allow;
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..badCertificateCallback =
            (cert, host, port) => _allowSelfSigned,
    );
  }

  /// 运行时可改后端地址（规整为绝对 URL），空串表示未配置。
  void setBaseUrl(String url) {
    dio.options.baseUrl = normalizeBaseUrl(url);
  }

  // ---------- 凭据读取（内存缓存） ----------
  //
  // flutter_secure_storage 每次 read 都是一次平台通道 + KeyStore 解密，冷启动
  // 首读实测 ~2s；且每个 HTTP 请求的拦截器都要读 access token。凭据只会在本类
  // 写入（saveTokens/clearTokens），按 key 懒加载缓存并在写入时同步更新，读路径
  // 零通道开销。用 containsKey 区分「已加载为 null」与「未加载」。
  final Map<String, String?> _tokenCache = {};
  final Map<String, Future<String?>> _tokenLoading = {};

  Future<String?> _readToken(String key) {
    if (_tokenCache.containsKey(key)) {
      return Future<String?>.value(_tokenCache[key]);
    }
    final inflight = _tokenLoading[key];
    if (inflight != null) return inflight;
    final f = storage.read(key: key).then((v) {
      _tokenCache[key] = v;
      return v;
    }).whenComplete(() {
      // 块体！箭头体会把 remove 的返回值（就是 f 本身）当 Future 返回，
      // whenComplete 会等它 → 自引用死锁，首读永不完成（启动转圈根因）。
      _tokenLoading.remove(key);
    });
    _tokenLoading[key] = f;
    return f;
  }

  Future<String?> getAccessToken() => _readToken(kAccess);
  Future<String?> getRefreshToken() => _readToken(kRefresh);
  Future<String?> getClientId() => _readToken(kClientId);
  Future<String?> getToken() => _readToken(kAccess);

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required String clientId,
  }) async {
    _tokenCache[kAccess] = accessToken;
    _tokenCache[kRefresh] = refreshToken;
    _tokenCache[kClientId] = clientId;
    await storage.write(key: kAccess, value: accessToken);
    await storage.write(key: kRefresh, value: refreshToken);
    await storage.write(key: kClientId, value: clientId);
  }

  Future<void> clearTokens() async {
    _tokenCache[kAccess] = null;
    _tokenCache[kRefresh] = null;
    _tokenCache[kClientId] = null;
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

  // ---------- 配对密钥（settings.md §3.5） ----------

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

  // ---------- 多设备状态同步（阶段5，DESIGN §7.2 / SyncEngine） ----------
  //
  // 与上面可空吞错的读取类方法不同：同步走引擎退避，Dio 异常直接上抛，
  // 由 SyncEngine 捕获记退避（未配对时返回 null 表示跳过）。

  /// 批量上推事件。返回 data（cursor/applied/duplicates/rejected/corrections）。
  Future<Map<String, dynamic>?> syncPush(
      String clientId, List<Map<String, dynamic>> events) async {
    if (dio.options.baseUrl.isEmpty) return null;
    final resp = await dio.post('/api/v1/sync/push', data: {
      'events': events,
    });
    return resp.data['data'] as Map<String, dynamic>?;
  }

  /// 增量拉取（since_cursor）。返回 data（cursor/has_more/songs/playlists/playstates）。
  Future<Map<String, dynamic>?> syncPull(int cursor) async {
    if (dio.options.baseUrl.isEmpty) return null;
    final resp = await dio.get('/api/v1/sync/pull',
        queryParameters: {'since_cursor': cursor});
    return resp.data['data'] as Map<String, dynamic>?;
  }

  /// 断点快路径：直接取服务端全局最新断点快照（1 RTT，不受 pull 的
  /// cursor backlog 分页影响）。data 为空/歌单不可同步 → null；
  /// 旧服务端无此端点（404）→ null，调用方回退到 pull 路径。
  Future<Map<String, dynamic>?> fetchLatestBreakpoint() async {
    if (dio.options.baseUrl.isEmpty) return null;
    try {
      final resp = await dio.get('/api/v1/playstates/latest');
      return resp.data['data'] as Map<String, dynamic>?;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  // ---------- 已配对设备管理（阶段5，设备管理页） ----------

  /// 设备列表（id/clientId/name/platform/revoked/pairedAt/lastSeenAt）。
  Future<List<dynamic>?> fetchDevices() async {
    if (dio.options.baseUrl.isEmpty) return null;
    final resp = await dio.get('/api/v1/admin/devices');
    return resp.data['data'] as List<dynamic>?;
  }

  /// 设备改名。
  Future<void> renameDevice(int id, String name) async {
    await dio.put('/api/v1/admin/devices/$id', data: {'name': name});
  }

  /// 吊销设备（服务端 revoked=true；被吊销设备 token 即刻失效）。
  Future<void> revokeDevice(int id) async {
    await dio.delete('/api/v1/admin/devices/$id');
  }
}
