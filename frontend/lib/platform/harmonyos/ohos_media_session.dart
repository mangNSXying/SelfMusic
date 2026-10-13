import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/song.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/player_provider.dart';
import '../../utils/cover_thumb.dart';

/// 鸿蒙 AVSession 媒体播控桥（Dart 侧，2026-09-29 设计）。
///
/// 与 [SelfMusicAudioHandler] 同构的**非劫持**薄转发层（settings.md §3.6）：
/// - 状态变化 → [sync]：读 [PlayerProvider] 全量状态，经 `selfmusic/avsession`
///   通道推给 ArkTS 侧 AvSessionBridge（系统通知栏/锁屏/播控中心随之展示）；
/// - 系统播控卡按钮 → 通道方法名直传 → provider 方法（play/pause/stop/
///   playNext/playPrevious/seek/setLoopMode/toggleFavorite）。
///
/// 快速连切防抖（2026-10-08，ANR 根因修复）：合并平台/UI 线程架构下，每次
/// updateMetadata 都会在主线程触发封面解码 + PixelMap IPC + av_session 服务
/// 推送；实测快速连切（30 次/45s）会打爆 av_session 服务（syncExecutor 超时）
/// 与 JPEG 硬解池，最终主线程 FUTEX 死锁（AppDfr THREAD_BLOCK 持续触发）。
/// 策略：距上次元数据推送超过 [_churnGuard] 的首次切歌立即推（正常切歌体验
/// 不变）；[_churnGuard] 窗口内的后续切歌判定为连切，全部合并为静默
/// [_churnSettle] 后的一次终态推送（元数据+播放态+封面一并携带）。防抖挂起
/// 期间的同曲状态变化（暂停/收藏等）由终态推送携带，不单独推送，避免向已
/// 拥塞的 av_session 服务追加请求。封面一律走 768px 缩略图（播控卡渲染尺寸
/// 仅数百 px，无需原图解码与 IPC）。
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

  /// 已实际推送到系统播控卡的曲目 id（连切防抖期间滞后于当前曲目）。
  String? _lastPushedAssetId;

  /// 已推送的封面路径（`_metadataMap` 的 coverPath 口径，'' 表示无图）：
  /// 同曲晚到封面（后台补读/播放补读在切歌后才落盘）靠它检出变化并补推
  /// `updateMetadata`，否则通知栏永不刷新封面（问题2）。
  String? _lastPushedCoverPath;

  /// 上次元数据推送时刻（前沿立即推的判定基准）。
  DateTime _lastMetaPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// 连切尾沿推送定时器（每次切歌重置，静默 [_churnSettle] 后触发）。
  Timer? _metaTimer;

  /// 前沿推送守卫：距上次元数据推送小于该窗口的切歌判定为连切。
  static const _churnGuard = Duration(seconds: 5);

  /// 连切静默期：窗口内无新切歌才推终态。
  static const _churnSettle = Duration(seconds: 2);

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
  /// 播放/暂停/切歌/seek/模式变化时机自动触发）。切歌走连切防抖（见类注释）。
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
    if (!_started) {
      _started = true;
      _lastPushedAssetId = item.id;
      _lastPushedCoverPath = _coverKey(s);
      _lastMetaPush = DateTime.now();
      _invoke('start', {..._metadataMap(p, s, item), ..._stateMap(p, s), 'showControls': showControls});
      return;
    }
    if (item.id == _lastPushedAssetId) {
      // 同曲状态变化：封面晚到（补读在切歌后才落盘）需补推元数据清/换图
      //（问题2：否则无图歌曲永不刷新，残留上一首图）。
      // 防抖挂起时由尾沿终态推送携带（它重读当前曲，含最新封面），不单独推送，
      // 避免向已拥塞的 av_session 服务追加请求。
      final coverKey = _coverKey(s);
      if (coverKey != _lastPushedCoverPath) {
        if (_metaTimer == null) {
          _pushMetadata(p, s, item);
        }
        // _metaTimer 非空时不更新 _lastPushedCoverPath：留给尾沿终态推送时
        // 经 _pushMetadata 统一记录，避免终态判定误以为已推送而只推 state。
      } else if (_metaTimer == null) {
        _invoke('updateState', _stateMap(p, s));
      }
      return;
    }
    if (_metaTimer == null &&
        DateTime.now().difference(_lastMetaPush) >= _churnGuard) {
      // 非连切：前沿立即推，正常单次切歌体验与原先一致。
      _pushMetadata(p, s, item);
      return;
    }
    // 连切中：重置尾沿定时器，静默期后一次性推终曲（元数据+封面+播放态）。
    _metaTimer?.cancel();
    _metaTimer = Timer(_churnSettle, () {
      _metaTimer = null;
      final pp = _player;
      final ss = pp?.current;
      if (pp == null || ss == null) return;
      final it = PlayerProvider.mediaItemOf(ss,
          title: pp.displayTitle(ss), duration: pp.duration);
      if (it.id != _lastPushedAssetId || _coverKey(ss) != _lastPushedCoverPath) {
        _pushMetadata(pp, ss, it);
      } else {
        _invoke('updateState', _stateMap(pp, ss));
      }
    });
  }

  /// 推送切歌元数据+播放态（前沿/尾沿/同曲封面晚到共用），并记录推送时刻。
  void _pushMetadata(PlayerProvider p, Song s, MediaItem item) {
    _lastPushedAssetId = item.id;
    _lastPushedCoverPath = _coverKey(s);
    _lastMetaPush = DateTime.now();
    _invoke('updateMetadata', _metadataMap(p, s, item));
    _invoke('updateState', _stateMap(p, s));
  }

  /// 封面去重/变化检出口径（与 [_metadataMap] 的 coverPath 一致）：
  /// 用展示路径（缩略图优先）比较，空表示无图。注意 [mediaItemOf] 的 artUri
  /// 可能因悬空路径校验为 null，而此处按源 coverPath 判定，两者都为空即一致。
  static String _coverKey(Song s) {
    final c = s.coverPath;
    if (c == null || c.isEmpty) return '';
    return coverDisplayPath(c);
  }

  /// 元数据字典（封面走 768px 缩略图：播控卡渲染仅数百 px，原图解码+IPC
  /// 是主线程负担；缩略图缺失时 coverDisplayPath 自动回退原图）。
  Map<String, Object?> _metadataMap(PlayerProvider p, Song s, MediaItem item) =>
      <String, Object?>{
        'assetId': item.id,
        'title': item.title,
        'artist': item.artist ?? '',
        'album': item.album ?? '',
        'duration': p.duration?.inMilliseconds ?? 0,
        'coverPath': s.coverPath == null || s.coverPath!.isEmpty
            ? ''
            : coverDisplayPath(s.coverPath!),
        'lyric': _clipLyric(_direct.index.lyricsOf(s.sourceKey, s.sourceRef)),
      };

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
    _metaTimer?.cancel();
    _metaTimer = null;
    if (!_started) return;
    _started = false;
    _lastPushedAssetId = null;
    _lastPushedCoverPath = null;
    _invoke('destroy', null);
  }

  /// 通道调用统一兜底：桥的任何异常都不允许影响播放器主流程。
  void _invoke(String method, Object? arguments) {
    _channel.invokeMethod(method, arguments).catchError((Object e) {
      debugPrint('[ohos_media_session] $method 失败（忽略）：$e');
    });
  }
}
