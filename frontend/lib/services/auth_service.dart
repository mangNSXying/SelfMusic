import 'package:dio/dio.dart';
import '../utils/platform_info.dart';

class AuthService {
  final Dio dio;
  AuthService(this.dio);

  Future<Map<String, String>> pair({
    required String pairingToken,
    required String deviceName,
    String? platform,
  }) async {
    final String effectivePlatform = platform ?? PlatformInfo.platform;
    final resp = await dio.post('/api/v1/auth/pair', data: {
      'pairing_token': pairingToken,
      'device_name': deviceName,
      'platform': effectivePlatform,
    });
    final data = resp.data['data'] as Map<String, dynamic>;
    return {
      'client_id': data['client_id'] as String,
      'device_token': data['device_token'] as String,
      'access_token': data['device_token'] as String,
      'refresh_token': data['refresh_token'] as String,
      'expires_in': data['expires_in']?.toString() ?? '',
      'refresh_expires_in': data['refresh_expires_in']?.toString() ?? '',
    };
  }

  // 供 AuthProvider.refreshSession 使用；成功返回 true，失败抛异常。
  Future<void> unpair() async {
    await dio.post('/api/v1/auth/unpair');
  }
}
