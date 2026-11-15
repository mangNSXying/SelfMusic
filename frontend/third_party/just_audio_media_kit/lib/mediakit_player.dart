library just_audio_media_kit;

import 'dart:async';

import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'src/set_property.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player]
class MediaKitPlayer extends AudioPlayerPlatform {
  static const kErrorCode = 1;

  /// `package:media_kit`'s [Player]
  late final Player _player;

  /// The subscriptions that have to be disposed
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();

  /// Completes when the player is ready
  Future<void> ready() => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _mediaOpened = false;

  /// 已释放（just_audio 的 stop/dispose 会走 [release]）：播放器已销毁，
  /// 迟到的 play/pause 不能再落到 mpv 上（会抛 assertion）。
  bool _released = false;
  int? _errorCode;
  String? _errorMessage;
  Completer<Duration?>? _loadCompleter;

  /// 装载批次号（SelfMusic 补丁）：每次 [load] 自增。just_audio 不会中断
  /// 并发的 `setUrl`，旧批次的 `open` 只能排队等待，因此旧批次的迟到回调
  /// 绝不能再改写 [_mediaOpened]/[_loadCompleter]/[_processingState] 等共享
  /// 状态——否则旧曲的 buffering 事件会把新曲的装载提前判成功，App 认为
  /// 切歌完成而 mpv 还在放旧曲（「UI 切歌、声音不切」）。
  int _loadGeneration = 0;

  /// The index that's currently playing
  int _currentIndex = 0;

  /// 暴露内部 media_kit Player（SelfMusic 补丁）：桌面均衡器通过
  /// `setProperty/command` 设置 mpv `af` 链。
  Player get player => _player;

  /// [LoadRequest.initialPosition] or [seek] request before [Player.play] was called and/or finished loading.
  Duration? _setPosition;

  Media? get _currentMedia {
    var medias = _player.state.playlist.medias;
    if (medias.isEmpty) return null;
    return medias[_player.state.playlist.index];
  }

