import 'dart:io';

import 'package:audio_service/audio_service.dart';

import '../models/song.dart';
import '../providers/player_provider.dart';

/// audio_service 通知栏/媒体会话处理器（settings.md §3.6）。
///
/// 不**劫持** just_audio 平台实例，而是在 [PlayerProvider] 上做薄转发：
/// - 通知栏按钮（播放/暂停/上一首/下一首/播放模式/退出软件）→ provider 方法；
/// - provider 状态变化时调用 [sync] 回推 mediaItem / playbackState，
///   通知栏与系统媒体控件因此展示当前歌曲与播放态。
///
/// 通知栏为自研 5 键（改进.txt UI5）：上一首 / 播放·暂停 / 下一首 / 播放模式 /
/// 退出软件，收起(compact)视图取前三个；图标为品牌色矢量（ic_np_*）。
class SelfMusicAudioHandler extends BaseAudioHandler {
  PlayerProvider? _player;

  void attach(PlayerProvider player) {
    _player = player;
    sync();
  }

  PlayerProvider? get player => _player;

  static const MediaControl _prev = MediaControl(
    androidIcon: 'drawable/ic_np_previous',
    label: '上一首',
    action: MediaAction.skipToPrevious,
  );

  static const MediaControl _play = MediaControl(
    androidIcon: 'drawable/ic_np_play',
    label: '播放',
    action: MediaAction.play,
  );

  static const MediaControl _pause = MediaControl(
    androidIcon: 'drawable/ic_np_pause',
    label: '暂停',
    action: MediaAction.pause,
  );

  static const MediaControl _next = MediaControl(
    androidIcon: 'drawable/ic_np_next',
    label: '下一首',
    action: MediaAction.skipToNext,
  );

  /// 「播放模式」按钮按当前 [PlayMode] 出对应图标/文案（图标与播放页一致）：
  /// 顺序/列表循环/单曲循环/随机。图标随模式变化 → 通知每次重发不同的
  /// CustomAction 图标资源，Android 端据此重建按钮（MediaControl.equals
  /// 比较 icon，setState 检测到变化即 updateNotification 换图标）。
  static MediaControl _modeControl(PlayMode m) => MediaControl(
        androidIcon: switch (m) {
          PlayMode.sequence => 'drawable/ic_np_mode_sequence',
          PlayMode.loopList => 'drawable/ic_np_mode_loop_list',
          PlayMode.loopOne => 'drawable/ic_np_mode_loop_one',
          PlayMode.weighted => 'drawable/ic_np_mode_weighted',
        },
        label: switch (m) {
          PlayMode.sequence => '顺序播放',
          PlayMode.loopList => '列表循环',
          PlayMode.loopOne => '单曲循环',
          PlayMode.weighted => '随机播放',
        },
        action: MediaAction.custom,
        customAction: const CustomMediaAction(name: 'play_mode'),
      );

  static const MediaControl _exit = MediaControl(
    androidIcon: 'drawable/ic_np_exit',
    label: '退出软件',
    action: MediaAction.custom,
    customAction: CustomMediaAction(name: 'exit_app'),
  );

  /// 从 provider 当前状态同步通知栏 / 媒体会话。
  void sync() {
    final p = _player;
    if (p == null) return;
    final s = p.current;
    if (s != null) {
      final id = _songId(s);
      final cur = mediaItem.valueOrNull;
      if (cur == null || cur.id != id) {
        mediaItem.add(PlayerProvider.mediaItemOf(s,
            title: p.displayTitle(s), duration: p.duration));
      }
    }
    final duration = p.duration;
    playbackState.add(PlaybackState(
      controls: [
        _prev,
        if (p.playing) _pause else _play,
        _next,
        _modeControl(p.mode),
        _exit,
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

  /// 通知栏「停止」（已不再出现在 5 键通知栏，保留供系统指令调用时的兜底）：
  /// 真正停止播放并把系统状态置 idle（收起通知/前台服务）。
  @override
  Future<void> stop() async {
    await _player?.stopFromNotifier();
    await super.stop();
  }

  /// 自研 5 键中的自定义按钮。
  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'play_mode':
        // 播放模式：与播放页模式按钮一致的循环切换。
        _player?.cycleMode();
        break;
      case 'exit_app':
        // 退出软件：落盘断点/队列后结束进程（与「退出软件」（侧栏/睡眠定时）同语义）。
        await _player?.shutdown();
        await super.stop();
        exit(0);
    }
  }

  /// 手动杀后台（最近任务划掉）：停止播放，但保留断点/队列（下次启动续播）。
  @override
  Future<void> onTaskRemoved() async {
    await _player?.stopFromNotifier(clearResume: false);
    await super.stop();
  }
}