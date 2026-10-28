import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/local/app_settings.dart';
import '../../platform/harmonyos/ohos_bootstrap.dart' show isOhos;
import 'android_equalizer_backend.dart';
import 'equalizer_backend.dart';
import 'equalizer_types.dart';
import 'mpv_equalizer_backend.dart';
import 'unsupported_equalizer_backend.dart';

/// 均衡器服务：持有当前播放器对应的平台后端，读取 AppSettings 并下发。
///
/// 生命周期跟播放器走：播放器重建时服务重建；设置变化时只调用 apply，
/// 不再为了 EQ 开关重建播放器。
class EqualizerService {
  EqualizerService({
    required AudioPlayer player,
    required AppSettings settings,
    required ValueChanged<EqualizerCapabilities?> onCapabilities,
  })  : _settings = settings,
        _onCapabilities = onCapabilities {
    if (!supportedOnThisPlatform) {
      _backend = UnsupportedEqualizerBackend(
        note: unsupportedNote,
        onCapabilitiesChanged: _emit,
      );
    } else if (Platform.isAndroid) {
      _backend = AndroidEqualizerBackend(
        player,
        onCapabilitiesChanged: _emit,
      );
    } else {
      _backend = MpvEqualizerBackend(onCapabilitiesChanged: _emit);
    }
  }

  final AppSettings _settings;
  final ValueChanged<EqualizerCapabilities?> _onCapabilities;
  late final EqualizerBackend _backend;
  Future<void>? _initFuture;
  bool _backendInitialized = false;
  bool _disposed = false;

  static bool get supportedOnThisPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows || Platform.isLinux);

  static String get unsupportedNote {
    if (isOhos) return '鸿蒙 AVPlayer 暂不支持应用级均衡器';
    return '当前平台暂不支持应用级均衡器';
  }

  EqualizerCapabilities get capabilities => _backend.capabilities;

  Future<void> init() async {
    if (_disposed) return;
    // 默认关闭时不创建任何原生监听/滤镜；首次开启由 apply 惰性初始化。
    if (!_settings.equalizerEnabled) return;
    await _ensureInitialized();
    if (_disposed) return;
    await apply(commit: true);
  }

  Future<void> _ensureInitialized() {
    return _initFuture ??= (() async {
      try {
        await _backend.init();
        _backendInitialized = true;
        if (!_disposed) _emit(_backend.capabilities);
      } catch (e) {
        debugPrint('[eq] 后端初始化失败: $e');
      }
    })();
  }

  Future<void> apply({bool commit = false}) async {
    if (_disposed) return;
    if (!_settings.equalizerEnabled && !_backendInitialized) return;
    if (_settings.equalizerEnabled) {
      await _ensureInitialized();
      if (_disposed) return;
    }
    await _backend.apply(
      enabled: _settings.equalizerEnabled,
      gains: _settings.eqBands,
      preampDb: _settings.eqPreampDb,
      commit: commit,
    );
    if (!_disposed) _emit(_backend.capabilities);
  }

  Future<void> flush() async {
    if (_disposed || !_backendInitialized) return;
    await _backend.flush();
    if (!_disposed) _emit(_backend.capabilities);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _backend.dispose();
    _onCapabilities(null);
  }

  void _emit(EqualizerCapabilities caps) {
    if (_disposed) return;
    _onCapabilities(caps);
  }
}
