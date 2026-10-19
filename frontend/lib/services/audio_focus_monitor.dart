import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/harmonyos/just_audio_avplayer.dart';
import '../platform/harmonyos/ohos_bootstrap.dart' show isOhos;

/// 音频焦点中断（自动暂停/恢复，settings.md §3.2）。
///
/// Android 由 just_audio 的 `handleInterruptions` 内部消费 `audio_session`
/// 焦点事件，Dart 应用层无需再订阅；鸿蒙 `audio_session` 是空实现，
/// AVPlayer 被系统抢占时也不会自动把 `state` 改成 paused，必须由
/// `AvPlayerBridge` 的 `audioInterrupt` 回调转成 [AudioFocusEvent]，交给
/// PlayerProvider 收口 UI/断点并按开关决定是否自动续播。
enum AudioFocusEventType { pause, resume, stop }

/// 一次音频焦点中断。
class AudioFocusEvent {
  final AudioFocusEventType type;

  /// 系统已强制暂停/停止（AVPlayer 的 `INTERRUPT_FORCE`）：原生桥已代为
  /// pause，Dart 侧只做状态收口，不再重复调用 pause。
  final bool forced;

  /// 中断发生时原生播放器是否真的在播；false 表示本来就暂停，忽略。
  final bool wasPlaying;

  const AudioFocusEvent({
    required this.type,
    required this.forced,
    required this.wasPlaying,
  });
}

/// 音频焦点事件源。其它平台（含 Android）返回空流，保持既有行为。
abstract class AudioFocusPlatform {
  Stream<AudioFocusEvent> get events;

  static AudioFocusPlatform forCurrentPlatform() {
    if (!kIsWeb && isOhos) return _OhosAudioFocusPlatform();
    return const _NoopAudioFocusPlatform();
  }
}

class _OhosAudioFocusPlatform implements AudioFocusPlatform {
  Stream<AudioFocusEvent>? _stream;

  @override
  Stream<AudioFocusEvent> get events => _stream ??= avPlayerFocusEvents
      .where((e) =>
          e.hint == AvPlayerFocusHint.pause ||
          e.hint == AvPlayerFocusHint.resume ||
          e.hint == AvPlayerFocusHint.stop)
      .map((e) => AudioFocusEvent(
            type: switch (e.hint) {
              AvPlayerFocusHint.pause => AudioFocusEventType.pause,
              AvPlayerFocusHint.resume => AudioFocusEventType.resume,
              _ => AudioFocusEventType.stop,
            },
            forced: e.forced,
            wasPlaying: e.wasPlaying,
          ));
}

class _NoopAudioFocusPlatform implements AudioFocusPlatform {
  const _NoopAudioFocusPlatform();

  @override
  Stream<AudioFocusEvent> get events => const Stream<AudioFocusEvent>.empty();
}
