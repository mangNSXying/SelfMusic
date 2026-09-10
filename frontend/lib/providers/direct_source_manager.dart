import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/sources/music_source.dart';
import '../data/sources/webdav_direct_source.dart';
import '../data/sources/server_proxy_source.dart';
import '../data/local/local_index.dart';
import '../models/song.dart';
import '../services/api_client.dart';

/// 直连模式源管理（阶段 3 / 阶段 4 接收器）。
///
/// - 持有 [LocalIndex]（直连模式的本地事实源）。
/// - 管理已配置的直连源（WebDAV 完整，SMB 为阶段 4 骨架）。
/// - 每个源可独立选择 [SourceMode.direct]（App 内扫描/播放）或
///   [SourceMode.proxy]（该源走后端 /api 拉整体库，需先配置「服务端」地址）。
/// - 所有源默认激活，歌曲经 [allSongs] 合并进全局图库。
/// - 提供 添加/删除/扫描/检索/收藏/缓存/模式切换 等操作，并驱动 UI 刷新。
class DirectSourceManager extends ChangeNotifier {
  final LocalIndex index = LocalIndex();
  final List<MusicSource> _sources = [];
  bool _ready = false;
  bool scanning = false;
  String? error;

  ApiClient? _api;

  /// 关联后端接入点，供按源代理源使用其中的 dio/baseUrl。
  void attachApi(ApiClient api) => _api = api;

  bool get ready => _ready;
  List<MusicSource> get sources => List.unmodifiable(_sources);

  /// 服务器模式始终存在。
  String get serverKey => 'server';

  /// 从 [src] 读出该源的模式（默认直连）。
  static SourceMode modeOf(MusicSource src) =>
      src is ServerProxySource ? SourceMode.proxy : SourceMode.direct;

  /// 该源当前是否为「服务端代理」模式。
  bool isProxy(String key) =>
      _sources.where((x) => x.key == key).firstOrNull is ServerProxySource;

  Future<void> init() async {
    await index.open();
    final rows = index.listSources();
    for (final r in rows) {
      if (!r.enabled) continue;
      try {
        if (r.kind == 'webdav') {
          final cfg = jsonDecode(r.config) as Map<String, dynamic>;
          final mode = _modeFromConfig(cfg);
          final name = cfg['name'] as String? ?? r.name;
          if (mode == SourceMode.proxy) {
            _sources.add(_buildProxy(name: name, key: _webdavKey(name)));
          } else {
            _sources.add(WebdavDirectSource(
              name: name,
              baseUrl: cfg['baseUrl'] as String? ?? '',
              username: cfg['username'] as String? ?? '',
              password: cfg['password'] as String? ?? '',
              index: index,
            ));
          }
        }
        // SMB 自动恢复在阶段 4 补充。
      } catch (_) {
        // 忽略损坏的源配置
      }
    }
    _ready = true;
    notifyListeners();
  }

  SourceMode _modeFromConfig(Map<String, dynamic> cfg) =>
      (cfg['mode'] as String?) == 'proxy' ? SourceMode.proxy : SourceMode.direct;

  String _webdavKey(String name) => 'webdav:$name';

  ServerProxySource _buildProxy({required String name, required String key}) {
    final base = _api?.baseUrl ?? '';
    return ServerProxySource(
      dio: _api?.dio ?? Dio(),
      baseUrl: base,
      key: key,
      name: name,
    );
  }

  void setActive(String key) {
    notifyListeners();
  }

  MusicSource? sourceByKey(String key) {
    if (key == serverKey) return null; // 服务器无直连源对象
    return _sources.where((x) => x.key == key).firstOrNull;
  }

  Future<void> addWebdav({
    required String name,
    required String baseUrl,
    String username = '',
    String password = '',
    SourceMode mode = SourceMode.direct,
  }) async {
    final key = _webdavKey(name);
    final src = mode == SourceMode.proxy
        ? _buildProxy(name: name, key: key)
        : WebdavDirectSource(
            name: name,
            baseUrl: baseUrl,
            username: username,
            password: password,
            index: index,
          );
    _sources.add(src);
    final cfg = <String, dynamic>{
      'name': name,
      'baseUrl': baseUrl,
      'username': username,
      'password': password,
      'mode': mode.name,
    };
    index.upsertSource(key, 'webdav', name, jsonEncode(cfg));
    notifyListeners();
  }

