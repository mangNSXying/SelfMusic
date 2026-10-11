import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api_client.dart';
import 'secret_store.dart';
import '../platform/harmonyos/path_provider_ohos_retry.dart';

/// 「服务端」设置：后端地址等运行时可配项。
///
/// 独立持久化成 `services/server_settings.dart`（不复用 LocalIndex，语义更清晰），
/// 数据落在应用支持目录下的 `server_settings.json`。**配对密钥不落明文文件**
/// （问题.md B2 收敛）：由 [SecretStore] 接管，json 仅存非敏感的 baseUrl。
class ServerSettings extends ChangeNotifier {
  static const _fileName = 'server_settings.json';

  final SecretStore secret;

  ServerSettings({SecretStore? secret})
      : secret = secret ?? SecretStore();

  String _baseUrl = '';
  String _pairingKey = '';
  bool _loaded = false;

  /// 后端地址（已规整为绝对 URL；未配置则空串）。
  String get baseUrl => _baseUrl;

  /// 最近一次从服务端取到的配对密钥（本地缓存，离线也能查看）。
  String get pairingKey => _pairingKey;

  String _settingsPath(String dir) =>
      p.join(dir, 'selfmusic', '.server', _fileName);

  /// 应用支持目录缓存：`getApplicationSupportDirectory()` 首调含通道预热
  /// （冷启动实测百 ms 级），`load` 与 `_persist` 原先各调一次。单例内复用。
  String? _cachedDir;

  Future<String?> _resolveDir() async {
    if (_cachedDir != null) return _cachedDir;
    try {
      // 启动链第一个路径调用：现场断言 ohos 重试包装在位（verify-4 实证
      // 引擎注册器在 main() 之前已跑完、从未覆盖包装；此断言是防未来引擎
      // 行为变化的保险，取证记录见 path_provider_ohos_retry.dart 头注释）。
      // ohos 之外为 no-op。
      ensureOhosPathWrapper('resolveDir');
      final support = await getApplicationSupportDirectory();
      _cachedDir = support.path;
      return _cachedDir;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    if (!_loaded) return; // 未加载先写会把磁盘上已有配置抹掉
    final dir = await _resolveDir();
    if (dir == null) return;
    try {
      final file = File(_settingsPath(dir));
      // 异步 IO：原先 createSync + writeAsStringSync(flush) 全堵 UI 线程
      // （冷启动 Skipped 帧的来源之一）。
      await file.parent.create(recursive: true);
      // 只落非敏感的 baseUrl；配对密钥由 SecretStore 管。
      await file.writeAsString(jsonEncode({'baseUrl': _baseUrl}),
          flush: true);
    } catch (e) {
      debugPrint('server settings save failed: $e');
    }
  }

  /// 安全存储读（带兜底）：失败按未配对继续，不拖垮启动。
  ///
  /// 抽出以便 [load] 内与文件读并行预热——原先文件读完才起安全存储读，
  /// 两个通道延迟串行（白屏真凶曾在此，见下注释）。
  Future<String> _readPairingKeySafely() async {
    // 安全存储读取失败不拖垮启动（白屏真凶曾在此：ohos 上包前端
    // UnsupportedError 未捕获即静默死亡，见 secure_storage_ohos.dart；
    // 已绕过包前端，此处兜底防未来未知异常，失败按未配对继续）。
    try {
      return (await secret.pairingKey()) ?? '';
    } catch (e, s) {
      debugPrint('[boot] 配对密钥读取失败，按未配对处理: $e\n$s');
      return '';
    }
  }

  /// 老版本 json 里残留的明文 pairingKey（快阶段暂存，慢阶段迁移）。
  String _legacyPairingKey = '';

  /// 慢阶段是否已跑完（幂等守卫；与 [_loaded] 独立）。
  bool _secretsLoaded = false;

  /// 快阶段（首帧前）：只读文件取 baseUrl，不碰安全存储。
  ///
  /// 冷启动实测安全存储首读 ~1.1s（插件通道预热 + 加密 prefs 初始化），
  /// 与文件读并行也省不下来；`pairingKey` 首帧前零消费者（仅配对页/设置页
  /// 读），故拆出首帧，见 [loadSlowSecrets]。
  Future<void> loadFast() async {
    if (_loaded) return;
    final dir = await _resolveDir();
    if (dir != null) {
      try {
        final file = File(_settingsPath(dir));
        if (await file.exists()) {
          final data =
              jsonDecode(await file.readAsString()) as Map<String, dynamic>;
          _baseUrl = (data['baseUrl'] as String? ?? '').trim();
          _legacyPairingKey = (data['pairingKey'] as String? ?? '').trim();
        }
      } catch (e) {
        debugPrint('server settings load failed: $e');
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 慢阶段（首帧后）：安全存储读 + 明文迁移 + 按需回写清理。
  ///
  /// 只在用户尚未写入新值时才用存储值覆盖（`setPairingKey` 可能先于本阶段
  /// 被调用， stale 读不能回盖用户值）。
  Future<void> loadSlowSecrets() async {
    if (_secretsLoaded) return;
    _secretsLoaded = true;
    final stored = await _readPairingKeySafely();
    if (_pairingKey.isEmpty) _pairingKey = stored;
    if (_pairingKey.isEmpty && _legacyPairingKey.isNotEmpty) {
      _pairingKey = _legacyPairingKey;
      await secret.setPairingKey(_legacyPairingKey);
    }
    // 仅需清理明文残留时回写，无迁移时纯浪费（目录查询 + 建目录 + flush）。
    if (_legacyPairingKey.isNotEmpty) await _persist();
    _legacyPairingKey = '';
    notifyListeners();
  }

  /// 从磁盘 + SecretStore 加载设置（幂等，可重复调用）。
  /// 老版本的 pairingKey 明文在 json 里：迁移进 SecretStore 后回写清理。
  Future<void> load() async {
    await loadFast();
    await loadSlowSecrets();
  }

  /// 保存后端地址（自动规整为绝对 URL；空串表示未配置）。
  Future<void> setBaseUrl(String url) async {
    _baseUrl = ApiClient.normalizeBaseUrl(url);
    await _persist();
    notifyListeners();
  }

  /// 保存最近取到的配对密钥（离线时仍可查看/复制）。落 SecretStore，不写明文文件。
  Future<void> setPairingKey(String key) async {
    final v = key.trim();
    if (v == _pairingKey) return;
    _pairingKey = v;
    await secret.setPairingKey(v);
    notifyListeners();
  }
}
