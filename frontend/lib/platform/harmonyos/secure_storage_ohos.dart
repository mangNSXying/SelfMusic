import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path_provider/path_provider.dart';

/// HarmonyOS（ohos）上的 flutter_secure_storage 平台实现（PoC 级）。
///
/// 背景：`flutter_secure_storage_ohos` 所有版本 `sdk <3.0.0` 无法用于当前
/// 工具链（Dart 3.11），故在 Dart 层自实现 [FlutterSecureStoragePlatform]：
/// 数据落在应用文档目录的单个 JSON 文件里，整体 base64 混淆落盘。
///
/// 安全级别：仅防随手查看明文，非加密存储。正式版应替换为 HarmonyOS
/// Asset Store Kit / HUKS 的 ArkTS 插件（见 DEVELOPER.md「鸿蒙适配」）。
///
/// API 形态对应 flutter_secure_storage_platform_interface 1.1.2
/// （Map-options 签名；flutter_secure_storage 9.2.4 锁定该接口版本），
/// options 参数携带各平台专有配置，此处全部忽略。
class OhosSecureStorage extends FlutterSecureStoragePlatform {
  static const _fileName = '.selfmusic_secure_storage';

  /// 内存即权威数据源；文件仅作持久化，避免读写竞态。
  Map<String, String>? _cache;
  Future<void>? _loading;

  Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    // 多个调用并发触发时只加载一次。
    final pending = _loading;
    if (pending != null) {
      await pending;
      return;
    }
    final completer = Completer<void>();
    _loading = completer.future;
    try {
      final map = <String, String>{};
      try {
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}${Platform.pathSeparator}$_fileName');
        if (await file.exists()) {
          // 整文件 base64：读出即解码出 JSON。
          final decoded = utf8.decode(base64Decode(await file.readAsString()));
          final raw = jsonDecode(decoded);
          if (raw is Map<String, dynamic>) {
            raw.forEach((k, v) {
              if (v is String) map[k] = v;
            });
          }
        }
      } catch (e) {
        // 损坏/不可读：视作空存储重新开始，不让密钥文件问题拖垮启动。
        debugPrint('[OhosSecureStorage] 读取失败，按空存储处理: $e');
      }
      _cache = map;
      completer.complete();
    } catch (e, s) {
      completer.completeError(e, s);
    } finally {
      _loading = null;
    }
    await completer.future;
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<void> _persist() async {
    try {
      final encoded =
          base64Encode(utf8.encode(jsonEncode(_cache ?? <String, String>{})));
      final file = await _file();
      await file.writeAsString(encoded, flush: true);
    } catch (e) {
      // 写失败不抛给调用方：密钥保存失败不应崩掉登录/配对流程（PoC 取稳）。
      debugPrint('[OhosSecureStorage] 写入失败: $e');
    }
  }

  @override
  Future<bool> containsKey(
      {required String key, required Map<String, String> options}) async {
    await _ensureLoaded();
    return _cache!.containsKey(key);
  }

  @override
  Future<String?> read(
      {required String key, required Map<String, String> options}) async {
    await _ensureLoaded();
    return _cache![key];
  }

  @override
  Future<Map<String, String>> readAll(
      {required Map<String, String> options}) async {
    await _ensureLoaded();
    return Map<String, String>.from(_cache!);
  }

  @override
  Future<void> write(
      {required String key,
      required String value,
      required Map<String, String> options}) async {
    await _ensureLoaded();
    _cache![key] = value;
    await _persist();
  }

  @override
  Future<void> delete(
      {required String key, required Map<String, String> options}) async {
    await _ensureLoaded();
    _cache!.remove(key);
    await _persist();
  }

  @override
  Future<void> deleteAll(
      {required Map<String, String> options}) async {
    await _ensureLoaded();
    _cache!.clear();
    await _persist();
  }
}