  MediaKitPlayer(super.id) {
    _player = Player(
        configuration: PlayerConfiguration(
      pitch: JustAudioMediaKit.pitch,
      protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
      title: JustAudioMediaKit.title,
      bufferSize: JustAudioMediaKit.bufferSize,
      logLevel: JustAudioMediaKit.mpvLogLevel,
      ready: () => _readyCompleter.complete(),
    ));

    if (JustAudioMediaKit.prefetchPlaylist) {
      setProperty(_player, 'prefetch-playlist', 'yes');
    }

    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        if (_currentMedia?.extras?['overrideDuration'] != null) return;

        if (_setPosition != null && duration.inSeconds > 0) {
          unawaited(_player.seek(_setPosition!));
          _setPosition = null;
        }
        _updateDuration(duration);
        _updatePlaybackEvent();
      }),
      _player.stream.position.listen((position) {
        _position = position;
        final start = _currentMedia?.start;
        if (start != null) _position -= start;
        if (_position < Duration.zero) _position = Duration.zero;
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        final start = _currentMedia?.start;
        if (!isBuffering && start != null && _bufferedPosition <= start) {
          // Not ready yet, will be triggered by _player.stream.buffer
          return;
        }
        if (_processingState == ProcessingStateMessage.loading) {
          if (!isBuffering && _mediaOpened) {
            _processingState = ProcessingStateMessage.ready;
            if (_loadCompleter?.isCompleted != true) {
              _loadCompleter?.complete(_duration);
            }
          }
        } else if (_processingState != ProcessingStateMessage.completed ||
            isBuffering) {
          _processingState = isBuffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
          if (_duration == null) {
            _updateDuration(_player.state.duration);
          }
        }
        _errorCode = null;
        _errorMessage = null;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        _bufferedPosition = buffer;
        // Detect ready for clipping audio source
        final start = _currentMedia?.start;
        if (!_player.state.buffering &&
            _mediaOpened &&
            start != null &&
            _bufferedPosition > start) {
          _processingState = ProcessingStateMessage.ready;
          if (_loadCompleter?.isCompleted != true) {
            _loadCompleter?.complete(_duration);
          }
        }
        _updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        _bufferedPosition = _position = Duration.zero;
        if (completed &&
            // is at the end of the [Playlist]
            _currentIndex == _player.state.playlist.medias.length - 1 &&
            // is not looping (technically this shouldn't be fired if the player is looping)
            _player.state.playlistMode == PlaylistMode.none) {
          _processingState = ProcessingStateMessage.completed;
        }
        _errorCode = null;
        _errorMessage = null;

        _updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        final errorUri = RegExp(r'Failed to open (.*)\.').firstMatch(error)?[1];
        if (errorUri == null || errorUri == _currentMedia?.uri) {
          _processingState = ProcessingStateMessage.idle;
          _errorCode = kErrorCode;
          _errorMessage = error;
          // 装载期间出错：叫醒等待中的 load，让错误尽快经 playbackEvent
          // 冒到上层（否则只能等上层的装载看门狗超时）。
          final loading = _loadCompleter;
          if (loading != null && !loading.isCompleted) loading.complete(null);
          _updatePlaybackEvent();
        }
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        if (_currentIndex != playlist.index) {
          _bufferedPosition = _position = Duration.zero;
          _currentIndex = playlist.index;
        }
        _duration = _currentMedia?.extras?['overrideDuration'];
        _updatePlaybackEvent();
      }),
      _player.stream.playlistMode.listen((playlistMode) {
        _dataController.add(
            PlayerDataMessage(loopMode: _playlistModeToLoopMode(playlistMode)));
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        // ignore: avoid_print
        print("MPV: [${event.level}] ${event.prefix}: ${event.text}");
      }),
    ];
  }

  void _updateDuration(Duration duration) {
    final start = _currentMedia?.start;
    final end = _currentMedia?.end;
    if (end != null) duration = end;
    if (start != null) duration -= start;
    _duration = duration;
  }

  PlaylistMode _loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  LoopModeMessage _playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.all,
    };
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  /// Updates the playback event
  void _updatePlaybackEvent() {
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _bufferedPosition,
      duration: _duration,
      icyMetadata: null,
      currentIndex: _currentIndex,
      androidAudioSessionId: null,
      errorCode: _errorCode,
      errorMessage: _errorMessage,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');
    final generation = ++_loadGeneration;
    // 上一批装载若还在等自己的 completer，先放它回去（它的结果已由
    // just_audio/调用方的切歌令牌作废）；否则会留下一个永不完成的 Future。
    final previous = _loadCompleter;
    if (previous != null && !previous.isCompleted) previous.complete(null);
    final completer = _loadCompleter = Completer<Duration?>();
    _mediaOpened = false;
    _currentIndex = request.initialIndex ?? 0;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _duration = null;
    _processingState = ProcessingStateMessage.loading;
    _errorCode = null;
    _errorMessage = null;
    _updatePlaybackEvent();

    // 统一以暂停态打开，起播意图在打开完成后按 [_playing] 的最新值补发：
    // open 内部的 `pause=true` 与装载期间到达的 play()/pause() 不会再互踩。
    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final audioSource =
          request.audioSourceMessage as ConcatenatingAudioSourceMessage;
      final playable = Playlist(
          audioSource.children.map(_convertAudioSourceIntoMediaKit).toList(),
          index: _currentIndex);

      if (generation == _loadGeneration) {
        await _player.open(playable, play: false);
      }
    } else {
      final playable =
          _convertAudioSourceIntoMediaKit(request.audioSourceMessage);
      _logger.finest('playable is ${playable.toString()}');
      if (generation == _loadGeneration) {
        await _player.open(playable, play: false);
      }
    }

    // 装载期间已发起更新的批次：本次结果作废。不得改状态（尤其
    // [_mediaOpened]），也不得播放——最终落地的是新批次打开的音源。
    if (generation != _loadGeneration) {
      return LoadResponse(duration: null);
    }
    _mediaOpened = true;

    // open 期间可能已经错过 ready/buffering 事件（那一拍 `_mediaOpened`
    // 还是 false，流回调不会完成 completer）。这里按当前状态补判一次，
    // 避免 load 永远停在等待上（上层只会看到 15s 装载超时）。
    if (!completer.isCompleted &&
        _processingState != ProcessingStateMessage.loading) {
      completer.complete(_duration);
    }

    if (request.initialPosition != null) {
      _setPosition = _position = request.initialPosition!;
    }

    // 装载期间到达的 play()/pause() 只更新了意图位（[_playing]），这里按
    // 最新意图补发实际命令；否则「装载中按播放」会被丢掉，mpv 停在 open
    // 内部的 pause=true 上，而 UI 显示播放中。
    //
    // 暂停意图不需要补发：open 内部本来就是 pause=true，下一批 open 也会
    // 重新置暂停；反而 pause() 会关掉 media_kit 的 buffering 状态广播，
    // 让装载永远等不到 ready。
    if (_playing) {
      await _player.play();
    }

    _updatePlaybackEvent();
    final duration = await completer.future;
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _playing = true;
    // 不能用 `_mediaOpened` 门控：装载进行中 `_mediaOpened` 为 false，此时
    // 的播放请求会被静默丢弃，而它恰恰是最需要生效的场景（装载中按播放）。
    // media_kit 允许在 open 之前先设 play/pause（open 安排在之后执行）。
    if (!_released) await _player.play();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    // 不按 `_mediaOpened` 门控：装载排队期间旧音源还在响，暂停必须立刻
    // 落到 mpv；新一次 open 内部本来也会置暂停，不会有副作用。
    if (!_released) await _player.pause();
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) =>
      _player.setPitch(request.pitch).then((_) => SetPitchResponse());

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    await _player.setPlaylistMode(_loopModeToPlaylistMode(request.loopMode));
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    bool shuffling = request.shuffleMode != ShuffleModeMessage.none;
    await _player.setShuffle(shuffling);

    _dataController.add(PlayerDataMessage(
        shuffleMode:
            shuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none));
    return SetShuffleModeResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');
    if (request.index != null) {
      await _player.jump(request.index!);
      if (!_playing) await _player.pause();
    }

    final position = request.position;
    if (position != null) {
      _position = position;

      final start = _currentMedia?.start;
      var nativePosition = position;
      if (start != null) nativePosition += start;
      if (_player.state.duration.inSeconds > 0) {
        await _player.seek(nativePosition);
      } else {
        _setPosition = nativePosition;
      }
    } else {
      _position = Duration.zero;
    }

    // reset position on seek
    _updatePlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    // _logger.fine('concatenatingInsertAll(${request.toMap()})');
    for (final source in request.children) {
      await _player.add(_convertAudioSourceIntoMediaKit(source));

      final length = _player.state.playlist.medias.length;

      if (length == 0 || length == 1) continue;

      if (request.index < (length - 1) && request.index >= 0) {
        await _player.move(length, request.index);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    for (var i = request.startIndex; i < request.endIndex; i++) {
      await _player.remove(request.startIndex);
    }

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) {
    return _player
        .move(
            request.currentIndex,
            // not sure why, but apparently there's an underlying difference between just_audio's move implementation
            // and media_kit, so let's fix it
            request.currentIndex > request.newIndex
                ? request.newIndex
                : request.newIndex + 1)
        .then((_) => ConcatenatingMoveResponse());
  }

  /// Release the resources used by this player.
  Future<void> release() async {
    _logger.info('releasing player resources');
    _released = true;
    _mediaOpened = false;
    await _player.dispose();
    // cancel all stream subscriptions
    for (final StreamSubscription subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback
  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      // removed because it doesn't seem to be actually working.
      // Related media-kit issue: https://github.com/media-kit/media-kit/issues/28
      // case final SilenceAudioSourceMessage silenceSource:
      //   // from https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
      //   return Media(
      //     'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms',
      //     extras: {'overrideDuration': silenceSource.duration},
      //   );

      case final ClippingAudioSourceMessage clippingSource:
        return Media(clippingSource.child.uri,
            start: clippingSource.start, end: clippingSource.end);

      default:
        throw UnsupportedError(
            '${audioSource.runtimeType} is currently not supported');
    }
  }
}