  /// 切换某源的数据通道模式（直连 ↔ 服务端代理）并持久化。
  Future<void> setMode(String key, SourceMode mode) async {
    final row = index.getSource(key);
    if (row == null) return;
    final cfg = <String, dynamic>{};
    try {
      final existing = jsonDecode(row.config) as Map<String, dynamic>;
      cfg.addAll(existing);
    } catch (_) {}
    cfg['mode'] = mode.name;

    final name = cfg['name'] as String? ?? row.name;
    final List<MusicSource> rebuilt = [];
    for (final s in _sources) {
      if (s.key == key) {
        if (mode == SourceMode.proxy) {
          rebuilt.add(_buildProxy(name: name, key: key));
        } else {
          rebuilt.add(WebdavDirectSource(
            name: name,
            baseUrl: cfg['baseUrl'] as String? ?? '',
            username: cfg['username'] as String? ?? '',
            password: cfg['password'] as String? ?? '',
            index: index,
          ));
        }
      } else {
        rebuilt.add(s);
      }
    }
    _sources
      ..clear()
      ..addAll(rebuilt);
    index.upsertSource(key, row.kind, name, jsonEncode(cfg));
    notifyListeners();
  }

  Future<void> removeSource(String key) async {
    _sources.removeWhere((s) => s.key == key);
    index.deleteSource(key);
    notifyListeners();
  }

  Future<ScanSummary> scanSource(String key) async {
    final src = sourceByKey(key);
    if (src == null || !src.supportsDirect) {
      throw StateError('$key 不支持直连扫描');
    }
    scanning = true;
    error = null;
    notifyListeners();
    try {
      index.updateSourceScan(key, 'scanning');
      final summary = await src.scan();
      index.updateSourceScan(key, 'done');
      return summary;
    } catch (e) {
      error = e.toString();
      index.updateSourceScan(key, 'failed');
      rethrow;
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// 检索某源索引的歌。代理源走后端整体库（异步）。
  Future<List<Song>> fetchSongsFor(String? sourceKey, {String? query}) async {
    final key = sourceKey ?? serverKey;
    if (key == serverKey) return const [];
    final s = _sources.where((x) => x.key == key).firstOrNull;
    if (s is ServerProxySource) {
      return s.fetchSongs(query: query, size: 200);
    }
    return index.searchSongs(sourceKey: key, query: query);
  }

  /// 同步检索（本地索引）。代理源无本地索引，返回空（由 [fetchSongsFor] 异步取后端）。
  List<Song> songsOf(String? sourceKey, {String? query}) {
    final key = sourceKey ?? serverKey;
    if (key == serverKey) return const [];
    final s = _sources.where((x) => x.key == key).firstOrNull;
    if (s is ServerProxySource) return const [];
    return index.searchSongs(sourceKey: key, query: query);
  }

  int countOf(String sourceKey) {
    final s = _sources.where((x) => x.key == sourceKey).firstOrNull;
    if (s is ServerProxySource) return 0;
    return index.countSongs(sourceKey);
  }

  /// 所有直连源本地索引歌曲的总和（供全局图库合并）。
  List<Song> allSongs({String? query}) {
    final out = <Song>[];
    for (final s in _sources) {
      if (s is ServerProxySource) continue;
      out.addAll(index.searchSongs(sourceKey: s.key, query: query));
    }
    return out;
  }

  /// 所有直连源歌曲总数。
  int get allSongsCount {
    var n = 0;
    for (final s in _sources) {
      if (s is ServerProxySource) continue;
      n += index.countSongs(s.key);
    }
    return n;
  }

  void setFavorite(Song s, bool fav) {
    if (!s.isDirect) return;
    index.setFavorite(s.sourceKey, s.sourceRef, fav);
    notifyListeners();
  }

  Future<void> cacheSong(MusicSource src, Song s) async {
    await src.cacheSong(s);
    notifyListeners();
  }

  String? cachedPathOf(MusicSource src, Song s) =>
      index.cachedPath('cache:$src.key|${s.sourceRef}');
}
