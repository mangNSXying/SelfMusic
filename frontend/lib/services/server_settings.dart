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

  Future<String?> _resolveDir() async {
    try {
      // 启动链第一个路径调用：现场断言 ohos 重试包装在位（verify-4 实证
      // 引擎注册器在 main() 之前已跑完、从未覆盖包装；此断言是防未来引擎
      // 行为变化的保险，取证记录见 path_provider_ohos_retry.dart 头注释）。
      // ohos 之外为 no-op。
      ensureOhosPathWrapper('resolveDir');
      final support = await getApplicationSupportDirectory();
      return support.path;
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
      file.parent.createSync(recursive: true);
      // 只落非敏感的 baseUrl；配对密钥由 SecretStore 管。
      file.writeAsStringSync(jsonEncode({'baseUrl': _baseUrl}),
          flush: true);
    } catch (e) {
      debugPrint('server settings save failed: $e');
    }
  }

  /// 从磁盘 + SecretStore 加载设置（幂等，可重复调用）。
  /// 老版本的 pairingKey 明文在 json 里：迁移进 SecretStore 后回写清理。
  Future<void> load() async {
    if (_loaded) return;
    String? legacyPairingKey;
    final dir = await _resolveDir();
    if (dir != null) {
      try {
        final file = File(_settingsPath(dir));
        if (file.existsSync()) {
          final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          _baseUrl = (data['baseUrl'] as String? ?? '').trim();
          legacyPairingKey = (data['pairingKey'] as String? ?? '').trim();
        }
      } catch (e) {
        debugPrint('server settings load failed: $e');
      }
    }
    // 安全存储读取失败不拖垮启动（白屏真凶曾在此：ohos 上包前端
    // UnsupportedError 未捕获即静默死亡，见 secure_storage_ohos.dart；
    // 已绕过包前端，此处兜底防未来未知异常，失败按未配对继续）。
    try {
      _pairingKey = (await secret.pairingKey()) ?? '';
      if (_pairingKey.isEmpty &&
          legacyPairingKey != null &&
          legacyPairingKey.isNotEmpty) {
        _pairingKey = legacyPairingKey;
        await secret.setPairingKey(legacyPairingKey);
      }
    } catch (e, s) {
      debugPrint('[boot] 配对密钥读取失败，按未配对处理: $e\n$s');
    }
    _loaded = true;
    // 回写一次：清理 json 中残留的明文 pairingKey。
    await _persist();
    notifyListeners();
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
