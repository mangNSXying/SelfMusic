import 'package:flutter/foundation.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  final ApiClient api;
  late final AuthService auth;
  String? _token;
  bool _loading = false;
  bool _bootstrapped = false; // 首次从存储加载 token 是否完成
  bool _sessionExpired = false;
  String? _error;

  AuthProvider(this.api) {
    auth = AuthService(api.dio);
    api.onSessionExpired = _onSessionExpired;
    _loadToken();
  }

  void _onSessionExpired() {
    _token = null;
    _sessionExpired = true;
    notifyListeners();
  }

  String? get token => _token;
  bool get isPaired => _token != null && _token!.isNotEmpty;
  bool get loading => _loading;
  bool get bootstrapped => _bootstrapped; // 尚无令牌时据此避免闪配对页
  bool get sessionExpired => _sessionExpired;
  String? get error => _error;

  Future<void> _loadToken() async {
    // Linux/libsecret 冷启动时 keyring 可能尚未解锁，做几次带小延时的重试，
    // 避免一次性读取失败就把用户误判为“未配对”。
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        _token = await api.getToken();
        break;
      } catch (e) {
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        } else {
          debugPrint('loadToken failed: $e');
        }
      }
    }
    _bootstrapped = true;
    notifyListeners();
  }

  Future<bool> pair(String pairingToken, String deviceName) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final res = await auth.pair(pairingToken: pairingToken, deviceName: deviceName);
      _token = res['device_token']!;
      await api.saveTokens(
        accessToken: res['device_token']!,
        refreshToken: res['refresh_token']!,
        clientId: res['client_id']!,
      );
      _sessionExpired = false;
      _bootstrapped = true;
      _loading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  // 访问令牌过期后的自动续签由 ApiClient 拦截器透明处理；
  // 仅当刷新失败（refresh token 失效/过期）时，ApiClient 触发 onSessionExpired，
  // 本 provider 置 _sessionExpired=true，Root 据此弹窗引导重新配对。

  Future<void> unpair() async {
    try {
      await auth.unpair();
    } catch (_) {}
    await api.clearTokens();
    _token = null;
    notifyListeners();
  }

  void acceptSessionExpired() {
    _sessionExpired = false;
    notifyListeners();
  }
}
