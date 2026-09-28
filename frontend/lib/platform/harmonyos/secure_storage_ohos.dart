import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path_provider/path_provider.dart';

/// HarmonyOS（ohos）上的 flutter_secure_storage：平台实现 + 包前端绕过。
///
/// 两层问题（真机 verify-4 取证，2026-09-28 定稿）：
/// 1. `flutter_secure_storage_ohos` 所有版本 `sdk <3.0.0` 无法用于当前
///    工具链（Dart 3.11），平台实现由下方 [OhosSecureStorage] 自实现：
///    数据落在应用文档目录的单个 JSON 文件里，整体 base64 混淆落盘。
/// 2. **只换平台实现救不了启动（白屏真凶）**：包前端 `FlutterSecureStorage`
///    的每个方法（read/write/delete/...）都先走 `_selectOptions()` 做平台
///    分支（web/linux/ios/android/windows/macos 六选一），ohos 不在其中 →
///    `throw UnsupportedError`——发生在触碰平台实现**之前**。异常沿
///    `ServerSettings.load()`（无 try/catch）传出 main()，且 fork 引擎启动
///    期未捕获异常**完全静默**（hilog 零输出）→ 启动白屏；此前曾连续三轮
///    被误判为引擎消息/Timer 停滞。故 ohos 默认实例必须用
///    [OhosFlutterSecureStorage] 绕过包前端直调平台接口（统一入口
///    [createSecureStorage]，三处默认构造点共用）。
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

/// ohos 专用的包前端替代：跳过 `FlutterSecureStorage._selectOptions` 的
/// 平台分支（ohos 上必抛 UnsupportedError，见文件头 2），直接调用平台
/// 接口 [FlutterSecureStoragePlatform.instance]。
///
/// - options 一律传空 Map：[OhosSecureStorage] 忽略 options；
/// - 不复刻包前端的 listener 通知（`registerListener` 全仓零使用）；
/// - 仅经 [createSecureStorage] 在 ohos 上启用，其它平台走包原生行为。
class OhosFlutterSecureStorage extends FlutterSecureStorage {
  const OhosFlutterSecureStorage();

  /// ohos 平台实现忽略 options，空 Map 即可。
  static const Map<String, String> _noOptions = <String, String>{};

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
    final platform = FlutterSecureStoragePlatform.instance;
    // 与包前端语义一致：null 值 = 删除该键。
    if (value == null) {
      await platform.delete(key: key, options: _noOptions);
    } else {
      await platform.write(key: key, value: value, options: _noOptions);
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      FlutterSecureStoragePlatform.instance.read(key: key, options: _noOptions);

  @override
  Future<bool> containsKey({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      FlutterSecureStoragePlatform.instance
          .containsKey(key: key, options: _noOptions);

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      FlutterSecureStoragePlatform.instance
          .delete(key: key, options: _noOptions);

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      FlutterSecureStoragePlatform.instance.readAll(options: _noOptions);

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      FlutterSecureStoragePlatform.instance.deleteAll(options: _noOptions);
}

/// 默认 [FlutterSecureStorage] 实例的统一入口（三处默认构造点共用：
/// SecretStore / ApiClient / ThemeProvider）：
/// - ohos：[OhosFlutterSecureStorage]，绕过包前端平台分支（见文件头 2）；
/// - 其它平台：包原生行为，零变化。
///
/// 平台判定用字符串比较（同 ohos_bootstrap 的 isOhos；不 import 后者
/// 以免环依赖）。
FlutterSecureStorage createSecureStorage() =>
    !kIsWeb && Platform.operatingSystem == 'ohos'
        ? const OhosFlutterSecureStorage()
        : const FlutterSecureStorage();
