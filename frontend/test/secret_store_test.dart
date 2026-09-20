import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/secret_store.dart';

/// 内存版 fake：替换平台通道，覆盖 read/write/delete 即可（其余命名参数忽略）。
class _FakeStorage extends FlutterSecureStorage {
  final Map<String, String> store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null || value.isEmpty) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }
}

void main() {
  test('SecretStore：WebDAV 密码 roundtrip / 空值清除 / 删除', () async {
    final fake = _FakeStorage();
    final store = SecretStore(storage: fake);

    expect(await store.webdavPassword('webdav:NAS'), isNull);

    await store.setWebdavPassword('webdav:NAS', 's3cret');
    expect(await store.webdavPassword('webdav:NAS'), 's3cret');
    // 不同源互不串扰。
    expect(await store.webdavPassword('webdav:Other'), isNull);

    await store.setWebdavPassword('webdav:NAS', '   ');
    expect(await store.webdavPassword('webdav:NAS'), isNull);
    expect(fake.store.containsKey('webdav_pwd:webdav:NAS'), isFalse);

    await store.setWebdavPassword('webdav:NAS', 'again');
    await store.deleteWebdav('webdav:NAS');
    expect(await store.webdavPassword('webdav:NAS'), isNull);
  });

  test('SecretStore：源改名迁移旧键并清理', () async {
    final store = SecretStore(storage: _FakeStorage());
    await store.setWebdavPassword('webdav:NAS', 'pwd');

    await store.migrateWebdav('webdav:NAS', 'webdav:新NAS');
    expect(await store.webdavPassword('webdav:新NAS'), 'pwd');
    expect(await store.webdavPassword('webdav:NAS'), isNull);

    // 同键 no-op，不丢数据。
    await store.migrateWebdav('webdav:新NAS', 'webdav:新NAS');
    expect(await store.webdavPassword('webdav:新NAS'), 'pwd');
  });

  test('SecretStore：配对密钥 roundtrip / 清除', () async {
    final fake = _FakeStorage();
    final store = SecretStore(storage: fake);
    expect(await store.pairingKey(), isNull);

    await store.setPairingKey('abc-123');
    expect(await store.pairingKey(), 'abc-123');

    await store.setPairingKey('');
    expect(await store.pairingKey(), isNull);
    expect(fake.store.containsKey(SecretStore.pairingKeyId), isFalse);
  });
}