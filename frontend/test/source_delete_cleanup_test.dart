import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/sync_event_types.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/providers/direct_source_manager.dart';
import 'package:selfmusic/providers/library_provider.dart';
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
  group('删源清理', () {
    test('删源清掉按源存的折叠/展开设置项', () async {
      final (index, dir) = await _openIndex('selfmusic_delsettings_');
      try {
        const key = 'webdav:NAS';
        await index.upsertSource(
            key, 'webdav', 'NAS', jsonEncode({'name': 'NAS', 'baseUrl': _addr}));
        index.settingsSet('group_collapsed_source:$key', 'A|B');
        index.settingsSet('folder_expanded_source:$key', 'Inbox');
        index.settingsSet(sourceLineSettingKey(key), 'fb0');
        index.settingsSet('unrelated', 'keep');

        await index.deleteSource(key);
        await index.flushWrites();

        expect(index.settingsGet('group_collapsed_source:$key'), isNull);
        expect(index.settingsGet('folder_expanded_source:$key'), isNull);
        expect(index.settingsGet(sourceLineSettingKey(key)), isNull);
        expect(index.settingsGet('unrelated'), 'keep');
        expect(index.settingsAll().containsKey('group_collapsed_source:$key'),
            isFalse);
      } finally {
        index.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('删源删掉该源封面文件（原图 + 缩略图），其它源同 ref 的封面保留', () async {
      final (index, dir) = await _openIndex('selfmusic_delcovers_');
      try {
        const a = 'webdav:NAS';
        const b = 'sftp:Box';
        await index.upsertSource(a, 'webdav', 'NAS', '{}');
        await index.upsertSource(b, 'sftp', 'Box', '{}');

        // 封面必须落在 `<support>/selfmusic/covers/` 下，否则删源会跳过
        //（保护逻辑：只删自己目录里的文件）。同 ref 的两个源落在同一路径。
        final onlyAPath = index.coverPathFor('/x.mp3')!;
        File(onlyAPath).writeAsBytesSync([1, 2, 3]);
        final sharedPath = index.coverPathFor('/y.mp3')!;
        File(sharedPath).writeAsBytesSync([1, 2, 3]);
        await index.upsertSongs([
          DirectSongRow(
              sourceKey: a,
              ref: '/x.mp3',
              title: 'X',
              size: 1,
              mtime: 1,
              coverPath: onlyAPath),
          DirectSongRow(
              sourceKey: a,
              ref: '/y.mp3',
              title: 'Y',
              size: 1,
              mtime: 1,
              coverPath: sharedPath),
          DirectSongRow(
              sourceKey: b,
              ref: '/y.mp3',
              title: 'Y',
              size: 1,
              mtime: 1,
              coverPath: sharedPath),
        ]);

        await index.deleteSource(a);

        expect(File(onlyAPath).existsSync(), isFalse, reason: 'A 独占的封面应删掉');
        expect(File(sharedPath).existsSync(), isTrue,
            reason: 'B 还引用同一张封面，不能删');
        expect(index.songByRef(a, '/x.mp3'), isNull);
      } finally {
        index.close();
        dir.deleteSync(recursive: true);
      }
    });

    test('删源递增曲库版本，LibraryProvider 据此重查（不再残留死引用）', () async {
      final dir = await Directory.systemTemp.createTemp('selfmusic_delmeta_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final direct = await _newManager();
      final lib = LibraryProvider()..attachDirectManager(direct);
      try {
        await direct.addLocal(name: 'M', path: dir.path);
        await direct.index.upsertSongs([
          DirectSongRow(
              sourceKey: 'local:M',
              ref: '/a.mp3',
              title: 'A',
              size: 1,
              mtime: 1),
        ]);
        await lib.loadSongs();
        expect(lib.songs.length, 1);

        final metaBefore = direct.metaVersion;
        final favBefore = direct.favoriteVersion;
        await direct.removeSource('local:M');
        // LibraryProvider 只在 metaVersion/settingsVersion/artistsVersion 变化时
        // 重查；删源若不递增版本，列表会一直挂着已删源的歌（点播即报错）。
        expect(direct.metaVersion, greaterThan(metaBefore));
        expect(direct.favoriteVersion, greaterThan(favBefore),
            reason: '喜欢页同样要失效');
        await lib.loadSongs();
        expect(lib.songs, isEmpty, reason: '删源后曲库不应再列出该源的歌');
      } finally {
        lib.dispose();
        direct.dispose();
        direct.index.close();
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('源改名迁移', () {
    test('改名迁移折叠/展开设置项，旧键不残留', () async {
      final (index, dir) = await _openIndex('selfmusic_rename_');
      try {
        const oldKey = 'webdav:NAS';
        const newKey = 'webdav:NAS2';
        await index.upsertSource(
            oldKey, 'webdav', 'NAS', jsonEncode({'name': 'NAS'}));
        index.settingsSet('group_collapsed_source:$oldKey', 'A');
        index.settingsSet(sourceLineSettingKey(oldKey), 'fb0');

        await index.renameSource(oldKey, newKey);
        await index.flushWrites();

        expect(index.settingsGet('group_collapsed_source:$newKey'), 'A');
        expect(index.settingsGet('group_collapsed_source:$oldKey'), isNull);
        expect(index.settingsGet(sourceLineSettingKey(newKey)), 'fb0');
        expect(index.settingsGet(sourceLineSettingKey(oldKey)), isNull);
      } finally {
        index.close();
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('冷启动快照恢复', () {
    test('恢复时丢弃已删源的歌', () async {
      final dir = await Directory.systemTemp.createTemp('selfmusic_restore_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final direct = await _newManager();
      final lib = LibraryProvider()..attachDirectManager(direct);
      try {
        await direct.addLocal(name: 'M', path: dir.path);
        final alive = Song.direct(
          id: 1,
          sourceKey: 'local:M',
          title: 'alive',
          source: 'local',
          sourceRef: '/a.mp3',
          fileSize: 1,
        );
        final dead = Song.direct(
          id: 2,
          sourceKey: 'webdav:Gone',
          title: 'dead',
          source: 'webdav',
          sourceRef: '/b.mp3',
          fileSize: 1,
        );
        // 直接写缓存文件（等价于上次启动时的落盘快照），不依赖内部私有方法。
        final cacheFile = File('${dir.path}/selfmusic/library_cache.json')
          ..createSync(recursive: true)
          ..writeAsStringSync(
              jsonEncode([alive.toJson(), dead.toJson()]));

        lib.songs = const [];
        await lib.restoreCache();
        expect(cacheFile.existsSync(), isTrue);
        expect(lib.songs.map((s) => s.title), ['alive'],
            reason: '快照里已删源的行必须过滤，避免首帧闪出死引用');
      } finally {
        lib.dispose();
        direct.dispose();
        direct.index.close();
        dir.deleteSync(recursive: true);
      }
    });
  });
}
