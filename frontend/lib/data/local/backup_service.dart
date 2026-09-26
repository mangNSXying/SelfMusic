import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../services/server_settings.dart';
import '../../theme/theme_provider.dart';
import 'app_settings.dart';
import 'local_index.dart';

/// 备份文件类型：仅设置 / 仅歌单 / 兼容旧的综合备份。
enum BackupKind { settings, playlists, full }

/// 设置 / 歌单导出导入（settings.md §3.5，常规分区）。
///
/// **设置与歌单分开导出导入**（含独立文件选择器导入，方便跨机迁移）：
/// - 导出写入应用支持目录 `selfmusic/backups/` 下
///   `selfmusic-settings-<时间戳>.json` / `selfmusic-playlists-<时间戳>.json`；
/// - 导入支持从任意位置选择文件（`file_selector`），按文件内 `type` 字段仅恢复对应部分；
/// - 兼容旧版综合备份（schema=1 且无 `type`，含 settings+server+theme+playlists）。
/// 不含令牌与源凭据（flutter_secure_storage 内容不导出）。
class BackupService {
  final LocalIndex index;
  final ServerSettings server;
  final ThemeProvider theme;

  static const int schema = 1;

  BackupService({
    required this.index,
    required this.server,
    required this.theme,
  });

  String get _backupDir {
    final d = p.join(index.dir, 'backups');
    Directory(d).createSync(recursive: true);
    return d;
  }

  /// 本机备份文件列表（按文件名排序，新的在后）。
  List<File> listBackups() {
    final dir = Directory(_backupDir);
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  /// 读取备份文件类型（旧综合备份无 `type` 时按 [BackupKind.full]）。
  static BackupKind kindOf(File file) {
    try {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return switch (data['type']) {
        'settings' => BackupKind.settings,
        'playlists' => BackupKind.playlists,
        _ => BackupKind.full,
      };
    } catch (_) {
      return BackupKind.full;
    }
  }

  /// 导出设置（app_settings 已知键 + 服务端地址 + 主题偏好）。
  Future<File> exportSettings() async {
    // 设置写入为 fire-and-forget（内存缓存先行），导出前等排队写落库。
    await index.flushWrites();
    return _write('settings', {
      'settings': _exportSettings(),
      'server': <String, dynamic>{'baseUrl': server.baseUrl},
      'theme': _exportTheme(),
    });
  }

  /// 导出全部歌单（含歌曲快照）。
  Future<File> exportPlaylists() async {
    await index.flushWrites();
    return _write('playlists', {'playlists': _exportPlaylists()});
  }

  File _write(String type, Map<String, dynamic> body) {
    final file = File(p.join(
        _backupDir, 'selfmusic-$type-${_stamp()}.json'));
    file.writeAsStringSync(
        const JsonEncoder.withIndent('  ')
            .convert(<String, dynamic>{
              'schema': schema,
              'type': type,
              'exportedAt': DateTime.now().toIso8601String(),
              ...body,
            }),
        flush: true);
    return file;
  }

  Map<String, String> _exportSettings() {
    return {
      for (final e in index.settingsAll().entries)
        if (AppSettings.knownKeys.contains(e.key)) e.key: e.value,
    };
  }

  Map<String, dynamic> _exportTheme() => <String, dynamic>{
        'mode': theme.mode.name,
        'accent': theme.accent.toARGB32(),
        'background': theme.background?.toARGB32(),
      };

  List<Map<String, dynamic>> _exportPlaylists() {
    return [
      for (final pl in index.listPlaylists())
        <String, dynamic>{
          'name': pl.name,
          'description': pl.description,
          'items': [
            for (final it in index.playlistItems(pl.id))
              <String, dynamic>{
                'sourceKey': it.sourceKey,
                'ref': it.songRef,
                'title': it.title,
                'artist': it.artist,
                'album': it.album,
                'coverPath': it.coverPath,
              },
          ],
        },
    ];
  }

  /// 从任意位置导入「设置」部分（含兼容旧综合备份）。返回导入摘要。
  Future<String> importSettings(File file) async {
    final data = _decode(file);
    final type = data['type'] as String?;
    if (type != null && type != 'settings') {
      throw FormatException('该文件是${_typeLabel(type)}备份，不含设置数据');
    }
    final settings = (data['settings'] as Map<String, dynamic>?) ?? const {};
    var restored = 0;
    for (final k in AppSettings.knownKeys) {
      final vv = settings[k] as String?;
      if (vv != null) {
        index.settingsSet(k, vv);
        restored++;
      }
    }
    final serverMap = (data['server'] as Map<String, dynamic>?) ?? const {};
    final baseUrl = serverMap['baseUrl'] as String?;
    if (baseUrl != null) await server.setBaseUrl(baseUrl);
    await _restoreTheme(
        (data['theme'] as Map<String, dynamic>?) ?? const {});
    return '已导入设置 $restored 项（含服务端地址、主题）';
  }

  /// 从任意位置导入「歌单」部分（含兼容旧综合备份）。返回导入摘要。
  Future<String> importPlaylists(File file) async {
    final data = _decode(file);
    final type = data['type'] as String?;
    if (type != null && type != 'playlists') {
      throw FormatException('该文件是${_typeLabel(type)}备份，不含歌单数据');
    }
    final playlists =
        (data['playlists'] as List<dynamic>?) ?? const <dynamic>[];
    var playlistCount = 0;
    var itemCount = 0;
    for (final raw in playlists) {
      final pl = raw as Map<String, dynamic>;
      final id = await index.createPlaylist(
          pl['name'] as String? ?? '未命名歌单',
          description: pl['description'] as String?);
      playlistCount++;
      for (final it in (pl['items'] as List<dynamic>? ?? const <dynamic>[])) {
        final m = it as Map<String, dynamic>;
        await index.addPlaylistItem(
          id,
          sourceKey: m['sourceKey'] as String? ?? '',
          songRef: m['ref'] as String? ?? '',
          title: m['title'] as String? ?? '',
          artist: m['artist'] as String?,
          album: m['album'] as String?,
          coverPath: m['coverPath'] as String?,
        );
        itemCount++;
      }
    }
    return '已导入歌单 $playlistCount 个、歌曲 $itemCount 首';
  }

  static String _typeLabel(String type) =>
      type == 'settings' ? '设置' : (type == 'playlists' ? '歌单' : '未知');

  Map<String, dynamic> _decode(File file) {
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (e) {
      throw FormatException('备份文件解析失败：$e');
    }
    final v = data['schema'] as int?;
    if (v != schema) {
      throw FormatException('不支持的备份版本（schema=$v，当前=$schema）');
    }
    return data;
  }

  Future<void> _restoreTheme(Map<String, dynamic> themeMap) async {
    final mode = themeMap['mode'] as String?;
    final accent = themeMap['accent'] as int?;
    final background = themeMap['background'] as int?;
    if (accent != null) await theme.setAccent(Color(accent));
    if (background != null) {
      await theme.setBackground(Color(background));
    } else {
      await theme.clearBackgroundOverride();
    }
    if (mode != null) {
      await theme.setMode(mode == 'dark' ? Brightness.dark : Brightness.light);
    }
  }

  static String _stamp() =>
      DateTime.now().toIso8601String().replaceAll(RegExp(r'[-:T]'), '').substring(0, 14);
}