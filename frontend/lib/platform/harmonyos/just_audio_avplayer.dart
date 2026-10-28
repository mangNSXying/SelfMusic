import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

/// 鸿蒙 AVPlayer `audioInterrupt` 的 hint 类型。
enum AvPlayerFocusHint { pause, resume, stop, duck, unduck }

/// 一次原生音频焦点中断（由 `AvPlayerBridge.ets` 上报）。
class AvPlayerFocusEvent {
  final String playerId;
  final AvPlayerFocusHint hint;

  /// 系统已强制暂停/停止（`INTERRUPT_FORCE`）。
  final bool forced;

  /// 中断发生前 AVPlayer 是否处于 playing。系统强制暂停不会把 state 改成
  /// paused，该字段必须在调用 pause() 前采样。
  final bool wasPlaying;

  /// 中断时刻的原生位置（毫秒）；未知时为 null。
  final Duration? position;

  const AvPlayerFocusEvent({
    required this.playerId,
    required this.hint,
    required this.forced,
    required this.wasPlaying,
    this.position,
  });
}

final StreamController<AvPlayerFocusEvent> _focusEvents =
    StreamController<AvPlayerFocusEvent>.broadcast();

/// 全局焦点事件流：PlayerProvider 经 `AudioFocusPlatform` 消费。
Stream<AvPlayerFocusEvent> get avPlayerFocusEvents => _focusEvents.stream;

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

  /// 原生播放态回传：鸿蒙系统强制暂停音频流时 AVPlayer.state 仍是 playing，
  /// 只有桥里的 audioInterrupt 回调能感知。把原生 paused/stopped 同步给
  /// just_audio，`playing`/进度条才不会继续假走。
  final StreamController<PlayerDataMessage> _playerData =
      StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _position = Duration.zero;
  Duration _buffered = Duration.zero;
  Duration? _duration;
  bool _loading = false;
  bool _transcodeStream = false;
  bool _released = false;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _playerData.stream;

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
    final args = <String, dynamic>{
      'playerId': id,
      if (filePath != null) 'filePath': filePath else 'url': playUrl,
      'headersJson': jsonEncode(source.headers ?? const <String, String>{}),
      'initialPositionMs': request.initialPosition?.inMilliseconds ?? 0,
    };
    try {
      Map<dynamic, dynamic>? result;
      try {
        result =
            await _channel.invokeMethod<Map<dynamic, dynamic>>('load', args);
      } on PlatformException catch (e) {
        if (_released || !_isNativeMissing(e)) rethrow;
        // 原生实例已不在，而 just_audio 仍认为平台处于激活态、不会自行重建
        // （见 AvPlayerBridge.detachEntry 注释的竞态）。不在这里兜底就只能
        // 重启应用：重建一次原生实例后重试本次装载。
        await _channel.invokeMethod<void>('createPlayer', {'playerId': id});
        result =
            await _channel.invokeMethod<Map<dynamic, dynamic>>('load', args);
      }
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

  /// 原生按 playerId 找不到实例（load 之外的错误消息不带 id）。
  static bool _isNativeMissing(PlatformException e) =>
      e.code == '404' && (e.message?.contains('播放器不存在') ?? false);

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (_released) return PlayResponse();
    await _channel.invokeMethod<void>('play', {'playerId': id});
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (_released) return PauseResponse();
    await _channel.invokeMethod<void>('pause', {'playerId': id});
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (_released) return SeekResponse();
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
    if (_released) return SetVolumeResponse();
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
        if (state is String) {
          // paused 状态自带原生真实停顿位置：先刷新 _position 再 _emit，
          // 防止手动暂停后进度条回跳到上一次 timeUpdate。
          final positionMs = event['positionMs'];
          if (positionMs is num && positionMs >= 0) {
            _position = Duration(milliseconds: positionMs.toInt());
          }
          _onNativeState(state);
        }
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
      case 'audioInterrupt':
        _onAudioInterrupt(event);
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
        _processingState = ProcessingStateMessage.ready;
        _emit();
        break;
      case 'playing':
        _processingState = ProcessingStateMessage.ready;
        _emit();
        _emitPlaying(true);
        break;
      case 'paused':
        _processingState = ProcessingStateMessage.ready;
        _emit();
        _emitPlaying(false);
        break;
      case 'completed':
        _processingState = ProcessingStateMessage.completed;
        _position = _duration ?? _position;
        _emit();
        // 不在这里翻 playing=false：PlayerProvider 依赖 st.playing 为 true
        // 处理自动续播；完成态由 processingState=completed 表达。
        break;
      case 'stopped':
      case 'idle':
        // load 期间 reset 产生的 idle/stopped 归 load 内部状态机，不外泄成
        // ProcessingState.idle（会触发 just_audio 停用平台实例）。
        if (_loading) return;
        _processingState = ProcessingStateMessage.idle;
        _emit();
        _emitPlaying(false);
        break;
    }
  }

  /// 原生 audioInterrupt → Dart。
  ///
  /// 关键顺序：
  /// 1. 先投递焦点事件，让 PlayerProvider 置「焦点暂停」标记；
  /// 2. 再用中断时刻的原生位置刷新 _position 并翻转 playing=false。
  ///    这样 just_audio 的 position getter 从墙钟插值立刻退回停顿点 T1，
  ///    Provider 收口时保存的断点也是 T1，而不是假走的 T2。
  void _onAudioInterrupt(Map<dynamic, dynamic> event) {
    final hint = _focusHintOf(event['hint']);
    if (hint == null) return;
    final forced = event['forced'] == true || event['forced'] == 1;
    final wasPlaying = event['wasPlaying'] == true || event['wasPlaying'] == 1;
    final rawPosition = event['positionMs'];
    final position = rawPosition is num && rawPosition >= 0
        ? Duration(milliseconds: rawPosition.toInt())
        : null;

    _focusEvents.add(AvPlayerFocusEvent(
      playerId: id,
      hint: hint,
      forced: forced,
      wasPlaying: wasPlaying,
      position: position,
    ));

    if ((hint == AvPlayerFocusHint.pause || hint == AvPlayerFocusHint.stop) &&
        wasPlaying) {
      if (position != null) _position = position;
      _emit();
      _emitPlaying(false);
    }
  }

  static AvPlayerFocusHint? _focusHintOf(dynamic raw) {
    switch (raw) {
      case 'pause':
        return AvPlayerFocusHint.pause;
      case 'resume':
        return AvPlayerFocusHint.resume;
      case 'stop':
        return AvPlayerFocusHint.stop;
      case 'duck':
        return AvPlayerFocusHint.duck;
      case 'unduck':
        return AvPlayerFocusHint.unduck;
    }
    return null;
  }

  void _emitPlaying(bool value) {
    if (_released || _playerData.isClosed) return;
    _playerData.add(PlayerDataMessage(playing: value));
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
    await _playerData.close();
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
