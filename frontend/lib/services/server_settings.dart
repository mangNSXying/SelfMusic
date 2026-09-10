import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';

/// 「服务端」设置：后端地址等运行时可配项。
///
/// 独立持久化成 `services/server_settings.dart`（不复用 LocalIndex，语义更清晰），
/// 数据落在应用支持目录下的 `server_settings.json`。
class ServerSettings extends ChangeNotifier {
  static const _fileName = 'server_settings.json';

  String _baseUrl = '';
  bool _loaded = false;

  /// 后端地址（已规整为绝对 URL；未配置则空串）。
  String get baseUrl => _baseUrl;

  String _settingsPath(String dir) =>
      p.join(dir, 'selfmusic', '.server', _fileName);

  Future<String?> _resolveDir() async {
    try {
      final support = await getApplicationSupportDirectory();
      return support.path;
    } catch (_) {
      return null;
    }
  }

  /// 从磁盘加载设置（幂等，可重复调用）。
  Future<void> load() async {
    if (_loaded) return;
    final dir = await _resolveDir();
    if (dir != null) {
      try {
        final file = File(_settingsPath(dir));
        if (file.existsSync()) {
          final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          _baseUrl = (data['baseUrl'] as String? ?? '').trim();
        }
      } catch (e) {
        debugPrint('server settings load failed: $e');
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 保存后端地址（自动规整为绝对 URL；空串表示未配置）。
  Future<void> setBaseUrl(String url) async {
    final normalized = ApiClient.normalizeBaseUrl(url);
    _baseUrl = normalized;
    final dir = await _resolveDir();
    if (dir != null) {
      try {
        final file = File(_settingsPath(dir));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
            jsonEncode({'baseUrl': normalized}), flush: true);
      } catch (e) {
        debugPrint('server settings save failed: $e');
      }
    }
    notifyListeners();
  }
}
