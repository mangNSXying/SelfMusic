import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 鸿蒙系统 AVPlayer 的 just_audio 平台实现（ohos 播放后端）。
///
/// 与 PlayerProvider / just_audio 同契约：应用层不感知后端差异。
/// 差异只有两处：
/// - 位置/时长由 ArkTS 侧 AVPlayer 事件上报（timeUpdate 默认 100ms），
///   不再用 200ms Dart Timer 轮询；
/// - 错误经 `playbackEventMessageStream.addError` 冒泡（just_audio 0.9.46
///   只认流上的 error；PlaybackEventMessage.errorCode 不会被消费）。
///
/// 通道协议见 `frontend/ohos/entry/src/main/ets/media/AvPlayerBridge.ets`。
class AvPlayerJustAudio extends JustAudioPlatform {
  static const MethodChannel _channel = MethodChannel('selfmusic/avplayer');
  static const EventChannel _eventChannel =
      EventChannel('selfmusic/avplayer/events');

  final Map<String, AvPlayerHandle> _players = {};
  bool _listening = false;

  /// just_audio 事件通道全局只订阅一次（事件带 playerId 分发）。
  void _ensureListening() {
    if (_listening) return;
    _listening = true;
    _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is! Map) return;
        final id = event['playerId'];
        if (id is! String) return;
        _players[id]?.handleEvent(event);
      },
      onError: (Object e) {
        debugPrint('[AvPlayerJustAudio] 事件通道错误: $e');
      },
    );
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    _ensureListening();
    final id = request.id;
    await _channel.invokeMethod<void>('createPlayer', {'playerId': id});
    final handle = AvPlayerHandle(id);
    _players[id] = handle;
    return handle;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    final handle = _players.remove(request.id);
    await handle?.release();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    try {
      await _channel.invokeMethod<void>('disposeAll');
    } catch (e) {
      debugPrint('[AvPlayerJustAudio] disposeAll 异常: $e');
    }
    for (final handle in _players.values) {
      await handle.release(notifyNative: false);
    }
    _players.clear();
    return DisposeAllPlayersResponse();
  }
}

/// 单个 just_audio 播放器句柄：命令转发 + 原生事件 → PlaybackEventMessage。
class AvPlayerHandle extends AudioPlayerPlatform {
  AvPlayerHandle(super.id);

  static const MethodChannel _channel = MethodChannel('selfmusic/avplayer');

  final StreamController<PlaybackEventMessage> _events =
      StreamController<PlaybackEventMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _position = Duration.zero;
  Duration _buffered = Duration.zero;
  Duration? _duration;
  bool _loading = false;
  bool _transcodeStream = false;
  bool _released = false;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final source = request.audioSourceMessage;
    if (source is! UriAudioSourceMessage) {
      throw UnsupportedError(
          '[AvPlayerHandle] 不支持的音源类型: ${source.runtimeType}');
    }
    final uri = source.uri;
    _loading = true;
    _transcodeStream = uri.contains('/transcode/stream');
    _duration = null;
    _buffered = Duration.zero;
    _position = request.initialPosition ?? Duration.zero;
    _processingState = ProcessingStateMessage.loading;
    _emit();

    String? filePath;
    var playUrl = uri;
    if (uri.startsWith('file://')) {
      filePath = Uri.parse(uri).toFilePath();
      playUrl = '';
    }
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('load', {
        'playerId': id,
        if (filePath != null) 'filePath': filePath else 'url': playUrl,
        'headersJson': jsonEncode(source.headers ?? const <String, String>{}),
        'initialPositionMs': request.initialPosition?.inMilliseconds ?? 0,
      });
      final ms = result?['durationMs'];
      _duration = (!_transcodeStream && ms is num && ms > 0)
          ? Duration(milliseconds: ms.toInt())
          : null;
      _processingState = ProcessingStateMessage.ready;
      return LoadResponse(duration: _duration);
    } finally {
      _loading = false;
      _emit();
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    await _channel.invokeMethod<void>('play', {'playerId': id});
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    await _channel.invokeMethod<void>('pause', {'playerId': id});
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    final pos = request.position ?? Duration.zero;
    _position = pos;
    _emit();
    await _channel.invokeMethod<void>('seek', {
      'playerId': id,
      'positionMs': pos.inMilliseconds,
    });
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    try {
      await _channel.invokeMethod<void>('setVolume', {
        'playerId': id,
        'volume': request.volume,
      });
    } catch (e) {
      // 音量异常不影响播放主链路（与平台侧静默口径一致）。
      debugPrint('[AvPlayerHandle] setVolume 忽略异常: $e');
    }
    return SetVolumeResponse();
  }

  // ---- 应用未使用的能力：保持 just_audio 内部调用不炸 ----

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async =>
      SetPitchResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
          SetShuffleModeRequest request) async =>
      SetShuffleModeResponse();

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(
          SetSkipSilenceRequest request) async =>
      SetSkipSilenceResponse();

  // ---------- 原生事件 → just_audio ----------

  void handleEvent(Map<dynamic, dynamic> event) {
    if (_released) return;
    final type = event['type'];
    switch (type) {
      case 'state':
        final state = event['state'];
        if (state is String) _onNativeState(state);
        break;
      case 'position':
        final value = event['value'];
        if (value is num) {
          _position = Duration(milliseconds: value.toInt());
          _emit();
        }
        break;
      case 'duration':
        final value = event['value'];
        if (!_transcodeStream && value is num) {
          final ms = value.toInt();
          final next = ms > 0 ? Duration(milliseconds: ms) : null;
          if (next != _duration) {
            _duration = next;
            _emit();
          }
        }
        break;
      case 'buffered':
        final infoType = event['infoType'];
        final value = event['value'];
        // BufferingInfoType.CACHED_DURATION = 4（其余为 start/end/percent）。
        if (infoType is num && infoType.toInt() == 4 && value is num) {
          _buffered = Duration(milliseconds: value.toInt());
          _emit();
        }
        break;
      case 'seekDone':
        final value = event['value'];
        if (value is num) {
          _position = Duration(milliseconds: value.toInt());
          _emit();
        }
        break;
      case 'error':
        final code = event['code'];
        final message = event['message'];
        _processingState = ProcessingStateMessage.idle;
        _emit();
        // 播中错误的唯一出口（PlayerProvider 的恢复/冷却/跳曲链路依赖它）。
        _events.addError(PlatformException(
          code: '$code',
          message: message is String ? message : 'AVPlayer 错误',
        ));
        break;
    }
  }

  void _onNativeState(String state) {
    switch (state) {
      case 'prepared':
      case 'playing':
      case 'paused':
        _processingState = ProcessingStateMessage.ready;
        _emit();
        break;
      case 'completed':
        _processingState = ProcessingStateMessage.completed;
        _position = _duration ?? _position;
        _emit();
        break;
      case 'stopped':
      case 'idle':
        // load 期间 reset 产生的 idle/stopped 归 load 内部状态机，不外泄成
        // ProcessingState.idle（会触发 just_audio 停用平台实例）。
        if (_loading) return;
        _processingState = ProcessingStateMessage.idle;
        _emit();
        break;
    }
  }

  Future<void> release({bool notifyNative = true}) async {
    if (_released) return;
    _released = true;
    if (notifyNative) {
      try {
        await _channel.invokeMethod<void>('dispose', {'playerId': id});
      } catch (e) {
        debugPrint('[AvPlayerHandle] dispose 异常: $e');
      }
    }
    await _events.close();
  }

  void _emit() {
    if (_released || _events.isClosed) return;
    _events.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _buffered,
      duration: _duration,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }
}
