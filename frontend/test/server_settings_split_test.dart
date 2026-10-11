import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/secret_store.dart';
import 'package:selfmusic/services/server_settings.dart';

/// 内存版 fake（同 secret_store_test 约定）+ 读计数：断言快阶段不碰安全存储。
class _FakeStorage extends FlutterSecureStorage {
  final Map<String, String> store = {};
  int pairingReads = 0;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (key == SecretStore.pairingKeyId) pairingReads++;
    return store[key];
  }

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
  test('快阶段不碰安全存储，慢阶段才读密钥', () async {
    final fake = _FakeStorage();
    fake.store[SecretStore.pairingKeyId] = 'k123';
    final s = ServerSettings(secret: SecretStore(storage: fake));

    await s.loadFast();
    expect(s.pairingKey, isEmpty, reason: '快阶段只读文件，不读密钥');
    expect(fake.pairingReads, 0);

    await s.loadSlowSecrets();
    expect(s.pairingKey, 'k123');
    expect(fake.pairingReads, 1);
  });

  test('慢阶段幂等：重复调用不再读存储', () async {
    final fake = _FakeStorage();
    final s = ServerSettings(secret: SecretStore(storage: fake));

    await s.loadFast();
    await s.loadSlowSecrets();
    await s.loadSlowSecrets();
    expect(fake.pairingReads, 1);
  });

  test('慢阶段不回盖用户已写入的新值', () async {
    final fake = _FakeStorage();
    final s = ServerSettings(secret: SecretStore(storage: fake));

    await s.loadFast();
    await s.setPairingKey('user-new');
    await s.loadSlowSecrets();
    expect(s.pairingKey, 'user-new');
  });

  test('load() 全量兼容：一次走完快慢', () async {
    final fake = _FakeStorage();
    fake.store[SecretStore.pairingKeyId] = 'k999';
    final s = ServerSettings(secret: SecretStore(storage: fake));

    await s.load();
    expect(s.pairingKey, 'k999');
    expect(fake.pairingReads, 1);
  });
}
