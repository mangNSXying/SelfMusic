import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/song.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/player_provider.dart';

/// 鸿蒙 AVSession 媒体播控桥（Dart 侧，2026-09-29 设计）。
///
/// 与 [SelfMusicAudioHandler] 同构的**非劫持**薄转发层（settings.md §3.6）：
/// - 状态变化 → [sync]：读 [PlayerProvider] 全量状态，经 `selfmusic/avsession`
///   通道推给 ArkTS 侧 AvSessionBridge（系统通知栏/锁屏/播控中心随之展示）；
/// - 系统播控卡按钮 → 通道方法名直传 → provider 方法（play/pause/stop/
///   playNext/playPrevious/seek/setLoopMode/toggleFavorite）。
///
/// 接线（main.dart）：`OhosMediaSessionBridge(direct)` → `attach(player)` →
/// provider 状态变化经 `PlayerProvider._syncSystemMedia` 钩子自动回推；
/// 收藏/歌词晚到经 `DirectSourceManager` 的 notifyListeners 补推。
///
/// 枚举 int 约定（与 ArkTS 侧 AvSessionBridge 一致）：
/// - 播放态：2=PLAY，3=PAUSE（AVSession PlaybackState）；
/// - 循环模式：0=sequence，1=loopOne，2=loopList，3=weighted
///   （AVSession LoopMode：SEQUENCE/SINGLE/LIST/SHUFFLE）。
class OhosMediaSessionBridge {
  static const _channel = MethodChannel('selfmusic/avsession');

  /// LRC 字节上限（AVSession 规范 40960，留余量按 40000 截断）。
  static const _lyricMaxBytes = 40000;

  final DirectSourceManager _direct;

  /// 是否渲染系统播控卡（通知栏/锁屏/播控中心）。为 false 时不建 AVSession
  /// （无播控卡），但 AUDIO_PLAYBACK 长时任务照常申请——后台播放的进程保活
  /// 与按钮开关解耦（与 Android 前台服务恒注册同一语义，重启生效）。
  final bool showControls;

  PlayerProvider? _player;

  /// 会话是否已启动（首次播放 start，停止 destroy 后复位）。
  bool _started = false;

  /// 上次推送的曲目 id（切歌判定：变化才推 updateMetadata）。
  String? _lastAssetId;

  OhosMediaSessionBridge(this._direct, {this.showControls = true}) {
    _channel.setMethodCallHandler(_onCommand);
  }

  /// main.dart 的 SelfMusicApp.build 中调用（player 创建后）。
  void attach(PlayerProvider player) {
    _player = player;
    player.attachSystemMediaSync(sync);
    // 收藏变化 / 内嵌歌词补读晚到（notifySongMetaChanged）都经 direct 广播，
    // 低频事件，无条件全量补推一次。
    _direct.addListener(_onDirectChanged);
  }

  void _onDirectChanged() {
    if (_started) {
      sync();
    }
  }

  /// 从 provider 当前状态同步系统播控（挂接自 _syncSystemMedia，全部
  /// 播放/暂停/切歌/seek/模式变化时机自动触发）。
  void sync() {
    final p = _player;
    if (p == null) return;
    final s = p.current;
    if (s == null) {
      _destroy();
      return;
    }
    final item = PlayerProvider.mediaItemOf(s,
        title: p.displayTitle(s), duration: p.duration);
    final metadata = <String, Object?>{
      'assetId': item.id,
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      'duration': p.duration?.inMilliseconds ?? 0,
      'coverPath': s.coverPath ?? '',
      'lyric': _clipLyric(_direct.index.lyricsOf(s.sourceKey, s.sourceRef)),
    };
    if (!_started) {
      _started = true;
      _invoke('start', {...metadata, ..._stateMap(p, s), 'showControls': showControls});
    } else {
      if (item.id != _lastAssetId) {
        _invoke('updateMetadata', metadata);
      }
      _invoke('updateState', _stateMap(p, s));
    }
    _lastAssetId = item.id;
  }

  /// 播放态 int 约定：2=PLAY / 3=PAUSE（sync 的触发时机均为稳定态，
  /// 缓冲/完结等瞬态不单独上报）。
  Map<String, Object?> _stateMap(PlayerProvider p, Song s) => <String, Object?>{
        'state': p.playing ? 2 : 3,
        'position': p.position.inMilliseconds,
        'speed': 1.0,
        'isFavorite': _direct.weight.isFavorite(s),
        'loopMode': _loopModeInt(p.mode),
      };

  static int _loopModeInt(PlayMode m) => switch (m) {
        PlayMode.sequence => 0,
        PlayMode.loopOne => 1,
        PlayMode.loopList => 2,
        PlayMode.weighted => 3,
      };

  static PlayMode _playModeOf(int v) => switch (v) {
        1 => PlayMode.loopOne,
        2 => PlayMode.loopList,
        3 => PlayMode.weighted,
        _ => PlayMode.sequence,
      };

  /// LRC 按 UTF-8 字节截断（不切断多字节序列），null/空返回 null。
  static String? _clipLyric(String? lrc) {
    if (lrc == null || lrc.isEmpty) return null;
    final bytes = utf8.encode(lrc);
    if (bytes.length <= _lyricMaxBytes) return lrc;
    var cut = _lyricMaxBytes;
    while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
      cut--;
    }
    return utf8.decode(bytes.sublist(0, cut), allowMalformed: true);
  }

  /// 系统播控卡按钮 → provider。方法名与 ArkTS 侧转发一致。
  Future<Object?> _onCommand(MethodCall call) async {
    final p = _player;
    if (p == null) return null;
    switch (call.method) {
      case 'play':
        await p.resumeFromNotifier();
        break;
      case 'pause':
        await p.pauseFromNotifier();
        break;
      case 'stop':
        await p.stopFromNotifier();
        // stopFromNotifier 不清当前曲，桥侧显式收卡（销毁会话+停长时任务）。
        _destroy();
        break;
      case 'playNext':
        await p.next();
        break;
      case 'playPrevious':
        await p.prev();
        break;
      case 'seek':
        await p.seek(Duration(milliseconds: (call.arguments as num?)?.toInt() ?? 0));
        break;
      case 'setLoopMode':
        p.setMode(_playModeOf((call.arguments as num?)?.toInt() ?? 0));
        break;
      case 'toggleFavorite':
        final s = p.current;
        if (s != null) {
          await _direct.setFavorite(s, !_direct.weight.isFavorite(s));
        }
        break;
      default:
        break;
    }
    return null;
  }

  /// 收卡：通知 ArkTS 销毁会话并复位本地状态（下次播放重新 start）。
  void _destroy() {
    if (!_started) return;
    _started = false;
    _lastAssetId = null;
    _invoke('destroy', null);
  }

  /// 通道调用统一兜底：桥的任何异常都不允许影响播放器主流程。
  void _invoke(String method, Object? arguments) {
    _channel.invokeMethod(method, arguments).catchError((Object e) {
      debugPrint('[ohos_media_session] $method 失败（忽略）：$e');
    });
  }
}
