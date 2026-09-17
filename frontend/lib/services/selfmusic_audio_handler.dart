import 'package:audio_service/audio_service.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';

/// audio_service 通知栏/媒体会话处理器（settings.md §3.6）。
///
/// 与 just_audio_background 不同：这里**不劫持** just_audio 平台实例，而是
/// 在 [PlayerProvider] 上做薄转发：
/// - 通知栏按钮（播放/暂停/上一首/下一首/停止）→ provider 方法；
/// - provider 状态变化时调用 [sync] 回推 mediaItem / playbackState，
///   通知栏与系统媒体控件因此展示当前歌曲与播放态。
class SelfMusicAudioHandler extends BaseAudioHandler {
  PlayerProvider? _player;

  void attach(PlayerProvider player) {
    _player = player;
    sync();
  }

  PlayerProvider? get player => _player;

  /// 从 provider 当前状态同步通知栏 / 媒体会话。
  void sync() {
    final p = _player;
    if (p == null) return;
    final s = p.current;
    if (s != null) {
      final id = _songId(s);
      final cur = mediaItem.valueOrNull;
      if (cur == null || cur.id != id) {
        mediaItem.add(MediaItem(
          id: id,
          album: s.albumName,
          artist: s.artist,
          title: s.title.isEmpty ? '未知曲目' : s.title,
          duration: p.duration,
          artUri: s.coverPath != null ? Uri.file(s.coverPath!) : null,
        ));
      }
    }
    final duration = p.duration;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (p.playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: AudioProcessingState.ready,
      playing: p.playing,
      updatePosition: p.position,
      bufferedPosition: duration ?? p.position,
    ));
  }

  static String _songId(Song s) => '${s.sourceKey}:${s.sourceRef}';

  // ---------- 通知栏 / 系统媒体控件回调 → provider ----------

  @override
  Future<void> play() async => _player?.resumeFromNotifier();

  @override
  Future<void> pause() async => _player?.pauseFromNotifier();

  @override
  Future<void> seek(Duration position) async => _player?.seek(position);

  @override
  Future<void> skipToNext() async => _player?.next();

  @override
  Future<void> skipToPrevious() async => _player?.prev();

  @override
  Future<void> stop() async {
    await _player?.pauseFromNotifier();
    _player?.clearResumeState();
  }
}