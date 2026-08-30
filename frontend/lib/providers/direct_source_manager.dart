import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/sources/music_source.dart';
import '../data/sources/webdav_direct_source.dart';
import '../data/local/local_index.dart';
import '../models/song.dart';

/// 直连模式源管理（阶段 3 / 阶段 4 接收器）。
///
/// - 持有 [LocalIndex]（直连模式的本地事实源）。
/// - 管理已配置的直连源（WebDAV 完整，SMB 为阶段 4 骨架）。
/// - 提供 添加/删除/扫描/检索/收藏/缓存 等操作，并驱动 UI 刷新。
class DirectSourceManager extends ChangeNotifier {
  final LocalIndex index = LocalIndex();
  final List<MusicSource> _sources = [];
  MusicSource? _active;
  String? _activeKey;
  bool _ready = false;
  bool scanning = false;
  String? error;

  bool get ready => _ready;
  List<MusicSource> get sources => List.unmodifiable(_sources);
  MusicSource? get active => _active;
  String? get activeKey => _activeKey;

  /// 服务器模式始终存在且默认激活。
  String get serverKey => 'server';

  Future<void> init() async {
    await index.open();
    final rows = index.listSources();
    for (final r in rows) {
      if (!r.enabled) continue;
      try {
        if (r.kind == 'webdav') {
          final cfg = jsonDecode(r.config) as Map<String, dynamic>;
          _sources.add(WebdavDirectSource(
            name: cfg['name'] as String? ?? r.name,
            baseUrl: cfg['baseUrl'] as String? ?? '',
            username: cfg['username'] as String? ?? '',
            password: cfg['password'] as String? ?? '',
            index: index,
          ));
        }
        // SMB 自动恢复在阶段 4 补充。
      } catch (_) {
        // 忽略损坏的源配置
      }
    }
    _ready = true;
    _active = _sources.isNotEmpty ? _sources.first : null;
    _activeKey = _active?.key;
    notifyListeners();
  }

  void setActive(String key) {
    if (key == serverKey) {
      _active = null;
      _activeKey = serverKey;
    } else {
      final s = _sources.where((x) => x.key == key).firstOrNull;
      if (s == null) return;
      _active = s;
      _activeKey = s.key;
    }
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
  }) async {
    final src = WebdavDirectSource(
      name: name,
      baseUrl: baseUrl,
      username: username,
      password: password,
      index: index,
    );
    _sources.add(src);
    index.upsertSource(src.key, 'webdav', name, src.configJson);
    if (_activeKey == null || _activeKey == serverKey) {
      _active = src;
      _activeKey = src.key;
    }
    notifyListeners();
  }

  Future<void> removeSource(String key) async {
    _sources.removeWhere((s) => s.key == key);
    index.deleteSource(key);
    if (_activeKey == key) {
      _active = _sources.isNotEmpty ? _sources.first : null;
      _activeKey = _active?.key ?? serverKey;
    }
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

  /// 检索某直连源索引的歌（默认当前激活源）。
  List<Song> songsOf(String? sourceKey, {String? query}) {
    final key = sourceKey ?? _activeKey ?? serverKey;
    if (key == serverKey) return const [];
    return index.searchSongs(sourceKey: key, query: query);
  }

  int countOf(String sourceKey) => index.countSongs(sourceKey);

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
