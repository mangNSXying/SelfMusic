import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/music_source.dart';
import 'package:selfmusic/data/sources/sftp_direct_source.dart';
import 'package:selfmusic/data/sources/smb_direct_source.dart';
import 'package:selfmusic/providers/player_provider.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:sqlite3/open.dart';

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

class _FakeStorage extends FlutterSecureStorage {
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
      null;
}

class _FakeRouteSource extends MusicSource {
  @override
  final String key;
  @override
  final String name;
  @override
  final SourceKind kind;
  @override
  final SourceRoute route;
  _FakeRouteSource({
    required this.key,
    required this.name,
    required this.kind,
    this.route = SourceRoute.direct,
  });
}

void main() {
  group('阶段6 follow_server 接线', () {
    test('默认 custom；切 follow_server 后生效值取服务端镜像，无镜像回退自定义',
        () async {
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_stage6_cfg_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final index = LocalIndex();
      await index.open();
      final s = AppSettings(index);

      expect(s.cacheConfigMode, 'custom');
      expect(s.followServer, isFalse);
      s.cacheMaxBytes = 100 * 1024 * 1024;
      s.cacheSongLimit = 50;
      expect(s.effectiveCacheMaxBytes, 100 * 1024 * 1024);
      expect(s.effectiveCacheSongLimit, 50);

      // 无服务端镜像时切 follow_server：回退自定义（不断播、不误淘汰）。
      s.cacheConfigMode = 'follow_server';
      expect(s.followServer, isTrue);
      expect(s.effectiveCacheMaxBytes, 100 * 1024 * 1024);

      // 拉到镜像后生效。
      s.serverCacheMaxBytes = 5 * 1024 * 1024 * 1024;
      s.serverCacheSongLimit = 200;
      expect(s.effectiveCacheMaxBytes, 5 * 1024 * 1024 * 1024);
      expect(s.effectiveCacheSongLimit, 200);

      // 切回 custom 即回本地。
      s.cacheConfigMode = 'custom';
      expect(s.effectiveCacheMaxBytes, 100 * 1024 * 1024);
      index.close();
    });

    test('转码开关默认关、码率默认 192；非法存值回退 192', () async {
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_stage6_tc_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final index = LocalIndex();
      await index.open();
      final s = AppSettings(index);
      expect(s.transcodeEnabled, isFalse);
      expect(s.transcodeBitrate, 192);
      s.transcodeEnabled = true;
      s.transcodeBitrate = 320;
      expect(s.transcodeEnabled, isTrue);
      expect(s.transcodeBitrate, 320);
      // 非法档位（含已下架的 128 与不存在的 512）回退。
      index.settingsSet(AppSettings.kTranscodeBitrate, '128');
      expect(AppSettings(index).transcodeBitrate, 192);
      index.settingsSet(AppSettings.kTranscodeBitrate, '512');
      expect(AppSettings(index).transcodeBitrate, 192);
      index.close();
    });

    test('转码响度均衡默认关、非法回落关', () async {
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_stage6_ln_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final index = LocalIndex();
      await index.open();
      final s = AppSettings(index);
      expect(s.transcodeLoudnorm, 'off');
      s.transcodeLoudnorm = '16';
      expect(AppSettings(index).transcodeLoudnorm, '16');
      index.settingsSet(AppSettings.kTranscodeLoudnorm, '99');
      expect(AppSettings(index).transcodeLoudnorm, 'off');
      index.close();
    });

    test('knownKeys 含新键、不含服务端镜像键（不随备份导出）', () {
      expect(AppSettings.knownKeys, contains(AppSettings.kCacheConfigMode));
      expect(AppSettings.knownKeys, contains(AppSettings.kTranscodeEnabled));
      expect(AppSettings.knownKeys, contains(AppSettings.kTranscodeBitrate));
      expect(AppSettings.knownKeys, contains(AppSettings.kTranscodeLoudnorm));
      expect(AppSettings.knownKeys,
          isNot(contains(AppSettings.kCacheServerMaxBytes)));
    });
  });

  group('阶段6 删除全删', () {
    test('deleteSong 清索引/权重/歌词/歌单条目', () async {
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_stage6_del_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final index = LocalIndex();
      await index.open();
      const sk = 'webdav:t';
      const ref = '/music/a.flac';
      await index.upsertSongs([
        DirectSongRow(
            sourceKey: sk, ref: ref, title: 'a', size: 100, mtime: 1),
      ]);
      await index.setFavorite(sk, ref, true);
      await index.setLyrics(sk, ref, '[00:01.00]hi');
      final pid = await index.createPlaylist('p');
      await index.addPlaylistItem(pid,
          sourceKey: sk, songRef: ref, title: 'a');

      expect(index.searchSongs(sourceKey: sk).length, 1);
      await index.deleteSong(sk, ref);
      expect(index.searchSongs(sourceKey: sk), isEmpty);
      expect(index.playMetaOf(sk, ref).favorite, isFalse);
      expect(index.lyricsOf(sk, ref), isNull);
      expect(index.playlistItems(pid), isEmpty);
      index.close();
    });
  });

  group('阶段6 抽象与 URL', () {
    test('SMB 骨架不支持写；转码 URL 构造含 origin、bitrate 与 loudnorm', () {
      final smb = SmbDirectSource(name: 'n', host: 'h', share: 's');
      expect(smb.supportsWrite, isFalse);
      final api = ApiClient(
          dio: Dio(BaseOptions(baseUrl: 'https://h:18443')),
          storage: _FakeStorage());
      final u = api.transcodeStreamUrl('https://nas:5006/music/a.flac', 128)!;
      expect(u, contains('/api/v1/transcode/stream?origin='));
      expect(u, contains('bitrate=128'));
      expect(u, contains('loudnorm=off'));
      expect(u, startsWith('https://h:18443'));
      final u2 = api.transcodeStreamUrl('https://nas:5006/music/a.flac', 192,
          loudnorm: '16')!;
      expect(u2, contains('loudnorm=16'));
    });

    test('SFTP 地址与信封纯函数', () {
      expect(normalizeSftpAddress('NAS:2222/Music/'), 'nas:2222/Music');
      expect(normalizeSftpAddress('nas'), 'nas:22');
      expect(normalizeSftpAddress(''), '');
      expect(
          sourceAddressOf('sftp',
              {'host': 'NAS', 'port': 2222, 'path': '/Music/'}),
          'nas:2222/Music');
      expect(
          sftpOriginUrl(host: 'nas', port: 22, ref: 'a b/歌.flac'),
          'sftp://nas:22/a%20b/%E6%AD%8C.flac');
      expect(parseSftpAuthMethod('key'), SftpAuthMethod.key);
      expect(parseSftpAuthMethod('bogus'), SftpAuthMethod.password);
      // 信封往返：服务端按同口径解析（u/p/hk 与 k/pp）。
      final env = buildSshEnvelope(
          username: 'u', password: 'p', fingerprint: 'SHA256:x');
      final body = jsonDecode(utf8.decode(
          base64Url.decode(env.padRight((env.length + 3) ~/ 4 * 4, '='))));
      expect(body, {'u': 'u', 'hk': 'SHA256:x', 'p': 'p'});
    });

    test('源地址归一化：WebDAV 缺 scheme 补 https、去尾斜杠；上报与比对同口径', () {
      // 回归：无 scheme 地址曾原样上报，服务端强校验失配 → 转码 400。
      expect(normalizeSourceAddress('webdav', 'webdav.shamiko.site/data/'),
          'https://webdav.shamiko.site/data');
      expect(
          normalizeSourceAddress('webdav', ' https://nas:5006/music// '),
          'https://nas:5006/music');
      expect(sourceAddressOf('webdav', {'baseUrl': 'webdav.shamiko.site/data'}),
          'https://webdav.shamiko.site/data');
      expect(
          sourceAddressOf('webdav', {'baseUrl': 'https://nas:5006/music/'}),
          'https://nas:5006/music');
      // SMB 不受 scheme 归一化影响（仍 host/share）。
      expect(sourceAddressOf('smb', {'host': 'nas', 'share': 'music'}),
          'nas/music');
      expect(normalizeSourceAddress('smb', 'nas/music'), 'nas/music');
    });
  });

  group('播放链路偏好（直连/代理）', () {
    test('parseSourceRoute：缺失与非法回落直连', () {
      expect(parseSourceRoute(null), SourceRoute.direct);
      expect(parseSourceRoute('direct'), SourceRoute.direct);
      expect(parseSourceRoute('proxy'), SourceRoute.proxy);
      expect(parseSourceRoute('weird'), SourceRoute.direct);
    });

    test('shouldUseTranscode：仅 开关开+后端可达+webdav/sftp代理 才走转码', () {
      final proxy = _FakeRouteSource(
          key: 'webdav:n', name: 'n', kind: SourceKind.webdav,
          route: SourceRoute.proxy);
      final direct = _FakeRouteSource(
          key: 'webdav:n', name: 'n', kind: SourceKind.webdav);
      expect(
          shouldUseTranscode(
              enabled: true, apiBaseUrl: 'https://h', src: proxy),
          isTrue);
      // 直连源：开关开也不走转码。
      expect(
          shouldUseTranscode(
              enabled: true, apiBaseUrl: 'https://h', src: direct),
          isFalse);
      // 开关关 / 未配对：代理源也不走。
      expect(
          shouldUseTranscode(
              enabled: false, apiBaseUrl: 'https://h', src: proxy),
          isFalse);
      expect(
          shouldUseTranscode(enabled: true, apiBaseUrl: '', src: proxy),
          isFalse);
      // 非 webdav/sftp 即使标代理也不走（服务端强校验只认同类源）。
      final localProxy = _FakeRouteSource(
          key: 'local:n', name: 'n', kind: SourceKind.local,
          route: SourceRoute.proxy);
      expect(
          shouldUseTranscode(
              enabled: true, apiBaseUrl: 'https://h', src: localProxy),
          isFalse);
      // sftp 代理与 webdav 代理同权。
      final sftpProxy = _FakeRouteSource(
          key: 'sftp:n', name: 'n', kind: SourceKind.sftp,
          route: SourceRoute.proxy);
      expect(
          shouldUseTranscode(
              enabled: true, apiBaseUrl: 'https://h', src: sftpProxy),
          isTrue);
      final sftpDirect = _FakeRouteSource(
          key: 'sftp:n', name: 'n', kind: SourceKind.sftp);
      expect(
          shouldUseTranscode(
              enabled: true, apiBaseUrl: 'https://h', src: sftpDirect),
          isFalse);
    });
  });
}
