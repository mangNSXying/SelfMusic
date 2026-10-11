import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 静音暂停 / 断连暂停的平台信号（settings.md §3.2，仅 Android）。
///
/// 之所以自持原生监听而不用 `audio_session`：后者的 becoming-noisy 接收器只在
/// just_audio 因音频焦点接管而请求焦点时才注册——音频焦点关闭时「断连暂停」会
/// 彻底失效，恰是用户最需要该功能的情形。故 Android 侧新增独立通道
/// （[AudioGuard.kt]）：
/// - MethodChannel `com.shamiko.selfmusic/audio_guard`：`getMediaVolume()`；
/// - EventChannel `com.shamiko.selfmusic/audio_guard/events`：媒体音量变化
///   （`{type:"volume", value:int}`）与当前输出设备断开（`{type:"outputLost"}`）。
///
/// 其它平台无实现，返回空信号源（与均衡器/音频焦点同样「Android 生效」）。

/// 单条音频守卫事件。
enum AudioGuardEventType {
  /// 媒体音量变化（`value` 为当前档位）。
  volume,

  /// 当前播放输出设备断开（如蓝牙音箱掉线、耳机拔出）。
  outputLost,
}

/// 音频守卫事件（[AudioGuardEventType.volume] 携带 [value]，其余为 null）。
class AudioGuardEvent {
  final AudioGuardEventType type;
  final int? value;

  const AudioGuardEvent._(this.type, this.value);
  const AudioGuardEvent.volume(int value)
      : this._(AudioGuardEventType.volume, value);
  const AudioGuardEvent.outputLost()
      : this._(AudioGuardEventType.outputLost, null);
}

/// 平台音频守卫信号源。
abstract class AudioGuardPlatform {
  /// 事件广播流；平台不支持时为空流。
  Stream<AudioGuardEvent> get events;

  /// 当前媒体音量档位；不支持/读取失败返回 null（调用方按「未知」忽略）。
  Future<int?> get mediaVolume;

  /// 当前平台实现：Android 走原生通道，其余平台 no-op。
  static AudioGuardPlatform forCurrentPlatform() {
    if (!kIsWeb && Platform.isAndroid) return _AndroidAudioGuard();
    return const _NoopAudioGuard();
  }
}

class _AndroidAudioGuard implements AudioGuardPlatform {
  static const MethodChannel _method =
      MethodChannel('com.shamiko.selfmusic/audio_guard');
  static const EventChannel _events =
      EventChannel('com.shamiko.selfmusic/audio_guard/events');

  Stream<AudioGuardEvent>? _stream;

  @override
  Stream<AudioGuardEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map(_decode)
      .where((e) => e != null)
      .cast<AudioGuardEvent>();

  static AudioGuardEvent? _decode(dynamic raw) {
    if (raw is! Map) return null;
    switch (raw['type']) {
      case 'volume':
        final v = raw['value'];
        return v is int ? AudioGuardEvent.volume(v) : null;
      case 'outputLost':
        return const AudioGuardEvent.outputLost();
    }
    return null;
  }

  @override
  Future<int?> get mediaVolume async {
    try {
      return await _method.invokeMethod<int>('getMediaVolume');
    } catch (_) {
      return null;
    }
  }
}

class _NoopAudioGuard implements AudioGuardPlatform {
  const _NoopAudioGuard();

  @override
  Stream<AudioGuardEvent> get events => const Stream<AudioGuardEvent>.empty();

  @override
  Future<int?> get mediaVolume async => null;
}

/// 播放守卫：订阅 [AudioGuardPlatform] 信号，在开关开启且**正在播放**时请求暂停。
///
/// 与 [PlayerProvider] 解耦（回调注入），便于单测：音量事件仅在
/// [volumePauseEnabled] 为真且档位为 0 时触发；断连事件仅在
/// [disconnectPauseEnabled] 为真时触发。订阅按需起停（[refresh]），
/// 两个开关全关时取消订阅（原生侧随之注销监听）。
class PlaybackGuard {
  PlaybackGuard({
    required AudioGuardPlatform platform,
    required bool Function() volumePauseEnabled,
    required bool Function() disconnectPauseEnabled,
    required bool Function() isPlaying,
    required Future<void> Function() onPause,
  })  : _platform = platform,
        _volumePauseEnabled = volumePauseEnabled,
        _disconnectPauseEnabled = disconnectPauseEnabled,
        _isPlaying = isPlaying,
        _onPause = onPause;

  final AudioGuardPlatform _platform;
  final bool Function() _volumePauseEnabled;
  final bool Function() _disconnectPauseEnabled;
  final bool Function() _isPlaying;
  final Future<void> Function() _onPause;

  StreamSubscription<AudioGuardEvent>? _sub;
  bool _disposed = false;

  /// 依据当前开关同步订阅状态：任一开启则订阅（并补查一次当前音量），
  /// 全关则取消。可在设置变动后反复调用。
  void refresh() {
    if (_disposed) return;
    if (_volumePauseEnabled() || _disconnectPauseEnabled()) {
      _sub ??= _platform.events.listen(_handle, onError: (_) {});
      if (_volumePauseEnabled()) unawaited(_checkInitialVolume());
    } else {
      _sub?.cancel();
      _sub = null;
    }
  }

  /// 订阅时当前音量已为 0 时立即暂停（否则要等下一次音量变化事件）。
  Future<void> _checkInitialVolume() async {
    final v = await _platform.mediaVolume;
    if (v == 0) _handle(const AudioGuardEvent.volume(0));
  }

  void _handle(AudioGuardEvent e) {
    if (_disposed) return;
    final shouldPause = switch (e.type) {
      AudioGuardEventType.volume => _volumePauseEnabled() && e.value == 0,
      AudioGuardEventType.outputLost => _disconnectPauseEnabled(),
    };
    if (!shouldPause || !_isPlaying()) return;
    unawaited(_onPause());
  }

  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _sub = null;
  }
}
