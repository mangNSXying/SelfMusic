import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/cache_manager.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/sources/music_source.dart';
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

const _sourceKey = 'webdav:test';

Future<LocalIndex> _openIndex(String tag) async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_${tag}_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  addTearDown(index.close);
  return index;
}

Future<void> _seedSong(LocalIndex index, String ref, {int duration = 100}) =>
    index.upsertSongs([
      DirectSongRow(
        sourceKey: _sourceKey,
        ref: ref,
        title: ref,
        size: 1024,
        mtime: 1,
        duration: duration,
      ),
    ]);

Future<void> _saveCache(LocalIndex index, String key, String ref,
        {CacheEntryKind kind = CacheEntryKind.user, int bytes = 4}) =>
    index.cacheSave(key, List<int>.filled(bytes, 1),
        sourceKey: _sourceKey, songRef: ref, kind: kind);

Future<void> _favorite(LocalIndex index, String ref) => index.applyWeightEvent(
      _sourceKey,
      ref,
      'liked',
      minFactor: 0.5,
      maxFactor: 1.5,
      step: 0.1,
      defaultFactor: 1.0,
      dislikedFactor: 0.1,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('按歌曲上限淘汰：null 中位最弱、收藏豁免、播放次数做次键、预载不占歌曲数', () async {
    final index = await _openIndex('cache_songs');
    final settings = AppSettings(index);
    settings.cacheConfigMode = 'custom';
    settings.cacheSongLimit = 2;
    settings.cacheMaxBytes = 1024 * 1024;

    await _seedSong(index, 'a'); // 收藏但从未播放：严格排序最弱，需豁免
    await _seedSong(index, 'b'); // 中位 80%，播放 500s
    await _seedSong(index, 'c'); // 中位 80%，播放 10s
    await _seedSong(index, 'd'); // 无进度样本
    await _favorite(index, 'a');
    for (var i = 0; i < 3; i++) {
      await index.recordProgress(_sourceKey, 'b', 80);
      await index.recordProgress(_sourceKey, 'c', 80);
    }
    await index.addPlaySec(_sourceKey, 'b', 500);
    await index.addPlaySec(_sourceKey, 'c', 10);

    await _saveCache(index, 'user-a', 'a');
    await _saveCache(index, 'user-b', 'b');
    await _saveCache(index, 'user-c', 'c');
    await _saveCache(index, 'user-d', 'd');
    // 预载产物：不占用户缓存歌曲数，本轮不应被删。
    await _saveCache(index, 'variant-b', 'b',
        kind: CacheEntryKind.preloadVariant);
    await _saveCache(index, 'origin-e', 'e',
        kind: CacheEntryKind.preloadOrigin);

    final cache = CacheManager(index, settings);
    await cache.evictIfNeeded();

    final left = index.listCache().map((r) => r.cacheKey).toSet();
    expect(left, contains('user-a'), reason: '收藏歌曲豁免淘汰');
    expect(left, contains('user-b'), reason: '中位/播放次数都更强');
    expect(left, isNot(contains('user-c')), reason: '同中位下播放次数更少');
    expect(left, isNot(contains('user-d')), reason: '无中位样本最弱');
    expect(left, contains('variant-b'), reason: '字节上限未超，变体保留');
    expect(left, contains('origin-e'), reason: '预载原文件不占歌曲上限');
    expect(index.countUserCachedSongs(), 2);
    expect(index.cachedPath('user-c'), isNull, reason: '删行同时删文件');
  });

  test('按字节上限淘汰：组内先删预载变体，再删原缓存', () async {
    final index = await _openIndex('cache_bytes');
    final settings = AppSettings(index);
    settings.cacheConfigMode = 'custom';
    settings.cacheSongLimit = 100;
    settings.cacheMaxBytes = 5;

    await _seedSong(index, 'x'); // 中位高，保留
    await _seedSong(index, 'y'); // 中位低，先淘汰
    for (var i = 0; i < 3; i++) {
      await index.recordProgress(_sourceKey, 'x', 100);
      await index.recordProgress(_sourceKey, 'y', 10);
    }

    await _saveCache(index, 'user-x', 'x', bytes: 4);
    await _saveCache(index, 'user-y', 'y', bytes: 4);
    await _saveCache(index, 'variant-y', 'y',
        kind: CacheEntryKind.preloadVariant, bytes: 4);

    final cache = CacheManager(index, settings);
    await cache.evictIfNeeded();

    final left = index.listCache().map((r) => r.cacheKey).toSet();
    expect(left, contains('user-x'));
    expect(left, isNot(contains('variant-y')), reason: '同组先删变体');
    expect(left, isNot(contains('user-y')), reason: '仍超字节才删原缓存');
  });
}
