import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/harmonyos/secure_storage_ohos.dart'
    show createSecureStorage;

/// 敏感凭据的统一存储（flutter_secure_storage），替代明文落盘（问题.md B1/B2）：
/// - WebDAV 密码：`webdav_pwd:<sourceKey>`（`sources.config` 不再含明文密码）
/// - SFTP 密码 / 私钥文本 / 私钥 passphrase：`sftp_pwd:<sourceKey>` /
///   `sftp_key:<sourceKey>` / `sftp_keypp:<sourceKey>`（同上，永不同步）
/// - SMB 密码：`smb_pwd:<sourceKey>`（同上，永不同步；用户名与密码双空即匿名）
/// - 配对密钥：`pairing_key`（`server_settings.json` 不再含明文密钥，仅存非敏感 baseUrl）
///
/// 构造可注入 [FlutterSecureStorage]，便于测试用 fake 替换；默认实例走
/// [createSecureStorage]（ohos 上绕过包前端，见 secure_storage_ohos.dart）。
class SecretStore {
  static const String pairingKeyId = 'pairing_key';
  static const String _webdavPwdPrefix = 'webdav_pwd:';
  static const String _sftpPwdPrefix = 'sftp_pwd:';
  static const String _sftpKeyPrefix = 'sftp_key:';
  static const String _sftpKeyPpPrefix = 'sftp_keypp:';
  static const String _smbPwdPrefix = 'smb_pwd:';

  final FlutterSecureStorage storage;

  SecretStore({FlutterSecureStorage? storage})
      : storage = storage ?? createSecureStorage();

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

  String _sftpKey(String prefix, String sourceKey) => '$prefix$sourceKey';

  Future<String?> sftpPassword(String sourceKey) =>
      storage.read(key: _sftpKey(_sftpPwdPrefix, sourceKey));

  Future<String?> sftpKeyPem(String sourceKey) =>
      storage.read(key: _sftpKey(_sftpKeyPrefix, sourceKey));

  Future<String?> sftpKeyPassphrase(String sourceKey) =>
      storage.read(key: _sftpKey(_sftpKeyPpPrefix, sourceKey));

  /// 写 SFTP 三件套（空即删键）；调用方按认证方式只传对应项。
  Future<void> setSftpSecrets(String sourceKey,
      {String? password, String? keyPem, String? passphrase}) async {
    await _setOrDelete(
        _sftpKey(_sftpPwdPrefix, sourceKey), password?.trim());
    await _setOrDelete(_sftpKey(_sftpKeyPrefix, sourceKey), keyPem?.trim());
    await _setOrDelete(
        _sftpKey(_sftpKeyPpPrefix, sourceKey), passphrase?.trim());
  }

  Future<void> _setOrDelete(String key, String? v) async {
    if (v == null || v.isEmpty) {
      await storage.delete(key: key);
    } else {
      await storage.write(key: key, value: v);
    }
  }

  /// 源改名（key 变化）时迁移 SFTP 三件套，并清理旧键。
  Future<void> migrateSftp(String oldKey, String newKey) async {
    if (oldKey == newKey) return;
    final triples = [
      _sftpPwdPrefix,
      _sftpKeyPrefix,
      _sftpKeyPpPrefix,
    ];
    for (final prefix in triples) {
      final v = await storage.read(key: _sftpKey(prefix, oldKey));
      if (v != null && v.isNotEmpty) {
        await storage.write(key: _sftpKey(prefix, newKey), value: v);
      }
      await storage.delete(key: _sftpKey(prefix, oldKey));
    }
  }

  Future<void> deleteSftp(String sourceKey) async {
    await storage.delete(key: _sftpKey(_sftpPwdPrefix, sourceKey));
    await storage.delete(key: _sftpKey(_sftpKeyPrefix, sourceKey));
    await storage.delete(key: _sftpKey(_sftpKeyPpPrefix, sourceKey));
  }

  String _smbKey(String sourceKey) => '$_smbPwdPrefix$sourceKey';

  /// SMB 密码；空串/不含内容即删除该键（匿名源不存）。
  Future<String?> smbPassword(String sourceKey) =>
      storage.read(key: _smbKey(sourceKey));

  Future<void> setSmbPassword(String sourceKey, String? password) async {
    final key = _smbKey(sourceKey);
    final v = (password ?? '').trim();
    if (v.isEmpty) {
      await storage.delete(key: key);
    } else {
      await storage.write(key: key, value: v);
    }
  }

  /// 源改名（key 变化）时迁移 SMB 密码键，并清理旧键。
  Future<void> migrateSmb(String oldKey, String newKey) async {
    if (oldKey == newKey) return;
    final v = await smbPassword(oldKey);
    if (v != null && v.isNotEmpty) {
      await storage.write(key: _smbKey(newKey), value: v);
    }
    await storage.delete(key: _smbKey(oldKey));
  }

  Future<void> deleteSmb(String sourceKey) =>
      storage.delete(key: _smbKey(sourceKey));

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