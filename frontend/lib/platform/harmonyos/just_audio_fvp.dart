import 'dart:async';

import 'package:fvp/mdk.dart' as mdk;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import 'avio_headers.dart';
import 'harmonyos_player_flags.dart';

/// just_audio 平台层 → fvp（libmdk 后端）的纯 Dart 适配（HarmonyOS）。
///
/// 背景：just_audio 无 ohos 官方实现；本适配层把 [JustAudioPlatform]
/// 契约映射到 vendored fvp 的 `package:fvp/mdk.dart`（FFI 直连 libfvp.so），
/// 不涉及任何 ArkTS。
///
/// 覆盖面（对照 app 实际调用，player_provider 只用以下能力）：
/// - load：UrlSource/setFilePath（file://、https://+Basic 头、DirectAudioSource
///   经 just_audio 内部代理后的 http://127.0.0.1/ 三种形态都到达
///   [UriAudioSourceMessage]，统一处理）
/// - play / pause / seek / setVolume，以及 completed→自动切歌、错误上报
/// - 倍速/循环一并接上（成本极低）；pitch/shuffle/skipSilence 静默忽略
///
/// 映射要点：
/// - mdk `prepare()`：0 成功、负数失败（-1 already loaded → load 前对同一
///   媒体先回 `stopped` 复位）
/// - mdk 无位置流：播放中用 200ms Timer 轮询 `position`/`buffered()`
/// - mdk `state=stopped` 且非加载复位/错误 → just_audio `completed`（app 的
///   自动切歌依赖此事件）
/// - 请求头：mdk/FFmpeg 经 `avio.headers` 原生承载（`Authorization: Basic/
///   Bearer`、`X-Origin-Auth/Ssh/Smb` 全部原样透传）。应用侧对鸿蒙关闭了
///   just_audio 的 Dart 回环代理（`useProxyForRequestHeaders:false`），
///   避免其主 isolate 代理在 fork 引擎上死锁/空转（2026-10-12 修复）。
/// - 自签名：`avio.tls_verify=0` 随 [ohosPlayerAllowSelfSigned] 设置，
///   覆盖自签后端/WebDAV 的原生播放（与 dart:io 侧 badCertificateCallback 同口径）
/// - 音量语义一致：两边都是 0.0-1.0（mdk 1.0 = 源音量）
class FvpJustAudio extends JustAudioPlatform {
  final _players = <String, FvpAudioPlayer>{};

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final player = FvpAudioPlayer(request.id);
    _players[request.id] = player;
    return player;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
      DisposePlayerRequest request) async {
    _players.remove(request.id)?.release();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(
      DisposeAllPlayersRequest request) async {
    for (final p in _players.values.toList()) {
      p.release();
    }
    _players.clear();
    return DisposeAllPlayersResponse();
  }
}

/// 单个播放器的平台层实现。
class FvpAudioPlayer extends AudioPlayerPlatform {
  static const _kErrorCode = 1;

  final mdk.Player _player = mdk.Player();
  final _eventController = StreamController<PlaybackEventMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _position = Duration.zero;
  Duration _buffered = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  int? _errorCode;
  String? _errorMessage;

  /// load 进行中：mdk 复位产生的 stopped 事件不算「播完」。
  bool _loading = false;

  /// 已上报错误：随后 mdk 回 stopped 时不再当作 completed。
  bool _failed = false;

  Timer? _ticker;

