import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 敏感凭据的统一存储（flutter_secure_storage），替代明文落盘（问题.md B1/B2）：
/// - WebDAV 密码：`webdav_pwd:<sourceKey>`（`sources.config` 不再含明文密码）
/// - 配对密钥：`pairing_key`（`server_settings.json` 不再含明文密钥，仅存非敏感 baseUrl）
///
/// 构造可注入 [FlutterSecureStorage]，便于测试用 fake 替换。
class SecretStore {
  static const String pairingKeyId = 'pairing_key';
  static const String _webdavPwdPrefix = 'webdav_pwd:';

  final FlutterSecureStorage storage;

  SecretStore({FlutterSecureStorage? storage})
      : storage = storage ?? const FlutterSecureStorage();

  String _webdavKey(String sourceKey) => '$_webdavPwdPrefix$sourceKey';

  Future<String?> webdavPassword(String sourceKey) =>
      storage.read(key: _webdavKey(sourceKey));

  /// 写密码；空串/不含内容即删除该键。
  Future<void> setWebdavPassword(String sourceKey, String? password) async {
    final key = _webdavKey(sourceKey);
    final v = (password ?? '').trim();
    if (v.isEmpty) {
      await storage.delete(key: key);
    } else {
      await storage.write(key: key, value: v);
    }
  }

  /// 源改名（key 变化）时迁移 WebDAV 密码键，并清理旧键。
  Future<void> migrateWebdav(String oldKey, String newKey) async {
    if (oldKey == newKey) return;
    final v = await webdavPassword(oldKey);
    if (v != null && v.isNotEmpty) {
      await storage.write(key: _webdavKey(newKey), value: v);
    }
    await storage.delete(key: _webdavKey(oldKey));
  }

  Future<void> deleteWebdav(String sourceKey) =>
      storage.delete(key: _webdavKey(sourceKey));

  Future<String?> pairingKey() => storage.read(key: pairingKeyId);

  Future<void> setPairingKey(String? key) async {
    final v = (key ?? '').trim();
    if (v.isEmpty) {
      await storage.delete(key: pairingKeyId);
    } else {
      await storage.write(key: pairingKeyId, value: v);
    }
  }
}