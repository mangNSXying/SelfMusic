import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'equalizer_backend.dart';
import 'equalizer_types.dart';

/// Android 原生均衡器：just_audio 暴露 audioSessionId 后，由 Kotlin 侧
/// 优先挂 DynamicsProcessing（10 段），失败回退系统 Equalizer（设备频段）。
class AndroidEqualizerBackend extends EqualizerBackend {
  AndroidEqualizerBackend(this._player, {super.onCapabilitiesChanged});

  static const MethodChannel _channel =
      MethodChannel('com.shamiko.selfmusic/equalizer');

  final AudioPlayer _player;
  StreamSubscription<int?>? _sessionSub;
  Timer? _applyTimer;
  Future<void> _op = Future<void>.value();

  int? _sessionId;
  int? _attachedSessionId;
  bool _enabled = false;
  List<double> _gains = List.of(kDefaultEqBands);
  double _preampDb = 0;
  bool _disposed = false;
  EqualizerCapabilities _caps = EqualizerCapabilities.unsupported;

  @override
  EqualizerCapabilities get capabilities => _caps;

  @override
  Future<void> init() async {
    _sessionSub = _player.androidAudioSessionIdStream.listen(
      (id) {
        if (_disposed || id == null || id <= 0) return;
        if (_sessionId == id && _attachedSessionId == id) return;
        _sessionId = id;
        _attachedSessionId = null;
        unawaited(_push(forceAttach: true));
      },
      onError: (Object e) => debugPrint('[eq] audioSessionId 监听失败: $e'),
    );
  }

  @override
  Future<void> apply({
    required bool enabled,
    required List<double> gains,
    required double preampDb,
    bool commit = false,
  }) async {
    _enabled = enabled;
    _gains = normalizeEqBands(gains);
    _preampDb = preampDb.clamp(kEqPreampMinDb, kEqPreampMaxDb).toDouble();
    _applyTimer?.cancel();
    if (_sessionId == null) return;
    if (commit) return _push();
    _applyTimer = Timer(const Duration(milliseconds: 40), () {
      unawaited(_push());
    });
  }

  Future<void> _push({bool forceAttach = false}) {
    final session = _sessionId;
    if (session == null || _disposed) return Future<void>.value();
    return _serialize(() async {
      if (_disposed) return;
      if (!_enabled && _attachedSessionId == null) {
        return;
      }
      if (forceAttach || _attachedSessionId != session) {
        try {
          final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
            'attach',
            <String, Object?>{
              'sessionId': session,
              'enabled': _enabled,
              'frequencies': kEqFrequencies,
              'gains': _gains,
              'preampDb': _preampDb,
            },
          );
          _attachedSessionId = session;
          _setCaps(EqualizerCapabilities.fromChannelMap(res));
        } catch (e) {
          _attachedSessionId = null;
          _setCaps(EqualizerCapabilities.unsupported);
          debugPrint('[eq] Android attach 失败: $e');
        }
        return;
      }
      try {
        final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'update',
          <String, Object?>{
            'sessionId': session,
            'enabled': _enabled,
            'gains': _gains,
            'preampDb': _preampDb,
          },
        );
        if (res != null) {
          _setCaps(EqualizerCapabilities.fromChannelMap(res));
        }
      } catch (e) {
        debugPrint('[eq] Android update 失败: $e');
      }
    });
  }

  void _setCaps(EqualizerCapabilities caps) {
    final changed = caps.kind != _caps.kind ||
        caps.bandCount != _caps.bandCount ||
        caps.note != _caps.note;
    _caps = caps;
    if (changed) onCapabilitiesChanged?.call(caps);
  }

  Future<void> _serialize(Future<void> Function() body) {
    final next = _op.then((_) => body()).catchError((Object e) {
      debugPrint('[eq] Android 命令异常: $e');
    });
    _op = next;
    return next;
  }

  @override
  Future<void> flush() async {
    _applyTimer?.cancel();
    await _push();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _applyTimer?.cancel();
    await _sessionSub?.cancel();
    _sessionSub = null;
    try {
      await _channel.invokeMethod<void>('detach');
    } catch (_) {}
  }
}