  FvpAudioPlayer(super.id) {
    _player.onStateChanged.listen(_onStateChanged);
    _player.onMediaStatus.listen(_onMediaStatus);
    _player.onEvent.listen(_onMediaEvent);
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  // ---------- 平台层方法 ----------

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final src = request.audioSourceMessage;
    if (src is! UriAudioSourceMessage) {
      // app 只用 UrlSource/StreamAudioSource（均为 Progressive 消息），
      // Concatenating/Clipping/Silence 等不支持。
      throw UnsupportedError(
          '[FvpAudioPlayer] 不支持的音源类型: ${src.runtimeType}');
    }
    _loading = true;
    _failed = false;
    _errorCode = null;
    _errorMessage = null;
    _duration = null;
    _buffered = Duration.zero;
    _position = request.initialPosition ?? Duration.zero;
    _processingState = ProcessingStateMessage.loading;
    _emit();
    try {
      final uri = _resolveUri(src);
      if (_player.media == uri &&
          _player.state != mdk.PlaybackState.stopped) {
        // 同一媒体重复 load（如重播当前曲目）：mdk 对已加载媒体 prepare 返回
        // -1（already loaded），先回 stopped 复位。
        _player.state = mdk.PlaybackState.stopped;
      }
      // 请求头与 TLS 策略须在 setMedia 前设定（mdk 在 prepare 时读取 avio 选项）。
      _applyHttpSettings(src);
      // 探测策略同样在 prepare 前设定（mdk 在 prepare 时读取 avformat 选项）。
      _applyProbePolicy(uri);
      _player.media = uri;
      final ret = await _player.prepare(
          position: request.initialPosition?.inMilliseconds ?? 0);
      if (ret < 0) {
        throw PlatformException(
          code: 'ohos-load-failed',
          message: 'mdk prepare 返回 $ret（uri: ${_redact(uri)}）',
        );
      }
      final ms = _player.mediaInfo.duration;
      _duration = ms > 0 ? Duration(milliseconds: ms) : null;
      _processingState = ProcessingStateMessage.ready;
      _emit();
      return LoadResponse(duration: _duration);
    } finally {
      _loading = false;
    }
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _playing = true;
    _player.state = mdk.PlaybackState.playing;
    _startTicker();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    _player.state = mdk.PlaybackState.paused;
    _stopTicker();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    final pos = request.position ?? Duration.zero;
    _position = pos;
    try {
      final ret = await _player.seek(position: pos.inMilliseconds);
      // -2 = 被更新的 seek 取代；-10 = 失败。都不打断 UI。
      if (ret < 0) {
        debugPrint('[FvpAudioPlayer] seek 返回 $ret');
      }
    } catch (e) {
      debugPrint('[FvpAudioPlayer] seek 异常: $e');
    }
    _emit();
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    _player.volume = request.volume;
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    _player.playbackRate = request.speed;
    return SetSpeedResponse();
  }

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    // mdk loop：-1 无限循环、0 不循环。单曲播放场景 all 无意义，按 one 处理。
    _player.loop = request.loopMode == LoopModeMessage.off ? 0 : -1;
    return SetLoopModeResponse();
  }

  // app 未使用；mdk 无对应能力，静默接受保持 just_audio 内部调用不炸。
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

  // ---------- mdk 事件 → just_audio 事件 ----------

  void _onStateChanged(
      ({mdk.PlaybackState oldValue, mdk.PlaybackState newValue}) event) {
    final s = event.newValue;
    if (s == mdk.PlaybackState.stopped) {
      _stopTicker();
      // load 复位 / 已上报错误后的 stopped 不是「播完」。
      if (_loading || _failed) return;
      if (_playing) {
        _playing = false;
        _position = _duration ?? _position;
        _processingState = ProcessingStateMessage.completed;
        _emit();
      }
      return;
    }
    if (s == mdk.PlaybackState.playing) {
      _startTicker();
    } else if (s == mdk.PlaybackState.paused) {
      _stopTicker();
      _emit();
    }
  }

  void _onMediaStatus(
      ({mdk.MediaStatus oldValue, mdk.MediaStatus newValue}) event) {
    final s = event.newValue;
    if (s.test(mdk.MediaStatus.invalid)) {
      _failed = true;
      _stopTicker();
      _errorCode = _kErrorCode;
      _errorMessage = '媒体无效或加载失败';
      _processingState = ProcessingStateMessage.idle;
      _emit();
      return;
    }
    if (_processingState == ProcessingStateMessage.completed ||
        _processingState == ProcessingStateMessage.idle) {
      return;
    }
    if (s.test(mdk.MediaStatus.loaded)) {
      final ms = _player.mediaInfo.duration;
      if (ms > 0) _duration = Duration(milliseconds: ms);
      _processingState = (s.test(mdk.MediaStatus.buffering) &&
              !s.test(mdk.MediaStatus.buffered))
          ? ProcessingStateMessage.buffering
          : ProcessingStateMessage.ready;
      _emit();
    } else if (s.test(mdk.MediaStatus.loading)) {
      _processingState = ProcessingStateMessage.loading;
      _emit();
    }
  }

  void _onMediaEvent(mdk.MediaEvent ev) {
    // category 如 reader/decoder 错误；error 字段在 buffering 事件里是进度值，
    // 只按 category 判错。
    if (ev.category.toLowerCase().contains('error')) {
      _failed = true;
      _stopTicker();
      _errorCode = _kErrorCode;
      _errorMessage = '${ev.category}: ${ev.detail}';
      _processingState = ProcessingStateMessage.idle;
      _emit();
    }
  }

  // ---------- 内部 ----------

  /// 把平台层收到的 URI 调成 mdk 可直接播放的形态：
  /// - `file://` → 裸本地路径（缓存文件播放，mdk 原生支持）
  ///
  /// HTTP(S) 请求头不再折进 URL：应用侧对鸿蒙关闭了 just_audio 回环代理，
  /// 头经 [_applyHttpSettings] 以 `avio.headers` 原生下发（含 Basic/Bearer）。
  String _resolveUri(UriAudioSourceMessage src) {
    final uri = src.uri;
    if (uri.startsWith('file://')) {
      return Uri.parse(uri).toFilePath();
    }
    return uri;
  }

  /// 装载前把 HTTP 请求头与 TLS 校验策略下发给 mdk：
  /// - `avio.headers`：`Header: Value\r\n` 逐条拼接（空 map 设空串清除上一曲残留）；
  /// - `avio.tls_verify`：自签名开关开时 `0`（不校验），否则 `1`（默认校验）。
  void _applyHttpSettings(UriAudioSourceMessage src) {
    _player.setProperty('avio.headers', buildAvioHeaders(src.headers));
    _player.setProperty(
        'avio.tls_verify', ohosPlayerAllowSelfSigned ? '0' : '1');
  }

  /// 转码流探测策略（转码卡顿根因修复）：
  /// 转码输出三无（无 Content-Length、`Accept-Ranges: none`、pipe 输出写不出
  /// 有效 Xing 时长头），常规探测（默认 probesize 5MB ≈ 整首 192k 体积）会把
  /// 整流读完才返回，`prepare()` 卡到 EOS（整首下完才播）。转码 URL 限小探测
  /// 秒回（duration 取 null，app 侧已容忍）；其余恢复 ffmpeg 默认，避免影响
  /// 直连/本地（同一 mdk 实例复用，必须显式复位，否则转码后播直连仍是小探测）。
  void _applyProbePolicy(String uri) {
    if (uri.contains('/transcode/stream')) {
      _player.setProperty('avformat.probesize', '524288');
      _player.setProperty('avformat.analyzeduration', '500000');
      _player.setProperty('avformat.fflags', '+nobuffer');
    } else {
      _player.setProperty('avformat.probesize', '5000000');
      _player.setProperty('avformat.analyzeduration', '0');
      _player.setProperty('avformat.fflags', '-nobuffer');
    }
  }

  /// 日志脱敏：隐藏 userinfo，避免凭据进日志。
  String _redact(String uri) {
    try {
      final u = Uri.parse(uri);
      return u.userInfo.isEmpty ? uri : u.replace(userInfo: '***').toString();
    } catch (_) {
      return uri;
    }
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (_eventController.isClosed) return;
      final pos = _player.position;
      _position = Duration(milliseconds: pos);
      _buffered = Duration(milliseconds: pos + _player.buffered());
      _emit();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _emit() {
    if (_eventController.isClosed) return;
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _buffered,
      duration: _duration,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
      errorCode: _errorCode,
      errorMessage: _errorMessage,
    ));
  }

  /// 释放资源（由 [FvpJustAudio.disposePlayer] 调用）。
  void release() {
    _stopTicker();
    _playing = false;
    try {
      // fvp 的 dispose 为 void async：纯音频且已加载过媒体时可正常走完
      // （_videoSize 已 complete）；未加载过时其内部挂起不影响本线程。
      _player.dispose();
    } catch (e) {
      debugPrint('[FvpAudioPlayer] release 异常: $e');
    }
    unawaited(_eventController.close());
  }
}

