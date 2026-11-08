import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/harmonyos/ohos_bootstrap.dart' show isOhos;
import 'audio_focus_monitor.dart';

/// 播放保护自动暂停的触发源（settings.md §3.2）。
///
/// 焦点、静音、断连三项共用同一套暂停入口；平台差异只保留在信号层，
/// 不再让焦点暂停走一条独立的状态收口路径。
enum AutoPauseReason {
  /// 媒体音量归零。
  volumeZero,

  /// 当前播放输出设备断开。
  outputLost,

  /// 临时失去音频焦点（来电/他应用抢占），恢复后可按开关续播。
  audioFocus,

  /// 永久失去音频焦点（STOP），只暂停，不自动恢复。
  audioFocusStop,
}

/// 一次自动暂停请求。
class AutoPauseRequest {
  final AutoPauseReason reason;

  /// 焦点中断发生前原生播放器是否真的在播；非焦点事件为 null。
  ///
  /// 原生状态可能滞后（装载中、play 挂起、系统强制暂停不改 state），
  /// 不能只依赖本地的 `player.playing`。
  final bool? focusWasPlaying;

  const AutoPauseRequest(this.reason, {this.focusWasPlaying});

  bool get isFocus =>
      reason == AutoPauseReason.audioFocus ||
      reason == AutoPauseReason.audioFocusStop;
}

/// 静音暂停 / 断连暂停的平台信号（settings.md §3.2，Android/鸿蒙）。
///
/// 之所以自持原生监听而不用 `audio_session`：后者的 becoming-noisy 接收器只在
/// just_audio 因音频焦点接管而请求焦点时才注册——音频焦点关闭时「断连暂停」会
/// 彻底失效，恰是用户最需要该功能的情形。故两端各自新增独立原生通道
/// （Android：[AudioGuard.kt]；鸿蒙：[AudioGuardBridge.ets]，通道同名）：
/// - MethodChannel `com.shamiko.selfmusic/audio_guard`：`getMediaVolume()`；
/// - EventChannel `com.shamiko.selfmusic/audio_guard/events`：媒体音量变化
///   （`{type:"volume", value:int}`）与当前输出设备断开（`{type:"outputLost"}`）。
///
/// 其它平台无实现，返回空信号源（与均衡器/音频焦点同样「Android/鸿蒙生效」）。

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
  /// 原生订阅时主动回推一次当前音量，这里用于开始播放时补判静音暂停。
  Future<int?> get mediaVolume;

  /// 当前平台实现：Android/鸿蒙走原生通道，其余平台 no-op。
  static AudioGuardPlatform forCurrentPlatform() {
    if (!kIsWeb && (Platform.isAndroid || isOhos)) return _NativeAudioGuard();
    return const _NoopAudioGuard();
  }
}

class _NativeAudioGuard implements AudioGuardPlatform {
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

/// 播放守卫：焦点 / 静音 / 断连三项共用的唯一自动暂停入口。
///
/// - [AudioGuardPlatform] 提供音量归零与输出断开信号；
/// - [AudioFocusPlatform] 提供鸿蒙焦点抢占/恢复信号（Android 为空流）；
/// - 所有触发都经统一的 [onPause] 交回 PlayerProvider，避免焦点一套、
///   静音/断连另一套的重复暂停路径。
///
/// 音量与断连事件仍要求**正在播放**；焦点事件始终上送，由 PlayerProvider
/// 结合 [AutoPauseRequest.focusWasPlaying] 与本地播放态决定是否收口。
class PlaybackGuard {
  PlaybackGuard({
    required AudioGuardPlatform platform,
    required AudioFocusPlatform focusPlatform,
    required bool Function() volumePauseEnabled,
    required bool Function() disconnectPauseEnabled,
    required bool Function() isPlaying,
    required Future<void> Function(AutoPauseRequest request) onPause,
    required Future<void> Function() onResume,
  })  : _platform = platform,
        _focusPlatform = focusPlatform,
        _volumePauseEnabled = volumePauseEnabled,
        _disconnectPauseEnabled = disconnectPauseEnabled,
        _isPlaying = isPlaying,
        _onPause = onPause,
        _onResume = onResume;

  final AudioGuardPlatform _platform;
  final AudioFocusPlatform _focusPlatform;
  final bool Function() _volumePauseEnabled;
  final bool Function() _disconnectPauseEnabled;
  final bool Function() _isPlaying;
  final Future<void> Function(AutoPauseRequest request) _onPause;
  final Future<void> Function() _onResume;

  StreamSubscription<AudioGuardEvent>? _guardSub;
  StreamSubscription<AudioFocusEvent>? _focusSub;
  bool _disposed = false;

  /// 依据当前开关同步订阅状态：静音/断连任一开启则订阅原生守卫信号，
  /// 全关则取消。焦点信号常驻订阅——鸿蒙系统强制暂停后，即使开关关闭
  /// 也需要同步 UI/断点，开关只决定焦点恢复时是否自动续播。
  void refresh() {
    if (_disposed) return;
    if (_volumePauseEnabled() || _disconnectPauseEnabled()) {
      _guardSub ??= _platform.events.listen(_handleGuardEvent, onError: (_) {});
    } else {
      _guardSub?.cancel();
      _guardSub = null;
    }
    _focusSub ??=
        _focusPlatform.events.listen(_handleFocusEvent, onError: (_) {});
  }

  /// 开始/恢复播放时补判一次当前媒体音量。
  ///
  /// 先静音再按播放不会产生 volumeChange 事件，单靠订阅监听会漏掉
  /// 「静音暂停」；原生 onListen 的首次回推只覆盖订阅时刻。
  void onPlaybackStarted() {
    if (_disposed || !_volumePauseEnabled()) return;
    unawaited(_checkCurrentVolume());
  }

  Future<void> _checkCurrentVolume() async {
    final v = await _platform.mediaVolume;
    if (_disposed || v != 0) return;
    _emitPause(const AutoPauseRequest(AutoPauseReason.volumeZero));
  }

  void _handleGuardEvent(AudioGuardEvent e) {
    final shouldPause = switch (e.type) {
      AudioGuardEventType.volume => _volumePauseEnabled() && e.value == 0,
      AudioGuardEventType.outputLost => _disconnectPauseEnabled(),
    };
    if (!shouldPause) return;
    _emitPause(AutoPauseRequest(e.type == AudioGuardEventType.volume
        ? AutoPauseReason.volumeZero
        : AutoPauseReason.outputLost));
  }

  void _handleFocusEvent(AudioFocusEvent e) {
    switch (e.type) {
      case AudioFocusEventType.pause:
        _emitPause(AutoPauseRequest(
          AutoPauseReason.audioFocus,
          focusWasPlaying: e.wasPlaying,
        ));
        break;
      case AudioFocusEventType.stop:
        _emitPause(AutoPauseRequest(
          AutoPauseReason.audioFocusStop,
          focusWasPlaying: e.wasPlaying,
        ));
        break;
      case AudioFocusEventType.resume:
        unawaited(_onResume());
        break;
    }
  }

  void _emitPause(AutoPauseRequest request) {
    if (_disposed) return;
    // 焦点事件即使本地 playing 已翻转也要交给 Provider 收口断点/UI；
    // 音量与断连事件仍要求真正在播，避免恢复界面时误暂停。
    if (!request.isFocus && !_isPlaying()) return;
    unawaited(_onPause(request));
  }

  void dispose() {
    _disposed = true;
    _guardSub?.cancel();
    _guardSub = null;
    _focusSub?.cancel();
    _focusSub = null;
  }
}
