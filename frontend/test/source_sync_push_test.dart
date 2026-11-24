import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/secret_store.dart';
import 'package:sqlite3/open.dart';

/// 内存版安全存储：测试环境没有平台通道，SecretStore 必须注入它。
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

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

Future<(LocalIndex, Directory)> _openIndex(String prefix) async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp(prefix);
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return (index, dir);
}

/// 仅提供 baseUrl 的 Api（源自举只读可达性，不发网络）。
class _BaseUrlApi extends ApiClient {
  @override
  String get baseUrl => 'https://sync.example';
  @override
  Future<String?> getClientId() async => 'test-client';
}

/// 建好 DirectSourceManager 并把 SecretStore 换成内存版（测试无平台通道）。
Future<DirectSourceManager> _newManager() async {
  final direct = DirectSourceManager();
  direct.secrets = SecretStore(storage: _FakeStorage());
  await direct.init();
  return direct;
}

const _addr = 'https://dav.example.com/music';

void main() {
  group('源上报判据（uuid 存在 ≠ 已上报）', () {
    test('添加源即生成 uuid，但未上报前 sourceNeedsSync 仍为真', () async {
      final (index, dir) = await _openIndex('selfmusic_needsync_');
      try {
        await index.upsertSource('webdav:NAS', 'webdav', 'NAS',
            jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
        await index.ensureSourceUuid('webdav:NAS');
        expect(index.sourceUuidOf('webdav:NAS'), isNotNull,
            reason: '添加源时 uuid 就落库了');
        expect(index.sourceSyncedSig('webdav:NAS'), isNull);
        expect(index.sourceNeedsSync('webdav:NAS'), isTrue,
            reason: 'uuid 存在不能当成「已上报」');
      } finally {
        index.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('本地源不参与同步，永远不需要上报', () async {
      final (index, dir) = await _openIndex('selfmusic_localskip_');
      try {
        await index.upsertSource(
            'local:Music', 'local', 'Music', jsonEncode({'name': 'Music'}));
        expect(index.sourceNeedsSync('local:Music'), isFalse);
      } finally {
        index.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('签名与键序无关；backfill 不影响签名', () async {
      final a = sourceSyncSignature({
        'client_uuid': 'u1',
        'kind': 'webdav',
        'address': _addr,
        'config': {'name': 'NAS', 'baseUrl': _addr, 'username': 'u'},
      });
      final b = sourceSyncSignature({
        'config': {'username': 'u', 'baseUrl': _addr, 'name': 'NAS'},
        'address': _addr,
        'kind': 'webdav',
        'client_uuid': 'u1',
      });
      expect(a, b, reason: 'config 键序不同但内容相同应同签名');
      expect(sourceSyncSignature({'backfill': true, 'kind': 'webdav'}),
          sourceSyncSignature({'kind': 'webdav'}));
    });

    test('配对不自动推源；源菜单「推送到服务端」才补推', () async {
      final dir = await Directory.systemTemp.createTemp('selfmusic_onpaired_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final direct = await _newManager();
      try {
        // 复现「先加源、后配对」：unpaired 时 addWebdav 的 _emitSource 直接 return。
        await direct.addWebdav(
            name: 'NAS', baseUrl: _addr, username: 'u', password: 'p');
        expect(await direct.index.pendingOutboxCount(), 0,
            reason: '未配对时不应入队');
        expect(direct.index.sourceNeedsSync('webdav:NAS'), isTrue);
        // 未配对时菜单项不出现（没地址，推了也没用）。
        expect(direct.canPushSourceToServer('webdav:NAS'), isFalse);

        // 配对完成（此处直接注入 api 模拟配对后的可用状态）。
        direct.attachApi(_BaseUrlApi());
        // 关键语义：配对**不会**自动补推——用户在弹窗点「不推送」就是真的不推。
        expect(await direct.index.pendingOutboxCount(), 0,
            reason: '配对后不应自动补推源');
        // 但此时菜单项应可用，作为显式出口。
        expect(direct.canPushSourceToServer('webdav:NAS'), isTrue);

        final queued = await direct.pushSourceToServer('webdav:NAS');
        expect(queued, isTrue);
        final pending = await direct.index.pendingOutbox();
        // 从未上报过 → 走补录 create（服务端只建行，不覆盖同址现行行）。
        final create = pending
            .where((e) => e.type == SyncEventTypes.sourceCreate)
            .toList();
        expect(create.length, 1, reason: '手动推送应入队 source.create');
        expect(create.single.payload['backfill'], isTrue);
        expect(create.single.payload['client_uuid'],
            direct.index.sourceUuidOf('webdav:NAS'));

        // 推成功后签名落地：菜单项消失，重复推送不产生事件。
        expect(direct.index.sourceNeedsSync('webdav:NAS'), isFalse);
        expect(direct.canPushSourceToServer('webdav:NAS'), isFalse);
        expect(await direct.pushSourceToServer('webdav:NAS'), isFalse);
        expect((await direct.index.pendingOutbox()).length, 1);
      } finally {
        direct.dispose();
        direct.index.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('已配对时添加的源自动入队，推送菜单不出现', () async {
      final dir = await Directory.systemTemp.createTemp('selfmusic_pairedadd_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final direct = await _newManager();
      try {
        direct.attachApi(_BaseUrlApi());
        await direct.addWebdav(name: 'NAS', baseUrl: _addr, username: 'u');
        final pending = await direct.index.pendingOutbox();
        expect(pending.where((e) => e.type == SyncEventTypes.sourceCreate).length,
            1,
            reason: '已配对时添加源应直接上报');
        expect(direct.canPushSourceToServer('webdav:NAS'), isFalse);
      } finally {
        direct.dispose();
        direct.index.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('本地源不显示推送菜单项', () async {
      final dir = await Directory.systemTemp.createTemp('selfmusic_localpush_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final direct = await _newManager();
      try {
        direct.attachApi(_BaseUrlApi());
        await direct.addLocal(name: 'M', path: dir.path);
        expect(direct.canPushSourceToServer('local:M'), isFalse);
        expect(await direct.pushSourceToServer('local:M'), isFalse);
      } finally {
        direct.dispose();
        direct.index.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('远端快照落库后视为已上报，重启不再回推', () async {
      final (index, dir) = await _openIndex('selfmusic_remoteapply_');
      try {
        await index.applySourceSnapshot(
          uuid: 'u1',
          kind: 'webdav',
          name: 'NAS',
          address: _addr,
          config: {'name': 'NAS', 'baseUrl': _addr},
          enabled: true,
          deleted: false,
        );
        expect(index.sourceNeedsSync('webdav:NAS'), isFalse,
            reason: '来自服务端的源不应被当成待上报');
      } finally {
        index.close();
        dir.deleteSync(recursive: true);
      }
    });
  });
}
