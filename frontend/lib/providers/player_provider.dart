import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../data/sources/music_source.dart';
import '../data/sources/direct_audio_source.dart';
import '../data/sources/meta_enrich.dart';
import '../data/sources/webdav_url.dart';
import '../data/local/local_index.dart';
import '../data/local/app_settings.dart';
import '../data/local/song_weight_store.dart';
import '../data/deep_list.dart';
import '../data/local/sync_event_types.dart';
import '../services/selfmusic_audio_handler.dart';
import '../utils/lrc_parser.dart';
import '../utils/play_stats.dart';
import '../utils/song_title_format.dart';
import '../utils/weight_curve.dart';
import '../widgets/app_toast.dart';

/// 播放时长对一次播放的完播/跳过分档（stage2.md §2.3）：
/// - >95% 记一次完播；<30% 记一次跳过；30%~95% 不记；
/// - 时长无效（null 或 0）无法判定（自然结束时由调用方补偿记完播）。
enum WeightJudgement { complete, skip, none }

/// 按播放时长判定完播/跳过（毫秒比值，临界严格按「大于 95% / 小于 30%」）。
@visibleForTesting
WeightJudgement judgeWeightRatio(Duration? duration, Duration position) {
  if (duration == null || duration.inMilliseconds <= 0) {
    return WeightJudgement.none;
  }
  final ratio = position.inMilliseconds / duration.inMilliseconds;
  if (ratio > PlayerProvider.completeRatio) return WeightJudgement.complete;
  if (ratio < PlayerProvider.skipRatio) return WeightJudgement.skip;
  return WeightJudgement.none;
}

/// 按源 key 解析播放源的函数：`server` → 服务器代理源；`webdav:<name>` → 对应直连源。
typedef SourceResolver = MusicSource? Function(String sourceKey);

/// 播放模式（stage2.md §3）。
enum PlayMode { sequence, loopList, loopOne, weighted }

/// 睡眠定时模式（播放页「睡眠」弹窗）。
enum SleepTimerKind { time, duration, count, endOfList }

extension PlayModeParse on PlayMode {
  /// 从存储值（settings.md §3.2 `play_mode_default`）解析；未知值回退 sequence。
  static PlayMode fromStored(String? v) => PlayMode.values.firstWhere(
        (m) => m.name == v,
        orElse: () => PlayMode.sequence,
      );
}

/// 全局播放状态：统一持有 AudioPlayer 与播放队列，供播放页与队列面板共享。
///
/// 阶段 2（stage2.md §2/§3/§7）：
/// - 四种播放模式（顺序/列表循环/单曲循环/加权随机）。
/// - 加权随机：每步从队列全量（排除上一首）按 factor 权重采样，不连续同一首。
/// - 事件采集：播放时长 >95% 记完播、<30% 记跳过、30%~95% 不记 → SongWeightStore 调权。
/// - 断点：节流持久化 play_state，启动恢复为暂停态。
class PlayerProvider extends ChangeNotifier with WidgetsBindingObserver {
  /// 完播阈值：播放时长 >95% 记一次完播（含自然结束时 100%）。
  static const double completeRatio = 0.95;
  /// 跳过阈值：播放时长 <30% 记一次跳过；30%~95% 区间不记。
  static const double skipRatio = 0.3;

  AudioPlayer? _player;
  List<Song> _queue = [];
  int _idx = 0;
  Song? _current;
  MusicSource? _curSource;
  SourceResolver? _resolver;
  LocalIndex? _index;
  SongWeightStore? _weight;
  AppSettings? _appSettings;
  void Function(MusicSource src, Song s)? _onTrackStarted;
  void Function(Song s)? _onSongMetaRefreshed;
  SelfMusicAudioHandler? _audioHandler;

  /// 加权抽样的随机源：种子取构造时刻的时间戳（同其他语言 `Random(seed)` 的
  /// 因子），整实例复用同一条 PRNG 流；构造参数 [rng] 可注入固定种子的实例，
  /// 用于确定性单测复现序列。
  final Random _rng;

  /// 当前播放器构造时套用的音频焦点开关（供 [_applyAudioConfigIfNeeded] 比对）。
  bool _builtAudioFocus = true;
  bool _builtEq = false;

  /// 阶段5：当前队列归属的已同步歌单 uuid（播歌单时由调用方传入，其它队列为 null）。
  /// 断点事件仅在此非空且当前歌曲有身份时进 outbox。
  String? _syncPlaylistUuid;

  /// 当前队列绑定的歌单 uuid（歌单页展示用）：从已同步歌单播全部/点歌时非空，
  /// 其它来源播放（全部歌曲/喜欢/专辑/歌手/播放源）为 null —— 此时歌单页兜底
  /// 展示运行时播放队列。
  String? get syncPlaylistUuid => _syncPlaylistUuid;

  /// 深层列表（隐藏历史栈）：绑定当前锚定列表（anchorKey）时启用；未锚定为 null。
  /// anchorKey 值域：playlist:<uuid>/liked/songs/album:<id>/artist:<name>/source:<key>。
  String? _anchorKey;
  DeepListController? _deepList;

  /// 融合基座：当前锚定列表的歌曲快照。
  /// 融合语义「固定首位接续」：队列 = 深层列表（前 N 位）+ 基座第 N+1 位起（后 M-N 位），
  /// 不按内容去重（重播历史中间的歌可出现两处）。仅锚定时非空。
  List<Song>? _fusedBase;

  /// 「下一首播放」预载槽：占用融合队列中深层历史之后的那一位（见 [_nextUpOffset]）。
  /// 锚定上下文下 [_queue] 是深层+基座的融合投影且总长恒等于基座长度，直接 `_queue.insert`
  /// 会被下次 [_rebuildFusedQueue] 整段重算冲掉，故由本字段承载并参与拼接。
  ///
  /// 语义是「替换」而非「插入」：只有一格，排新的会顶掉原先排的那首，队列长度不变
  /// （原 [_nextUpOffset] 位上的基座歌曲被挤掉，基座整体左移一位）。播完即出队；
  /// 未播放任何内容时不用（退化为「立即播放」）。
  Song? _nextUp;

  /// 锚定键构造（调用方传入上下文用）。
  static String anchorForPlaylist(String uuid) => 'playlist:$uuid';
  static String anchorForLiked() => 'liked';
  static String anchorForSongs() => 'songs';
  static String anchorForAlbum(int id) => 'album:$id';
  static String anchorForArtist(String name) => 'artist:$name';
  static String anchorForSource(String key) => 'source:$key';

  /// 融合队列：队列 = 深层列表（前 N 位）+ [_nextUp]（可选，占第 N 位）+ 歌单第 N+1 位起（后 M-N-1 位）。
  /// [_nextUp] 为空时与旧的「深层 ‖ 基座」完全等价，总长=歌单长 M；
  /// 非空时「替换」掉基座第 N+1 首，总长仍是 M（预载语义：换人、不加位）。
  List<Song> _fusedQueue(List<Song> base) {
    final dl = _deepList;
    if (_fusedBase == null || dl == null) return List.of(base);
    return fusedQueueOf(dl.entries, base, nextUp: _nextUp);
  }

  /// [_nextUp] 在融合队列中占的位：深层历史长度（即当前曲之后第一位）。
  /// 深层为空（锚定后尚未播任何曲）时退化为队首。
  int get _nextUpOffset => _deepList?.length ?? 0;

  /// 融合队列纯组装（供测试）：不按内容去重；深层过长时余部为空。
  /// [nextUp] 为「下一首播放」预载项，**替换**掉基座第 N+1 首（总长守恒 = base.length）；
  /// 为 null 时退化为「深层 ‖ 基座」。
  @visibleForTesting
  static List<Song> fusedQueueOf(List<Song> deep, List<Song> base,
      {Song? nextUp}) {
    final n = deep.length;
    final at = n.clamp(0, deep.length);
    if (nextUp == null) {
      if (n == 0) return List.of(base);
      final rest = base.length > n ? base.sublist(n) : const <Song>[];
      return [...deep, ...rest];
    }
    // 预载换人：基座从 n+1 接续（被顶掉的是原第 n+1 首），总长 = deep + 1 + (base-n-1) = base。
    final rest = base.length > n + 1 ? base.sublist(n + 1) : const <Song>[];
    return [...deep.sublist(0, at), nextUp, ...deep.sublist(at), ...rest];
  }

  /// 歌单行 [start] 在融合队列中的位置：深层头部被播放历史占据，
  /// 尾区位置即自身；历史中已有同曲则取同曲（可两处）；否则退回历史末尾。
  int _fusedIndexOf(int start, List<Song> base) {
    final dl = _deepList;
    final n = dl?.length ?? 0;
    if (_fusedBase == null || n == 0) return start.clamp(0, _queue.length - 1);
    if (start >= n) return start.clamp(0, _queue.length - 1);
    final i = _queue.indexWhere((s) => _same(s, base[start]));
    return i >= 0 ? i : (n - 1).clamp(0, _queue.length - 1);
  }

  /// 歌单行 [start] 在融合队列中的位置（纯函数，供测试）。
  @visibleForTesting
  static int fusedIndexFor(int start, int deepLen, List<Song> fused,
      List<Song> base, bool Function(Song a, Song b) same) {
    if (deepLen == 0) return start.clamp(0, fused.length - 1);
    if (start >= deepLen) return start.clamp(0, fused.length - 1);
    final i = fused.indexWhere((s) => same(s, base[start]));
    return i >= 0 ? i : (deepLen - 1).clamp(0, fused.length - 1);
  }

  /// 阶段5：服务器可达性门控（main 经 [attachServerAvailable] 注入）。
  bool Function()? _serverAvailable;

  /// 断点事件节流：同歌 25s 内不重复入队（切歌立即入队）。
  String? _lastBpKey;
  int _lastBpAtMs = 0;

  /// 播放时懒补全元数据：正在补全的歌（sourceKey|sourceRef）去重集合。
  final Set<String> _enriching = {};

  /// 切歌令牌（P0 连按 guard）：每次 [_play] 递增，过期者静默丢弃。
  int _playToken = 0;

  /// 关联 audio_service 通知栏处理器（settings.md §3.6）：状态变化时回推媒体信息。
  void attachAudioHandler(SelfMusicAudioHandler handler) {
    _audioHandler = handler;
    handler.attach(this);
  }

  /// 与 [main] 中可选的 audio_service 处理器接线（未启用通知栏控制时为空）。
  void attachAudioHandlerIfAny(SelfMusicAudioHandler? handler) {
    if (handler != null) attachAudioHandler(handler);
  }

  /// 鸿蒙 AVSession 桥的回推挂钩（ohos_media_session.dart）：状态变化时与
  /// audio_handler 一起被 [_syncSystemMedia] 调用（非鸿蒙/开关关闭时为空）。
  void Function()? _systemMediaSync;

  void attachSystemMediaSync(void Function()? sync) {
    _systemMediaSync = sync;
  }

  void _syncSystemMedia() {
    _audioHandler?.sync();
    _systemMediaSync?.call();
  }

  PlayMode _mode = PlayMode.sequence;
  DateTime? _lastStateSave;
  bool _restored = false;

  Timer? _fadeTimer;
  bool _fadingPause = false;
  AndroidEqualizer? _eq;

  // ---------- 睡眠定时（播放页「睡眠」） ----------

  Timer? _sleepTick;
  SleepTimerKind? _sleepKind;
  DateTime? _sleepUntil;          // 指定时间：目标时刻（可含次日）
  DateTime? _sleepDeadline;       // 指定时长：倒计时截止时刻
  int _sleepCountLeft = 0;        // 指定曲数：剩余曲目数
  bool _sleepPlayThrough = false; // 播放完最后的曲目（到点不中断当前曲）
  bool _sleepPendingStop = false; // play-through 已触发，等当前曲放完暂停
  bool _sleepExitApp = false;     // 到时退出软件（落盘断点后结束进程，不驻留后台）

  bool get sleepTimerActive => _sleepKind != null;

  SleepTimerKind? get sleepMode => _sleepKind;

  /// 指定时间模式下目标时刻（null 表示未设置）。
  DateTime? get sleepUntilTime => _sleepUntil;

  /// 指定曲数模式下剩余曲数。
  int get sleepCountLeft => _sleepCountLeft;

  /// 是否「播放完最后的曲目」。
  bool get sleepPlayThrough => _sleepPlayThrough;

  /// 是否「播放结束退出软件」。
  bool get sleepExitApp => _sleepExitApp;

  /// 倒计时剩余分钟（指定时长模式，随秒跳变取整）。
  int get sleepMinutes {
    if (_sleepKind == SleepTimerKind.duration && _sleepDeadline != null) {
      final rem = _sleepDeadline!
          .difference(DateTime.now())
          .inMilliseconds;
      return rem <= 0 ? 0 : (rem / 60000).ceil();
    }
    return 0;
  }

  /// 当前定时的可读摘要（用于按钮 tooltip / 弹窗标识）。
  String? get sleepSummaryText {
    final exitAppSuffix = _sleepExitApp ? '，到时退出软件' : '';
    return switch (_sleepKind) {
      SleepTimerKind.time => _sleepUntil == null
          ? null
          : '到 ${_fmtTime(_sleepUntil!)} 停止'
              '${_sleepPlayThrough ? '（播完当前曲）' : ''}$exitAppSuffix',
      SleepTimerKind.duration => '$sleepMinutes 分钟后停止'
          '${_sleepPlayThrough ? '（播完当前曲）' : ''}$exitAppSuffix',
      SleepTimerKind.count => '播放 $_sleepCountLeft 首后停止'
          '${_sleepPlayThrough ? '（播完当前曲）' : ''}$exitAppSuffix',
      SleepTimerKind.endOfList => '列表结尾停止$exitAppSuffix',
      null => null,
    };
  }

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 指定时间：到 [target] 时刻停止（早于当前时间视为次日）。
  void setSleepTime(DateTime target,
      {bool playThrough = false, bool exitApp = false}) {
    var when = target;
    if (!when.isAfter(DateTime.now())) when = when.add(const Duration(days: 1));
    _setSleepStart();
    _sleepKind = SleepTimerKind.time;
    _sleepUntil = when;
    _sleepPlayThrough = playThrough;
    _sleepExitApp = exitApp;
    _startSleepTick();
    notifyListeners();
  }

  /// 指定时长：倒计时 [duration] 后停止。
  void setSleepDuration(Duration duration,
      {bool playThrough = false, bool exitApp = false}) {
    if (duration.inSeconds <= 0) {
      cancelSleepTimer();
      return;
    }
    _setSleepStart();
    _sleepKind = SleepTimerKind.duration;
    _sleepDeadline = DateTime.now().add(duration);
    _sleepPlayThrough = playThrough;
    _sleepExitApp = exitApp;
    _startSleepTick();
    notifyListeners();
  }

  /// 指定曲数：再播放 [count] 首后停止。
  void setSleepCount(int count,
      {bool playThrough = false, bool exitApp = false}) {
    _setSleepStart();
    _sleepKind = SleepTimerKind.count;
    _sleepCountLeft = count > 0 ? count : 0;
    _sleepPlayThrough = playThrough;
    _sleepExitApp = exitApp;
    notifyListeners();
  }

  /// 列表结尾：播完队列最后一首即停止（天然播完）。
  void setSleepEndOfList({bool exitApp = false}) {
    _setSleepStart();
    _sleepKind = SleepTimerKind.endOfList;
    _sleepPlayThrough = true;
    _sleepExitApp = exitApp;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _clearSleep();
    notifyListeners();
  }

  void _setSleepStart() {
    _sleepTick?.cancel();
    _sleepPendingStop = false;
    _sleepUntil = null;
    _sleepDeadline = null;
    _sleepCountLeft = 0;
    _sleepExitApp = false;
  }

  void _clearSleep() {
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepKind = null;
    _sleepUntil = null;
    _sleepDeadline = null;
    _sleepCountLeft = 0;
    _sleepPlayThrough = false;
    _sleepPendingStop = false;
    _sleepExitApp = false;
  }

  /// 时间/时长模式：每秒检查到期；时长模式剩余分钟变化时刷新 UI。
  void _startSleepTick() {
    _sleepTick?.cancel();
    var shown = sleepMinutes;
    _sleepTick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_sleepPendingStop) {
        t.cancel();
        return;
      }
      final kind = _sleepKind;
      if (kind == SleepTimerKind.time) {
        final until = _sleepUntil;
        if (until != null && !DateTime.now().isBefore(until)) {
          t.cancel();
          unawaited(_stopForSleep(atBoundary: false));
        }
      } else if (kind == SleepTimerKind.duration) {
        final dl = _sleepDeadline;
        if (dl != null && !DateTime.now().isBefore(dl)) {
          t.cancel();
          unawaited(_stopForSleep(atBoundary: false));
        } else {
          final m = sleepMinutes;
          if (m != shown) {
            shown = m;
            notifyListeners();
          }
        }
      }
    });
  }

  /// 到期执行：play-through 时等当前曲放完；否则立即停止（按开关退出/暂停）。
  Future<void> _stopForSleep({required bool atBoundary}) async {
    if (player.playing && _sleepPlayThrough && !atBoundary && !_sleepPendingStop) {
      _sleepPendingStop = true;
      _sleepTick?.cancel();
      notifyListeners();
      return;
    }
    _sleepStop();
  }

  /// 睡眠定时最终收口：先读退出开关再清定时（清空会复位该位），
  /// 「播放结束退出软件」为开则退出进程，否则暂停。
  void _sleepStop() {
    final exitApp = _sleepExitApp;
    _clearSleep();
    unawaited(exitApp ? _quitAfterSleep() : _pauseNowForSleep());
  }

  /// 「播放结束退出软件」：先走正常停机（落库断点/停播放器），再退进程。
  Future<void> _quitAfterSleep() async {
    await shutdown();
    exit(0);
  }

  Future<void> _pauseNowForSleep() async {
    if (player.playing) await _fadeOutThenPause();
    notifyListeners();
    _syncSystemMedia();
  }

  /// 曲目自然播放结束时被调用：返回 true 表示由睡眠定时接管（不再自动切歌）。
  bool _handleTrackCompletedSleep() {
    if (_sleepPendingStop) {
      _sleepStop();
      return true;
    }
    final kind = _sleepKind;
    if (kind == SleepTimerKind.count) {
      if (_sleepCountLeft > 0) _sleepCountLeft--;
      if (_sleepCountLeft <= 0) {
        _sleepStop();
        return true;
      }
      notifyListeners();
      return false;
    }
    if (kind == SleepTimerKind.endOfList &&
        _idx == _queue.length - 1 &&
        _current != null) {
      _sleepStop();
      return true;
    }
    return false;
  }

  /// 播放器延迟到首次使用才构造（见 [player]），故构造器不建实例。
  PlayerProvider({Random? rng})
      : _rng = rng ?? Random(DateTime.now().microsecondsSinceEpoch) {
    if (!kIsWeb) WidgetsBinding.instance.addObserver(this);
  }

  /// 按用户设置构造播放器：均衡器（Android 原生 AndroidEqualizer）与音频焦点开关
  /// 均需在构造时注入（settings.md §3.2/§3.6），设置变动时经 [applyAudioConfig] 重建。
  AudioPlayer _buildPlayer() {
    final s = _appSettings;
    final eqEnabled = !kIsWeb && Platform.isAndroid && (s?.equalizerEnabled ?? false);
    _eq = eqEnabled ? AndroidEqualizer() : null;
    // 记录本次构造实际套用的配置：供 [_applyAudioConfigIfNeeded] 判断是否过期。
    _builtAudioFocus = s?.audioFocusEnabled ?? true;
    _builtEq = eqEnabled;
    return AudioPlayer(
      handleInterruptions: _builtAudioFocus,
      audioPipeline: _eq != null
          ? AudioPipeline(androidAudioEffects: [_eq!])
          : null,
    );
  }

  /// 播放器已存在、但构造时读到的音频配置与当前设置不一致时重建。
  /// 正常路径下 [player] 延迟构造已保证一致，这里兜住「设置晚于首次使用注入」
  /// 与热重排等边界；无当前曲目时只换实例，不打断播放。
  void _applyAudioConfigIfNeeded() {
    if (_player == null || _shuttingDown) return;
    final s = _appSettings;
    if (s == null) return;
    final focus = s.audioFocusEnabled;
    final eq = !kIsWeb && Platform.isAndroid && s.equalizerEnabled;
    if (focus == _builtAudioFocus && eq == _builtEq) return;
    if (_current == null) {
      _fadeTimer?.cancel();
      final old = _player;
      _player = null;
      unawaited(old?.dispose());
      _buildAndWire();
      notifyListeners();
      return;
    }
    unawaited(applyAudioConfig());
  }

  void _setupPlayerStreams(AudioPlayer p) {
    p.playerStateStream.listen((st) {
      // 暂停/停止：结清当前挂钟窗口（positionStream 停止跳动，不再有 tick）。
      if (!st.playing) _playSecStop();
      if (st.processingState != ProcessingState.completed) return;
      // 到点暂停会把 playing 置 false 并再发一次 completed：
      // 这种「已暂停」的完成事件不再处理，否则暂停后又被自动切歌。
      if (!st.playing) return;
      final finished = _current;
      if (finished == null) return;
      // 同一首歌的 completed 事件兜底去重。
      final key = '${finished.sourceKey}\u0000${finished.sourceRef}';
      if (_completedKey == key) return;
      _completedKey = key;
      _emitWeight(finished, completed: true,
          position: player.duration ?? Duration.zero);
      if (_handleTrackCompletedSleep()) return;
      _advance(autoAdvanceOnFailure: true);
    });
    // 播放时长采集挂在这里：位置流在播放中持续跳动，暂停/停止时停止。
    p.positionStream.listen((pos) {
      _maybeSaveState(pos);
      _playSecReconcile(playing: p.playing);
    });
    // just_audio 0.9.x 没有 errorStream：平台侧错误只从 playbackEventStream 的
    // onError 冒出来（playerStateStream 内部 handleError 吞掉，见包的
    // `_processingStateSubject.addStream(...handleError(noop))`）。此前无人监听，
    // ExoPlayer 任何源错误都表现为「playing 仍为 true、界面显示播放中、却没声音」。
    p.playbackEventStream.listen((_) {}, onError: _onPlaybackError);
  }

  /// 播放错误（ExoPlayer 源错误/网络中断）统一入口：诊断日志 + 重新装载当前曲。
  /// 这类错误发生在装载成功之后，不会抛回 [_playDirect] 的调用点。
  void _onPlaybackError(dynamic e) {
    debugPrint('[play] 播放错误: $e');
    if (_shuttingDown) return;
    final cur = _current;
    if (cur == null) return;
    final now = DateTime.now();
    final last = _lastRecoverAt;
    if (last != null && now.difference(last) < _recoverCooldown) return;
    _lastRecoverAt = now;
    _loadFailStreak = 0;
    unawaited(_recoverPlayback(cur));
  }

  /// 重新装载当前曲（外部点歌语义，不重复推深层历史）；
  /// 仍装载失败则由 [_autoSkipAfterFailure] 继续跳下一首。
  Future<void> _recoverPlayback(Song s) async {
    final src = _curSource;
    if (src == null || _shuttingDown) return;
    await _play(s,
        source: src, fromPlaylist: false, autoAdvanceOnFailure: true);
  }

  /// 已处理过 completed 的曲目 key（含暂停导致的二次 completed，见监听器注释）。
  String? _completedKey;

  /// 当前曲是否用户手动点播（playAt/playQueue；next/prev/自动/失败重试=非手动）。
  /// 自然完播（>95%）时在此基础上额外累计 `complete_manual` 权重 +0.1 一档。
  bool _startedManual = false;

  // ---------- 装载失败与播放错误（改进.txt：后台有概率停止播放） ----------

  /// 装载退避重试间隔：后台网络被回收/连接超时后重建连接再试一次。
  /// 非常量：测试可临时置零以免真的等待。
  @visibleForTesting
  static List<Duration> loadBackoff = const [
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  /// 连续装载失败到该首数才停止：个别坏歌不卡住整条队列，
  /// 整队都不可播时也不会无限跳歌。
  static const int _loadFailSkipLimit = 3;

  /// 装载看门狗：原生装载器（ohos fvp/mdk、桌面 mpv）对「主机不可达/
  /// 无响应」的 open 没有应用层超时——真机实测 IPv6 路由丢失时 mdk
  /// prepare 永久挂起，UI 卡 00:00/00:00、点播放无响应（2026-09-30）。
  /// 超时后交 [loadBackoff] 退避重试，重试耗尽走既有装载失败提示/跳曲。
  /// ExoPlayer 自带连接超时通常先于此报错（对 Android 无感）。
  static const Duration _loadUrlTimeout = Duration(seconds: 15);

  /// 预热探针看门狗：[MusicSource.probe] 的 HttpClient 只有 15s 连接超时，
  /// 不覆盖「连上但无响应」；探针失败本就不阻塞装载，超时同按失败忽略。
  static const Duration _probeTimeout = Duration(seconds: 10);

  /// 播放错误自动恢复的最小间隔，抑制错误风暴反复重装同一首。
  static const Duration _recoverCooldown = Duration(seconds: 5);

  /// 连续装载失败计数（成功装载即清零）。
  int _loadFailStreak = 0;

  /// 上次播放错误自动恢复的时间。
  DateTime? _lastRecoverAt;

  /// 退出中：不再重试/恢复（避免与 dispose 竞争）。
  bool _shuttingDown = false;

  /// 装载动作（测试注入；生产恒走 [_loadOnce]）。
  @visibleForTesting
  Future<void> Function(Song s, MusicSource src)? loadOverride;

  /// 测试入口：只跑装载重试（不碰队列/UI）。
  @visibleForTesting
  Future<void> debugLoadDirect(Song s, MusicSource src,
          {required bool Function() alive}) =>
      _playDirect(s, src, alive: alive);

  // ---------- 任务被划掉（Android 通知栏路径） ----------

  /// 已 dispose：生命周期回调可能晚于释放，迟到的通知栏/生命周期事件要挡住。
  bool _disposed = false;

  /// 任务被划掉（Android 通知栏路径）：停止播放但**保留断点/队列**。
  ///
  /// 之前这里走 `stopFromNotifier()`（会清断点），导致划掉/退出后再进入是空队列
  /// 重新从头播放（改进.txt 修复项）。划掉任务只是结束可见 Activity，用户没说要
  /// 丢掉进度——下次启动由断点恢复接回队列（受 resumeOnStartup 开关控制）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.detached || _disposed || _shuttingDown) {
      return;
    }
    if (kIsWeb || !Platform.isAndroid) return;
    // 仅通知栏路径生效：与迁移前 onTaskRemoved 的触发条件一致（关掉通知栏控制时
    // 不拦截，播放继续）。
    if (!(_appSettings?.notificationControls ?? false)) return;
    debugPrint('[play] 任务被划掉，停止播放（保留断点）');
    unawaited(stopFromNotifier(clearResume: false));
  }

  // ---------- 下一首预热（后台切歌不再冷启动） ----------

  /// 预热成功后的免重复窗口：同一首在 TTL 内不重复握手。
  static const Duration _warmTtl = Duration(minutes: 10);

  /// 预热失败后的重试间隔：后台网络恢复要时间，摊在本曲播放期间慢慢试，
  /// 别等到切歌那一刻才两手空空。非常量：测试可临时置零。
  @visibleForTesting
  static Duration warmRetryDelay = const Duration(seconds: 20);

  /// 预热最多尝试次数（含首次）。用尽即放弃，交给装载重试兜底。
  static const int _warmMaxAttempts = 3;

  /// 单次预热超时：预热是「提前打招呼」，不能拖慢任何东西。
  static const Duration _warmTimeout = Duration(seconds: 15);

  /// 已预热成功的曲目（key → 时间）。
  final Map<String, DateTime> _warmed = {};

  /// 预热退避重试的定时器（切歌/退出时取消）。
  Timer? _warmTimer;

  /// 正在预热的曲目（并发去重）。
  String? _warmingKey;

  /// 预热动作（测试注入；生产恒走 [MusicSource.probe]）。
  @visibleForTesting
  Future<void> Function(Song s, MusicSource src)? probeOverride;

  /// 测试入口：只跑预热（不碰播放器/队列）。
  @visibleForTesting
  Future<void> debugWarmNext(Song s, MusicSource src) =>
      _warmTarget(s, src, attempt: 1);

  /// 测试入口：按当前模式算出的「下一首」（不预热）。
  @visibleForTesting
  Song? debugPeekWarmTarget() => _peekWarmTarget();

  /// 按当前播放模式算出「下一首会是谁」（不消耗 [_peekedNext]）。
  Song? _peekWarmTarget() {
    if (_queue.isEmpty || _current == null) return null;
    // 单曲循环：下一首还是它自己，播放器里已有缓冲，没有可预热的连接。
    if (_mode == PlayMode.loopOne) return null;
    // 其余模式复用 [peekNext]：加权随机在这里定下预采样结果，切歌时播的正是
    // 这一首（口径必须一致，不能另采一次样导致预热落空）。
    return peekNext();
  }

  /// 切歌成功后预热下一首：把取流请求从「切歌那一刻」提前到「本曲播放期间」。
  ///
  /// 修的是后台停播的另一半原因：ee15375 让失败不再静默（重试 + 跳歌 + 报错），
  /// 但切歌仍要等一次冷启动请求，而后台这条请求容易被 Doze / 应用待机拖到超时。
  /// 提前预热既缩短了关键路径，也给失败留出退避重试的窗口。
  void _scheduleWarmup() {
    _warmTimer?.cancel();
    _warmTimer = null;
    _warmingKey = null;
    if (_shuttingDown) return;
    final next = _peekWarmTarget();
    if (next == null) return;
    final src = _resolver?.call(next.sourceKey);
    if (src == null || !src.supportsDirect) return;
    unawaited(_warmTarget(next, src, attempt: 1));
  }

  Future<void> _warmTarget(Song s, MusicSource src,
      {required int attempt}) async {
    final key = _songKey(s);
    if (_warmingKey == key) return; // 同一首已在预热中
    _warmingKey = key;
    try {
      final done = _warmed[key];
      if (done != null && DateTime.now().difference(done) < _warmTtl) return;
      // 已离线缓存的曲目走本地文件，没有可预热的连接。
      if (await src.cachedFilePath(s) != null) {
        _warmed[key] = DateTime.now();
        return;
      }
      final injected = probeOverride;
      if (injected != null) {
        await injected(s, src).timeout(_warmTimeout);
      } else {
        await src.probe(s).timeout(_warmTimeout);
      }
      _warmed[key] = DateTime.now();
      debugPrint('[play] 已预热下一首《${s.title}》');
    } catch (e) {
      final again = attempt + 1;
      if (_shuttingDown || again > _warmMaxAttempts) {
        debugPrint('[play] 预热下一首失败（放弃，等装载重试兜底）: $e');
        return;
      }
      debugPrint('[play] 预热失败，${warmRetryDelay.inSeconds}s 后再试: $e');
      _warmTimer = Timer(warmRetryDelay, () {
        if (_shuttingDown) return;
        unawaited(_warmTarget(s, src, attempt: again));
      });
    } finally {
      if (_warmingKey == key) _warmingKey = null;
    }
  }

  /// 测试：播放器是否已构造。
  @visibleForTesting
  bool get debugPlayerBuilt => _player != null;

  /// 测试：播放器构造时套用的音频焦点开关（未构造时为 null）。
  @visibleForTesting
  bool? get debugBuiltAudioFocus =>
      _player == null ? null : _builtAudioFocus;

  /// 应用音频相关设置（均衡器/音频焦点/淡入淡出开关变化）：重建播放器并恢复当前曲目。
  Future<void> applyAudioConfig() async {
    // 还没建播放器：不必重建，首次构造会直接读到新设置。
    if (_player == null) return;
    if (_current == null) {
      _fadeTimer?.cancel();
      await _disposePlayer();
      _buildAndWire();
      notifyListeners();
      return;
    }
    final pos = player.position;
    final wasPlaying = player.playing;
    final current = _current!;
    final source = _curSource;
    _fadeTimer?.cancel();
    await _disposePlayer();
    _buildAndWire();
    await _play(current, source: source, play: wasPlaying);
    try {
      await player.seek(pos);
    } catch (_) {}
    notifyListeners();
  }

  /// 丢弃当前播放器实例（不自动重建；下次访问 [player] 时按最新设置重建）。
  Future<void> _disposePlayer() async {
    final old = _player;
    _player = null;
    try {
      await old?.dispose();
    } catch (_) {}
  }

  // ---------- 淡入淡出（settings.md §3.2） ----------

  bool get _fadeOn => _appSettings?.fadeEnabled ?? false;

  Duration get _fadeDuration => Duration(
      milliseconds: _appSettings?.fadeDurationMs ?? 2000);

  /// 淡入：从 0 渐变到 1（关闭时直接置 1）。
  void _fadeIn() {
    _fadeTimer?.cancel();
    if (!_fadeOn) {
      player.setVolume(1.0);
      return;
    }
    final dur = _fadeDuration.inMilliseconds;
    final start = DateTime.now();
    player.setVolume(0.0);
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 16), (t) async {
      final el = DateTime.now().difference(start).inMilliseconds;
      final p = dur <= 0 ? 1.0 : (el / dur).clamp(0.0, 1.0);
      await player.setVolume(p);
      if (p >= 1.0) t.cancel();
    });
  }

  /// 淡出后真正暂停（关闭淡入淡出时直接暂停）。
  Future<void> _fadeOutThenPause() async {
    if (!_fadeOn) {
      await player.pause();
      return;
    }
    _fadeTimer?.cancel();
    _fadingPause = true;
    final dur = _fadeDuration.inMilliseconds;
    final start = DateTime.now();
    player.setVolume(1.0);
    await Future.delayed(const Duration(milliseconds: 16));
    while (true) {
      final el = DateTime.now().difference(start).inMilliseconds;
      final v = (1.0 - el / dur).clamp(0.0, 1.0);
      await player.setVolume(v);
      if (v <= 0.0) break;
      await Future.delayed(const Duration(milliseconds: 16));
    }
    await player.pause();
    await player.setVolume(1.0);
    _fadingPause = false;
  }

  // ---------- 均衡器（settings.md §3.2，仅 Android） ----------

  /// 应用存储的频段增益（播放器装载完成、效果激活后调用）。
  Future<void> _applyEqualizerBands() async {
    final eq = _eq;
    final s = _appSettings;
    if (eq == null || s == null || !s.equalizerEnabled) return;
    try {
      final params = await eq.parameters;
      final bands = s.eqBands;
      for (var i = 0; i < bands.length && i < params.bands.length; i++) {
        final gain = bands[i]
            .clamp(params.minDecibels.toDouble(), params.maxDecibels.toDouble());
        await params.bands[i].setGain(gain);
      }
      await eq.setEnabled(true);
    } catch (_) {
      // 平台不支持 / 尚未激活时静默跳过。
    }
  }

  /// 单个频段增益写入（UI 拖动即时生效）；同时持久化。
  Future<void> setEqBand(int index, double db) async {
    final s = _appSettings;
    if (s == null) return;
    final bands = s.eqBands;
    bands[index] = db;
    s.eqBands = bands;
    final params = _eq == null ? null : await _eq!.parameters;
    if (params != null && index < params.bands.length) {
      try {
        var gain = db;
        if (gain < params.minDecibels) gain = params.minDecibels;
        if (gain > params.maxDecibels) gain = params.maxDecibels;
        await params.bands[index].setGain(gain);
      } catch (_) {}
    }
  }

  /// 关联源解析器（混合队列时按歌曲 sourceKey 逐首选择播放源）。
  void attachSourceResolver(SourceResolver resolver) {
    _resolver = resolver;
  }

  /// 该歌曲在本机是否有可直连的播放源（断点恢复跳过不可播曲目用）。
  bool _playable(MusicSource? src) => src != null && src.supportsDirect;

  /// 关联本地索引（断点持久化/恢复）与权重存储（事件调权）。
  void attachPersistence({
    required LocalIndex index,
    required SongWeightStore weight,
    void Function(MusicSource src, Song s)? onTrackStarted,
    void Function(Song s)? onSongMetaRefreshed,
  }) {
    _index = index;
    _weight = weight;
    _onTrackStarted = onTrackStarted;
    _onSongMetaRefreshed = onSongMetaRefreshed;
  }

  /// 播放器实例，**首次使用时才构造**。
  ///
  /// 构造 PlayerProvider 时 [attachAppSettings] 还没调用，若此时建播放器，
  /// 音频焦点/均衡器只能读到默认值——「忽略音频焦点」冷启动永远失效，必须进
  /// 设置页手动切一次开关才生效。延迟构造保证第一次建时就拿到真实设置。
  AudioPlayer get player => _player ??= _buildAndWire();

  AudioPlayer _buildAndWire() {
    final p = _buildPlayer();
    _setupPlayerStreams(p);
    return p;
  }

  // ---------- 播放时长采集（改进.txt：播放时长精确到秒） ----------

  /// 累计播放秒数的批量落库阈值：约每 [_playSecFlushAt] 秒写一次库，
  /// 暂停/切歌/退出时立即结清。
  static const int _playSecFlushAt = 20;

  /// 当前挂钟窗口起点（只在「正在播」时非空）。
  DateTime? _playSecWindow;

  /// 已结算但还没落库的秒数。
  int _playSecPending = 0;

  /// [_playSecPending] 归属的歌曲（切歌时先把上一首结清）。
  Song? _playSecSong;

  /// 采集 tick（positionStream，播放中约 200ms 一次）：对齐「当前曲 + 是否在播」
  /// 与挂钟窗口。
  ///
  /// 挂在已有的 positionStream 上而不是另起定时器：播放中位置流本身就是稳定的
  /// 心跳，且自动续播/错误恢复时 `playing` 一直为 true 不产生新事件，靠 playing
  /// 事件会漏采——这里每次都按 [_current] 重新对账，切歌自动归属到新歌。
  void _playSecReconcile({required bool playing}) {
    final s = _current;
    if (s == null || !playing) {
      _playSecStop();
      return;
    }
    if (_playSecSong == null || !_same(_playSecSong!, s)) {
      _playSecFlush(); // 换歌：先结清上一首
      _playSecSong = s;
    }
    final win = _playSecWindow ??= DateTime.now();
    final r = settlePlaySecWindow(win, DateTime.now());
    if (r.sec > 0) {
      _playSecPending += r.sec;
      _playSecWindow = r.window;
      if (_playSecPending >= _playSecFlushAt) _playSecFlush();
    }
  }

  /// 暂停/停止/退出：结清窗口并立即落库。
  void _playSecStop() {
    final win = _playSecWindow;
    if (win != null) {
      final r = settlePlaySecWindow(win, DateTime.now());
      _playSecPending += r.sec;
      _playSecWindow = null;
    }
    _playSecFlush();
  }

  /// 落库待结算秒数。播放时长是纯本地累计量，不逐次进 outbox；
  /// 跨设备同步走 `song.state` 绝对态（见 SongWeightStore.backfill / 快照回写）。
  void _playSecFlush() {
    final s = _playSecSong;
    final sec = _playSecPending;
    final w = _weight;
    if (s == null || sec <= 0 || w == null) return;
    _playSecPending = 0;
    unawaited(w.addPlaySec(s, sec));
  }

  /// 关联用户设置：套用默认播放模式（settings.md §3.2 `play_mode_default`），
  /// 之后每次切模式写回。顺带校正播放器构造时读到的音频配置（冷启动）。
  void attachAppSettings(AppSettings settings) {
    _appSettings = settings;
    final m = PlayModeParse.fromStored(settings.playModeDefault);
    if (_mode != m) _mode = m;
    _applyAudioConfigIfNeeded();
  }

  /// 关联服务器可达性门控（main 注入 `direct.isServerAvailable`）：
  /// 直连歌曲断点仅在连着服务器时上报，避免未配对用户 outbox 积压。
  void attachServerAvailable(bool Function() fn) {
    _serverAvailable = fn;
  }

  List<Song> get queue => List.unmodifiable(_queue);
  Song? get current => _current;
  bool get hasCurrent => _current != null;
  Duration get position => player.position;
  Duration? get duration => player.duration;
  bool get playing => player.playing;
  PlayMode get mode => _mode;

  /// 是否为当前播放曲（按 sourceKey + sourceRef，避免多源 id 碰撞）。
  bool isCurrent(Song s) {
    final c = _current;
    return c != null && _same(c, s);
  }

  /// 按「歌曲标题显示格式」格式化（通知栏等无 BuildContext 场景）。
  String displayTitle(Song s) => formatSongTitleWith(s, _appSettings);

  /// 当前歌曲权重因子（无存储时为空；用于播放页展示，可选）。
  double? get currentWeightFactor {
    final s = _current;
    final w = _weight;
    if (s == null || w == null) return null;
    return w.factorOf(s);
  }

  void setMode(PlayMode m) {
    if (_mode == m) return;
    _mode = m;
    _peekedNext = null; // 模式变了，旧的预取结果作废
    final s = _appSettings;
    if (s != null && s.playModeDefault != m.name) {
      s.playModeDefault = m.name;
    }
    notifyListeners();
    // 播控卡循环模式按钮需要跟随（鸿蒙 AVSession 经 systemMediaSync 回推）。
    _syncSystemMedia();
  }

  /// 通知栏「播放模式」按钮：与播放页模式按钮一致的循环切换。
  void cycleMode() {
    final m = _mode;
    final next = PlayMode.values[(m.index + 1) % PlayMode.values.length];
    setMode(next);
  }

  // ---------- 队列装载 ----------

  /// 载入一个播放队列并从 [index] 开始播放。
  /// [index]：起始曲下标。歌单「播放」传 [startIndexForPlaylist]（按当前播放
  /// 顺序算法决定），「从头播放」传 0（默认）；点歌传被点行下标。
  /// [playlistUuid]：从已同步歌单播全部/点歌时传入（阶段5 断点归属用），其它队列不传。
  /// [resumeFromBreakpoint]：打开歌单「播放」时开启——若其他设备的断点更新，
  /// 自动定位到该进度并提示（详情页「从头播放」走默认 false）。
  /// [contextKey]：当前点歌所在列表的锚定键（PlayerProvider.anchorForXxx）。
  /// [resetAnchor]：歌单页「播放/从头播放」专用——清空深层历史并切换到该歌单。
  ///
  /// 锚定语义（深层列表功能）：
  /// - 首个列表即锚定；同锚定键点歌推入深层末尾（固定首位接续融合）；
  /// - 其它列表点歌不切 base、不重建队列，仅替换深层末尾（外部点歌）；
  /// - resetAnchor 清空深层 + 重锚到目标歌单。
  Future<void> playQueue(List<Song> songs,
      {int index = 0,
      MusicSource? source,
      String? playlistUuid,
      bool resumeFromBreakpoint = false,
      String? contextKey,
      bool resetAnchor = false}) async {
    if (songs.isEmpty) return;
    final resolved = _resolveLiveAll(songs);
    // 起播一批新歌 = 换上下文：旧的「下一首播放」暂存项不再有意义。
    _nextUp = null;
    final key = contextKey ??
        (playlistUuid != null ? PlayerProvider.anchorForPlaylist(playlistUuid) : null);

    if (resetAnchor) {
      // 「播放/从头播放」：清空深层历史 + 重锚到目标（歌单）。
      _syncPlaylistUuid = playlistUuid;
      _fusedBase = null;
      _bindDeepList(key, listSize: resolved.length, reset: true);
      _fusedBase = resolved;
      _queue = _fusedQueue(resolved);
      final target = resolved[index.clamp(0, resolved.length - 1)];
      _idx = _fusedIndexOf(index.clamp(0, resolved.length - 1), resolved);
      _leaveFor(target);
      notifyListeners();
      await _play(target, source: source, fromPlaylist: true, manual: true);
      if (resumeFromBreakpoint && playlistUuid != null) {
        await _resumeFromMirrorIfAny(playlistUuid);
      }
      return;
    }

    if (_anchorKey == null) {
      // 首个列表即锚定：建立融合队列。
      _syncPlaylistUuid = playlistUuid;
      _bindDeepList(key, listSize: resolved.length);
      _fusedBase = resolved;
      _queue = _fusedQueue(resolved);
      final target = resolved[index.clamp(0, resolved.length - 1)];
      _idx = _fusedIndexOf(index.clamp(0, resolved.length - 1), resolved);
      _leaveFor(target);
      notifyListeners();
      await _play(target, source: source, fromPlaylist: true, manual: true);
      return;
    }

    if (key == _anchorKey) {
      // 同一锚定上下文：保留深层历史，仅随列表长度更新容量后重建融合队列。
      _syncPlaylistUuid = playlistUuid;
      _bindDeepList(key, listSize: resolved.length);
      _fusedBase = resolved;
      _queue = _fusedQueue(resolved);
      final target = resolved[index.clamp(0, resolved.length - 1)];
      _idx = _fusedIndexOf(index.clamp(0, resolved.length - 1), resolved);
      _leaveFor(target);
      notifyListeners();
      await _play(target, source: source, fromPlaylist: true, manual: true);
      return;
    }

    // 其它列表点歌：不切 base、不重建队列，仅替换深层末尾并播放该歌（外部点歌）。
    final target = resolved[index.clamp(0, resolved.length - 1)];
    _leaveFor(target);
    notifyListeners();
    await _play(target, source: source, fromPlaylist: false, manual: true);
  }

  Future<void> playAt(int index, {MusicSource? source}) async {
    if (index < 0 || index >= _queue.length) return;
    _leaveFor(_queue[index]);
    _idx = index;
    await _play(_queue[_idx], source: source, fromPlaylist: true, manual: true);
  }

  /// 「下一首播放」：把 [s] 排到当前曲之后（尚未播放任何内容时直接起播）。
  ///
  /// 锚定上下文里 [_queue] 是「深层历史 ‖ 基座续播段」的融合投影且总长恒等于基座长度，
  /// 直接 `_queue.insert` 会被下次 [_rebuildFusedQueue] 整段重算冲掉。因此这里只写
  /// [_nextUp]，由 [_fusedQueue]/[_rebuildFusedQueue] 在 [_nextUpOffset] 处替换拼接，
  /// 队列面板看到的顺序与实际播出一致。
  ///
  /// 语义是**替换**：「下一首播放」只有一格，再排别的就顶掉原先那首，队列不腾位置。
  ///
  /// 只改运行时队列，不改写持久化歌单（与 [removeAt] 同源）。已排过的同一首幂等（不重复替换）。
  bool playNext(Song s) {
    if (_current == null || _queue.isEmpty) {
      // 没有当前曲：「下一首播放」无从谈起，退化为直接起播。
      unawaited(playQueue([s]));
      return true;
    }
    if (_fusedBase != null && _deepList != null) {
      // 已排在这一格上：幂等，不重复替换自己。
      if (_nextUp != null && _same(_nextUp!, s)) return false;
      // 预载只有一格：排新的会顶掉原先排的那首（替换语义，队列长度不变）。
      _nextUp = s;
      _rebuildFusedQueue(target: _current);
    } else {
      // 非锚定队列不会被重算：直接把「当前曲之后那一格」换成新歌即可。
      // 注意这里不能碰 [_nextUp]——非锚定时 [_nextUpOffset] 恒为 0，
      // 留在槽里会让 [_advance] 跳回队首。
      final at = _idx + 1;
      if (at < _queue.length) {
        if (_same(_queue[at], s)) return false;
        _queue[at] = s;
      } else {
        _queue.add(s);
      }
    }
    // 下一首变了：作废旧的预取/预热，避免预热到已经不该播的那首。
    _peekedNext = null;
    _warmTimer?.cancel();
    _warmTimer = null;
    notifyListeners();
    _syncSystemMedia();
    _scheduleWarmup();
    return true;
  }

  /// 移除队列中第 [index] 首（右滑歌单页单曲移除/多选批量共用）。
  /// 只改运行时队列，不改写持久化歌单（与歌单详情不同源）。
  /// - 非当前曲：仅修正 [nextIndexAfterRemove] 并通知；
  /// - 当前曲：记一次离开事件后，续播同位置（滑入的那首）；队列被删光则收尾停止。
  void removeAt(int index) {
    if (index < 0 || index >= _queue.length) return;
    // 删掉的若是「下一首播放」预载项，清空槽位，否则重建后又冒出来。
    if (_nextUp != null && _same(_nextUp!, _queue[index])) _nextUp = null;
    final removingCurrent = index == _idx;
    if (removingCurrent) _leaveFor(null);
    _queue.removeAt(index);
    if (removingCurrent) {
      if (_queue.isEmpty) {
        unawaited(_clearStoppedState());
        return;
      }
      _idx = index.clamp(0, _queue.length - 1);
      unawaited(
          _play(_queue[_idx], source: _curSource, autoAdvanceOnFailure: true));
      return;
    }
    _idx = nextIndexAfterRemove(_idx, index);
    notifyListeners();
    _syncSystemMedia();
  }

  /// 清空队列：记录离开事件后停播、清当前曲与断点残留。
  /// 不动持久化歌单，仅运行时播放队列。
  void clearQueue() {
    _nextUp = null;
    if (_queue.isEmpty) return;
    _leaveFor(null);
    _queue = [];
    _idx = 0;
    unawaited(_clearStoppedState());
  }

  /// 队列被清空/当前曲被删光时收尾：停播、清当前曲与断点残留，通知 + 回推媒体会话。
  Future<void> _clearStoppedState() async {
    _fadeTimer?.cancel();
    _fadingPause = false;
    _peekedNext = null;
    _warmTimer?.cancel();
    _warmTimer = null;
    _current = null;
    _curSource = null;
    clearResumeState();
    try {
      await player.stop();
    } catch (_) {}
    notifyListeners();
    _syncSystemMedia();
  }

  /// 从队列移除 [removed]（非当前曲）后，当前下标 [cur] 的修正值：
  /// 移除位在当前位置之前 → 左移一位；之后 → 不变。
  /// 纯函数（不依赖实例状态），便于直接单测（同 [startIndexForOrder] 约定）。
  static int nextIndexAfterRemove(int cur, int removed) =>
      removed < cur ? cur - 1 : cur;

  /// 以本地索引最新行纠正旧快照（歌单快照/断点恢复可能携带补读前的数据）：
  /// 返回可直接播放的歌曲对象；索引中无此歌（服务端歌）时原样返回。
  Song resolveLiveSong(Song s) =>
      _index?.songByRef(s.sourceKey, s.sourceRef) ?? s;

  /// 整队解析：队列装载时统一纠正为本机索引实时行，
  /// 播放队列面板/后续切歌展示与歌曲页同源（封面/标题格式/歌手·专辑）。
  List<Song> _resolveLiveAll(List<Song> songs) =>
      [for (final s in songs) resolveLiveSong(s)];

  /// 用户修改元数据后：刷新队列与当前歌曲中的同源对象并通知（含断点快照）。
  void refreshSongMeta(Song updated) {
    var changed = false;
    for (var i = 0; i < _queue.length; i++) {
      if (_same(_queue[i], updated)) {
        _queue[i] = updated;
        changed = true;
      }
    }
    final cur = _current;
    if (cur != null && _same(cur, updated)) {
      _current = updated;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// [fromPlaylist]：锚定列表内播放（推入深层末尾）；false = 外部点歌（替换末尾）。
  /// [autoAdvanceOnFailure]：自动续播链路（自然播完/失败跳歌）专用——装载彻底失败
  /// 时不逐首弹 toast，直接跳下一首（见 [_autoSkipAfterFailure]）。
  /// [manual]：本曲是否用户手动点播（playAt/playQueue）——自然完播时额外走
  /// `complete_manual` 权重 +0.1 一档（改进.txt 功能7）；next/prev/自动/失败重试均非手动。
  Future<void> _play(Song s,
      {MusicSource? source,
      bool play = true,
      bool fromPlaylist = true,
      bool autoAdvanceOnFailure = false,
      bool manual = false}) async {
    // 连按切歌 guard：每次 _play 领一个单调令牌，后续 await 间隙若令牌过期
    //（更新的切歌已接管），静默丢弃，不报错、不覆盖、不触发副作用。
    // 解决了快速 next/prev 时旧 setUrl 的 connection abort / source error  toast 刷屏。
    final token = ++_playToken;
    bool alive() => token == _playToken;
    // 新曲开始前清掉上一首的预取结果与 completed 去重标记。
    _peekedNext = null;
    _completedKey = null;
    // 上一首的预热目标已作废，撤掉在途的退避重试（本曲装载成功后再预热新的）。
    _warmTimer?.cancel();
    _warmTimer = null;
    _warmingKey = null;
    // 睡眠定时处于「等当前曲放完」的挂起态时，手动切歌视为用户接管：取消定时。
    if (_sleepPendingStop) {
      _clearSleep();
      notifyListeners();
    }
    try {
      final src = _resolver?.call(s.sourceKey) ?? source ?? _curSource;
      // 以索引最新行纠正调用方可能携带的旧快照（歌单快照/断点恢复等）：
      // 后台补读过的歌名/歌手/封面立即可见，不再等重新读头或重启。
      final cur = resolveLiveSong(s);
      if (!identical(cur, s)) {
        for (var i = 0; i < _queue.length; i++) {
          if (_same(_queue[i], s)) _queue[i] = cur;
        }
      }
      // 立即切换当前曲目并通知：后面的网络装载/缓冲再慢，播放页也先显示新曲。
      _current = cur;
      _curSource = src;
      // 记录本次起始是否用户手动点播（改进.txt 功能7 完播判定用；任何新起始都会覆盖）。
      _startedManual = manual;
      notifyListeners();
      if (src == null || !src.supportsDirect) {
        // 无本地源（如同步快照行且本机未配置对应源）：不崩，提示后由调用方决定。
        throw StateError('找不到该歌曲的播放源，请先配置对应播放源');
      }
      await _playDirect(cur, src, alive: alive);
      if (!alive()) return; // 已被更新的切歌接管
      _loadFailStreak = 0;
      if (play) {
        // just_audio 的 play() 在内部 playing==true 时空转。上一首自然播完
        // 时 playing 不会自动复位，直接 play() 会静默跳过：平台层（ohos 的
        // mdk 停在 prepare 后的 paused、Android 的 ExoPlayer 也不发 play）
        // 收不到播放指令——表现为自动切歌无声、进度条靠 just_audio 时钟
        // 插值假走。装载新曲后先复位 playing 再播。
        if (player.playing) {
          await player.pause();
        }
        await player.play();
        _fadeIn();
      }
      if (!alive()) return;
      unawaited(_applyEqualizerBands());
      _saveState(player.position);
      // 深层列表维护：歌单内播放推入末尾；外部点歌替换末尾。
      _trackDeepList(cur, push: fromPlaylist);
      _onTrackStarted?.call(src, cur);
      // 播放即重读当前歌曲元数据（不管之前是否读过，保证展示最新）。
      unawaited(_enrichLazily(cur, src));
      unawaited(_loadLyrics(cur, src));
      // 趁本曲在播，把下一首的连接/鉴权打通（后台切歌不再冷启动）。
      _scheduleWarmup();
      notifyListeners();
      _syncSystemMedia();
    } catch (e) {
      if (!alive()) return; // 旧切歌被接管后的 abort：静默丢弃
      debugPrint('[play] 装载失败《${s.title}》: $e');
      // 自动续播链路：后台切歌失败不逐首弹 toast（人不在屏幕前），跳下一首；
      // 连败到上限才提示。手动点播仍逐次提示。
      if (!autoAdvanceOnFailure) AppToast.error(e, '播放失败');
      notifyListeners();
      if (autoAdvanceOnFailure) unawaited(_autoSkipAfterFailure());
    }
  }

  /// 直连源装载（带退避重试）：「切后台后还能播一两首、播完静默停住」的主因是
  /// 后台网络被回收/连接超时，失败后没有重试也没有下一首兜底。重试会重建连接；
  /// [alive] 为假（已被更新的切歌接管）或正在退出时立即放弃，不再触碰播放器。
  Future<void> _playDirect(Song s, MusicSource src,
      {required bool Function() alive}) async {
    Object? last;
    final backoff = loadBackoff;
    for (var i = 0; i <= backoff.length; i++) {
      if (!alive() || _shuttingDown) return;
      if (i > 0) {
        final wait = backoff[i - 1];
        debugPrint('[play] ${wait.inSeconds}s 后重试装载《${s.title}》');
        await Future.delayed(wait);
        if (!alive() || _shuttingDown) return;
      }
      try {
        final injected = loadOverride;
        if (injected != null) {
          await injected(s, src);
        } else {
          await _loadOnce(s, src);
        }
        return;
      } catch (e) {
        // 被更新的装载接管（连按切歌）不是源错误，重试没有意义。
        if (e is PlayerInterruptedException) rethrow;
        // 鉴权被拒（401/403）重试也不会好：立即失败让提示尽早出现。
        if (e is SourceAuthException) rethrow;
        last = e;
      }
    }
    throw last ?? StateError('装载失败');
  }

  /// 单次装载：优先离线缓存文件，其次原生 URL（Range/seek 更稳），
  /// 最后回落到自建字节流 [DirectAudioSource]。
  Future<void> _loadOnce(Song s, MusicSource src) async {
    final tag = mediaItemOf(s, title: displayTitle(s));
    final cached = await src.cachedFilePath(s);
    if (cached != null) {
      debugPrint('[play] ${src.kind} 缓存文件: $cached');
      await player.setFilePath(cached, tag: tag);
      return;
    }
    final direct = src.directStream(s);
    if (direct != null) {
      debugPrint('[play] ${src.kind} URL: ${direct.url}'
          '${direct.headers != null && direct.headers!.isNotEmpty ? ' (headers: ${direct.headers!.keys.join(",")})' : ' (无 headers)'}');
      // 装载前快速鉴权探针：1 字节 Range 走完 DNS/TCP/TLS/鉴权。401/403
      // 直接失败——原生播放器（fvp/ExoPlayer）对错误响应只会无限缓冲，
      // 进度停 0:00 无任何提示（2026-09-29 真机实测，密码过期即此表现）。
      // 其余探针异常不阻塞装载（网络抖动交给播放器自身重试）。
      try {
        final probe = src.probe(s);
        try {
          await probe.timeout(_probeTimeout);
        } on TimeoutException {
          probe.ignore(); // 看门狗放弃后，迟到的失败静默丢弃防 unhandled
          rethrow;
        }
      } on SourceAuthException {
        rethrow;
      } catch (e) {
        debugPrint('[play] 装载前探针失败（忽略，继续装载）: $e');
      }
      // 装载看门狗（_loadUrlTimeout）：超时按装载失败进入退避重试；迟到
      // 的完成/错误 ignore() 吞掉——若期间用户切了歌，旧 future 会被
      // just_audio 以 PlayerInterruptedException 打断，也不能变 unhandled。
      final load = player.setUrl(direct.url, headers: direct.headers, tag: tag);
      try {
        await load.timeout(_loadUrlTimeout);
      } on TimeoutException {
        load.ignore();
        throw TimeoutException(
            '装载超时（${_loadUrlTimeout.inSeconds}s）：服务器无响应或网络不可达');
      }
      return;
    }
    debugPrint('[play] ${src.kind} 自建字节流: ${s.title}');
    await player.setAudioSource(
        DirectAudioSource(source: src, song: s, tag: tag));
  }

  /// 懒补全：播放后把解析出的完整元数据（标题/歌手/专辑/专辑歌手/时长/曲目/年份/封面）
  /// 回填索引。从头完整读取（采样不足时读满整个文件，不截断），失败静默不影响播放。
  /// 成功后刷新队列与当前歌曲对象并通知，播放页即时展示新读到的信息；
  /// 另有变化时通过 [_onSongMetaRefreshed] 通知全局库就地刷新，并失效旧封面图像缓存。
  Future<void> _enrichLazily(Song s, MusicSource src) async {
    final idx = _index;
    if (idx == null) return;
    final k = '${s.sourceKey}\u0000${s.sourceRef}';
    if (_enriching.contains(k)) return;
    _enriching.add(k);
    try {
      await enrichSongMeta(idx, src, s);
      final updated = idx.songByRef(s.sourceKey, s.sourceRef);
      if (updated != null) {
        final changed = updated.title != s.title ||
            updated.artist != s.artist ||
            updated.albumName != s.albumName ||
            updated.albumArtist != s.albumArtist ||
            updated.duration != s.duration ||
            updated.genre != s.genre ||
            updated.trackNo != s.trackNo ||
            updated.year != s.year ||
            updated.coverPath != s.coverPath;
        refreshSongMeta(updated);
        if (changed) {
          final cover = updated.coverPath;
          if (cover != null) {
            // 同一路径封面被重写时 Flutter 图像缓存会留旧图，主动失效。
            unawaited(FileImage(File(cover)).evict());
          }
          _onSongMetaRefreshed?.call(updated);
        }
      }
      _applyLyricsIfCurrent(s);
    } catch (_) {
      // 后台补全失败不影响播放（不标已读，下次播放再试）。
    } finally {
      _enriching.remove(k);
    }
  }

  // ---------- 歌词（内嵌标签 / 同目录 .lrc） ----------

  List<LyricLine> _lyricLines = const [];
  String? _plainLyrics;
  bool _lyricsLoading = false;

  /// 当前歌词加载目标（sourceKey\0sourceRef）：异步结果回填时的切歌竞态守卫。
  String? _lyricsKey;

  List<LyricLine> get lyricLines => _lyricLines;
  String? get plainLyrics => _plainLyrics;
  bool get lyricsLoading => _lyricsLoading;

  /// 歌词页位置流（生产走 [player]，懒构造不额外建播放器）。
  Stream<Duration> get lyricPositionStream =>
      lyricsPositionOverride ?? player.positionStream;

  /// 歌词页位置流覆盖（仅测试：避免 widget 测试构造真实 AudioPlayer）。
  @visibleForTesting
  Stream<Duration>? lyricsPositionOverride;

  /// 测试注入歌词内容（生产走 [song_lyrics] / 同目录 `.lrc`）。
  @visibleForTesting
  void debugApplyLyrics(String content) => _applyLyrics(content);

  static String _songKey(Song s) => '${s.sourceKey}\u0000${s.sourceRef}';

  /// 通知栏 / 媒体会话元数据（settings.md §3.6）。
  ///
  /// Android 走 just_audio_background 时由它在 `setAudioSource` 时从 **tag** 读取，
  /// 自研 handler 则是主动回推；两条路径共用这一个构造，避免字段各写一套后漂移。
  /// `id` 必须唯一且非空（包依赖它标识曲目）。
  static MediaItem mediaItemOf(Song s, {String? title, Duration? duration}) {
    // 未给格式化标题时退回歌曲自身标题：通知栏宁可显示原名，也不要空行。
    final t = (title == null || title.isEmpty) ? s.title : title;
    return MediaItem(
      id: '${s.sourceKey}:${s.sourceRef}',
      album: s.albumName,
      artist: s.artist,
      title: t.isEmpty ? '未知曲目' : t,
      duration: duration,
      artUri: s.coverPath != null ? Uri.file(s.coverPath!) : null,
    );
  }

  /// 加载当前歌曲歌词：
  /// 1. 索引已有（内嵌补读 / 上次读取的同名 .lrc）→ 直接展示；
  /// 2. 直连源尝试同目录 `.lrc`；等待期间内嵌补读可能已写入索引，内嵌优先；
  /// 3. 都没有 → 写「无歌词」标记，避免每次播放重复请求。
  Future<void> _loadLyrics(Song s, MusicSource? src) async {
    final idx = _index;
    final key = _songKey(s);
    _lyricsKey = key;
    _lyricLines = const [];
    _plainLyrics = null;
    _lyricsLoading = true;
    notifyListeners();

    String? content = idx?.lyricsOf(s.sourceKey, s.sourceRef);
    if (content == null && idx != null && src != null && src.supportsDirect) {
      final lrc = await _fetchSiblingLrc(src, s);
      if (_lyricsKey != key) return; // 已切歌：丢弃本次结果
      final embedded = idx.lyricsOf(s.sourceKey, s.sourceRef);
      if (embedded != null && embedded.isNotEmpty) {
        content = embedded;
      } else if (lrc != null && lrc.trim().isNotEmpty) {
        idx.setLyrics(s.sourceKey, s.sourceRef, lrc);
        content = lrc;
      } else {
        idx.markLyricsMissing(s.sourceKey, s.sourceRef);
      }
    }
    if (_lyricsKey != key) return;
    _applyLyrics(content);
  }

  /// 内嵌补读成功后调用：当前曲有新歌词且尚未展示时即时刷新。
  void _applyLyricsIfCurrent(Song s) {
    if (_lyricsKey != _songKey(s)) return;
    final content = _index?.lyricsOf(s.sourceKey, s.sourceRef);
    if (content != null && content.isNotEmpty) _applyLyrics(content);
  }

  void _applyLyrics(String? content) {
    if (content == null || content.isEmpty) {
      _lyricLines = const [];
      _plainLyrics = null;
    } else {
      final parsed = parseLyrics(content);
      _lyricLines = parsed.lines;
      _plainLyrics = parsed.plain;
    }
    _lyricsLoading = false;
    notifyListeners();
  }

  /// 尝试读取同目录同名 `.lrc`（大小写两种扩展名），失败/不存在返回 null。
  Future<String?> _fetchSiblingLrc(MusicSource src, Song s) async {
    final ref = s.sourceRef;
    final slash = ref.lastIndexOf('/');
    final dot = ref.lastIndexOf('.');
    if (dot <= slash) return null;
    final stem = ref.substring(0, dot);
    for (final ext in const ['.lrc', '.LRC']) {
      try {
        final probe = Song.direct(
          id: s.id,
          sourceKey: s.sourceKey,
          title: s.title,
          source: s.source,
          sourceRef: '$stem$ext',
          fileSize: 0,
          format: 'lrc',
        );
        final opened =
            await src.open(probe, range: const IntRange(0, 512 * 1024));
        final bytes = <int>[];
        await for (final chunk in opened.stream) {
          bytes.addAll(chunk);
          if (bytes.length >= 512 * 1024) break;
        }
        if (bytes.isEmpty) continue;
        final text = _decodeTextBytes(bytes);
        if (text.trim().isNotEmpty) return text;
      } catch (_) {
        // 不存在/无权限：尝试下一个扩展名。
      }
    }
    return null;
  }

  /// 歌词文件字节解码：兼容 UTF-16 BOM 与 UTF-8（含 BOM / 宽松容错）。
  static String _decodeTextBytes(List<int> bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final buf = StringBuffer();
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        buf.writeCharCode(bytes[i] | (bytes[i + 1] << 8));
      }
      return buf.toString();
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final buf = StringBuffer();
      for (var i = 2; i + 1 < bytes.length; i += 2) {
        buf.writeCharCode((bytes[i] << 8) | bytes[i + 1]);
      }
      return buf.toString();
    }
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    return utf8.decode(bytes.sublist(start), allowMalformed: true);
  }

  // ---------- 前进/后退 ----------

  /// 预取的下一首（加权随机用它保证「确定的结果 = 实际播放」；其余模式可随时重算）。
  Song? _peekedNext;

  /// 按当前播放顺序算法确定下一首（不播放，只确定；开关与预载无关）：
  /// 顺序/列表循环/单曲循环可确定；加权随机先按权重抽样并记住，
  /// 切歌时复用同一结果，保证预载命中。
  Song? peekNext() {
    if (_queue.isEmpty || _current == null) return null;
    // 单曲循环与 [_advance] 口径一致：连预载也压住，否则会预热一首永远不会播的歌。
    if (_mode == PlayMode.loopOne) return _current;
    // 「下一首播放」优先：预热/系统媒体「下一首」都要与 [_advance] 的口径一致。
    if (_nextUp != null) {
      _peekedNext = _nextUp;
      return _peekedNext;
    }
    if (_mode == PlayMode.loopList) {
      _peekedNext = _queue[(_idx + 1) % _queue.length];
      return _peekedNext;
    }
    if (_mode == PlayMode.weighted) {
      _peekedNext = _pickWeighted();
      return _peekedNext;
    }
    if (_idx + 1 < _queue.length) {
      _peekedNext = _queue[_idx + 1];
      return _peekedNext;
    }
    return null;
  }

  /// 取出并校验预取的下一首（队列/当前曲变化后失效则返回 null 重新采样）。
  Song? _takePeeked() {
    final p = _peekedNext;
    _peekedNext = null;
    if (p == null || _current == null || _same(p, _current!)) return null;
    final i = _queue.indexWhere((s) => _same(s, p));
    return i < 0 ? null : _queue[i];
  }

  Future<void> next() {
    _leaveFor(null);
    return _advance();
  }

  /// 推进到下一首。[autoAdvanceOnFailure] 为 true 表示这是自动续播链路
  /// （自然播完、失败跳歌、播放错误恢复），装载失败时继续跳下一首而非停住。
  Future<void> _advance({bool autoAdvanceOnFailure = false}) async {
    if (_queue.isEmpty || _current == null) return;
    // 单曲循环是显式的「不要推进」：连 [_nextUp] 也压住，等用户切模式或手动下一首。
    if (_mode == PlayMode.loopOne) {
      await _replay();
      return;
    }
    // 「下一首播放」优先于随机抽样与列表循环：无论何种模式，用户排的那首都先播。
    if (_nextUp != null) {
      _idx = _nextUpOffset.clamp(0, _queue.length - 1);
      final target = _queue[_idx];
      // 先出队再播：装载失败时 [_autoSkipAfterFailure] 会重入 [_advance]，
      // 槽位若还在就会一直重播同一首。播成后由 [_rebuildFusedQueue] 让基座补位。
      _nextUp = null;
      await _play(target,
          source: _curSource, autoAdvanceOnFailure: autoAdvanceOnFailure);
      return;
    }
    if (_mode == PlayMode.weighted) {
      await _playWeighted(autoAdvanceOnFailure: autoAdvanceOnFailure);
      return;
    }
    if (_mode == PlayMode.loopList) {
      _idx = (_idx + 1) % _queue.length;
      await _play(_queue[_idx],
          source: _curSource, autoAdvanceOnFailure: autoAdvanceOnFailure);
      return;
    }
    if (_idx + 1 < _queue.length) {
      _idx++;
      await _play(_queue[_idx],
          source: _curSource, autoAdvanceOnFailure: autoAdvanceOnFailure);
      return;
    }
    // 顺序模式播到队尾：显式收尾。此前这里什么都不做，播放器停在 completed 且
    // playing 仍为 true，界面一直显示「播放中」却早已没声音。
    await _finishQueue();
  }

  /// 队列播完（或连续装载失败放弃）收尾：暂停 + 通知 + 回推媒体会话。
  Future<void> _finishQueue() async {
    try {
      await player.pause();
    } catch (_) {}
    notifyListeners();
    _syncSystemMedia();
  }

  /// 装载失败后自动跳下一首：连败到 [_loadFailSkipLimit] 首才停，
  /// 既不让个别坏歌卡住整条队列，也避免整队不可播时无限跳歌。
  Future<void> _autoSkipAfterFailure() async {
    _loadFailStreak++;
    debugPrint('[play] 装载连续失败 $_loadFailStreak 次');
    if (_loadFailStreak >= _loadFailSkipLimit) {
      _loadFailStreak = 0;
      await _finishQueue();
      AppToast.show('连续 $_loadFailSkipLimit 首无法加载，已停止播放');
      return;
    }
    await _advance(autoAdvanceOnFailure: true);
  }

  Future<void> prev() {
    _leaveFor(null);
    if (_queue.isEmpty || _current == null) return Future.value();
    // 深层列表（改进.txt 1.4）：上一首 = 弹出深层末尾（当前曲），新末尾从头播放。
    // 融合队列下同样弹栈——历史在深层中；深层空时退队列线性上一首。
    final dl = _deepList;
    if (dl != null && dl.length >= 2) {
      if (_mode == PlayMode.loopOne) return _replay();
      dl.popTail();
      _persistDeepList();
      final target = dl.tail;
      if (target != null) {
        if (_fusedBase != null) _rebuildFusedQueue(target: target);
        return _play(target, source: _curSource, fromPlaylist: false);
      }
    }
    // 无深层列表/仅一首：沿用队列上一首逻辑。
    if (_mode == PlayMode.loopOne) return _replay();
    if (_mode == PlayMode.loopList) {
      _idx = (_idx - 1 + _queue.length) % _queue.length;
      return _play(_queue[_idx], source: _curSource);
    }
    if (_idx > 0) {
      _idx--;
      return _play(_queue[_idx], source: _curSource);
    }
    return Future.value();
  }

  /// 单曲循环：同一首重播。
  Future<void> _replay() async {
    _completedKey = null;
    await player.seek(Duration.zero);
    await player.play();
  }

  /// 加权随机下一首（stage2.md §2.2）：优先采用 peekNext 已抽样的结果
  /// （保证预载的就是实际要播的），失效则重新从队列全量排除上一首按 factor 采样。
  Future<void> _playWeighted({bool autoAdvanceOnFailure = false}) async {
    final picked = _takePeeked() ?? _pickWeighted();
    if (picked == null) return;
    _idx = _queue.indexWhere((s) => _same(s, picked));
    if (_idx < 0) _idx = 0;
    await _play(picked,
        source: _curSource, autoAdvanceOnFailure: autoAdvanceOnFailure);
  }

  /// 按权重随机抽一首（排除当前曲；只剩当前曲时允许重播）。
  Song? _pickWeighted() {
    final i = _weightedPickIndex(_queue, _current);
    return i == null ? null : _queue[i];
  }

  /// 加权抽样的下标版（队列下一首与歌单起播共用）：
  /// 在 [pool] 中排除 [exclude] 后按 factor 抽样，返回命中下标；池空返回 null。
  /// 已应用时长削弱（改进.txt 功能8）：effective = factor × 时长系数，钳回 [0.5,1.5]。
  int? _weightedPickIndex(List<Song> pool, Song? exclude) {
    if (pool.isEmpty) return null;
    final curve = _durationCurve;
    var candidates = <int>[
      for (var i = 0; i < pool.length; i++)
        if (exclude == null || !_same(pool[i], exclude)) i,
    ];
    // 只剩当前曲（或全被排除）时退回全量，允许重播。
    if (candidates.isEmpty) candidates = [for (var i = 0; i < pool.length; i++) i];
    final store = _weight;
    // 整队一次性取回权重向量（按 sourceKey 分组批量查询），循环内不再逐首同步查库。
    final factors =
        store == null ? const <String, Map<String, double>>{} : store.factorsOf(pool);
    final weights = <double>[];
    for (final i in candidates) {
      final f = factors[pool[i].sourceKey]?[pool[i].sourceRef] ??
          SongWeightStore.defaultFactor;
      weights.add((f * curve.multiplierFor(pool[i].duration?.toDouble()))
          .clamp(SongWeightStore.minFactor, SongWeightStore.maxFactor));
    }
    return weightedPickByWheel(weights, _rng.nextDouble());
  }

  /// 加权轮盘：把 [weights] 按比例铺成 `[0,total)` 上的连续区段，取随机点 [r]
  /// （`[0,1)`，由调用方注入）落中哪段即返回该下标。
  ///
  /// 纯函数（不依赖实例状态），随机值由调用方注入——同 [startIndexForOrder]
  /// 的约定，便于确定性单测。每次命中概率 = `weights[i] / total`。
  /// [weights] 需非空（调用方已保证池非空），且各权重恒为正（上层钳回
  /// `[minFactor, maxFactor]`，杜绝零概率空槽）。
  static int weightedPickByWheel(List<double> weights, double r) {
    var total = 0.0;
    for (final w in weights) {
      total += w;
    }
    var pos = r * total;
    var picked = 0;
    for (var i = 0; i < weights.length; i++) {
      pos -= weights[i];
      if (pos <= 0) {
        picked = i;
        break;
      }
    }
    return picked;
  }

  /// 时长削弱曲线（设置>歌曲）：仅影响加权抽样的即时计算，不落库。
  WeightCurve get _durationCurve {
    final s = _appSettings;
    if (s == null || !s.weightCurveEnabled) return const WeightCurve();
    return WeightCurve.fromSettings(true, s.weightCurveSegments);
  }

  /// 歌单「播放」的起始下标（改进.txt：按当前播放顺序决定，而非固定从头）：
  /// - 顺序 / 单曲循环：首曲；
  /// - 列表循环：当前曲在歌单内则接续其后（末尾回绕到首曲），否则首曲；
  /// - 加权随机：按权重抽样（[weightedIndex] 由调用方给出，null 时退回首曲）。
  ///
  /// 纯函数（不依赖实例状态），便于直接单测；实例入口见 [startIndexForPlaylist]。
  static int startIndexForOrder(PlayMode mode, int length,
      {int? currentIndex, int? weightedIndex}) {
    if (length <= 0) return 0;
    switch (mode) {
      case PlayMode.loopList:
        if (currentIndex == null || currentIndex < 0) return 0;
        return (currentIndex + 1) % length;
      case PlayMode.weighted:
        final w = weightedIndex;
        return (w == null || w < 0 || w >= length) ? 0 : w;
      case PlayMode.sequence:
      case PlayMode.loopOne:
        return 0;
    }
  }

  /// 实例版起播下标：把「当前曲在歌单内的位置」与「加权抽样结果」喂给
  /// [startIndexForOrder]（加权模式在此抽样，与队列下一首同一套权重逻辑）。
  int startIndexForPlaylist(List<Song> songs) {
    if (songs.isEmpty) return 0;
    final cur = _current;
    final currentIndex =
        cur == null ? -1 : songs.indexWhere((s) => _same(s, cur));
    final weightedIndex = _mode == PlayMode.weighted
        ? _weightedPickIndex(songs, cur)
        : null;
    return startIndexForOrder(_mode, songs.length,
        currentIndex: currentIndex < 0 ? null : currentIndex,
        weightedIndex: weightedIndex);
  }

  // ---------- 事件采集（stage2.md §2.3） ----------

  void _emitWeight(Song s, {required bool completed, required Duration position}) {
    final w = _weight;
    if (w == null) return;
    final j = judgeWeightRatio(player.duration, position);
    // 用户手动点播并自然完播（>95%）：额外记一次 complete_manual——权重直接 +0.1
    // 一档并清空双 streak（改进.txt 功能7）。非手动起点（next/prev/自动/失败重试）不触发。
    final manual = _startedManual;
    if (j == WeightJudgement.complete) {
      w.onCompleted(s);
      if (manual) w.onCompletedManual(s);
    } else if (j == WeightJudgement.skip) {
      w.onSkipped(s);
    } else if (j == WeightJudgement.none && completed) {
      // 时长不可判定但自然结束：补偿记一次完播。
      w.onCompleted(s);
      if (manual) w.onCompletedManual(s);
    }
    _startedManual = false;
  }

  /// 手动离开当前歌前调用（避免对同一首重复判定）。
  void _leaveFor(Song? target) {
    final c = _current;
    if (c == null) return;
    if (target != null && _same(c, target)) return;
    _emitWeight(c, completed: false, position: player.position);
  }

  // ---------- 播放控制 ----------

  Future<void> toggle() async {
    if (_fadingPause) return;
    if (player.playing) {
      await _fadeOutThenPause();
    } else {
      await _resumeOrReplay();
    }
    notifyListeners();
    _syncSystemMedia();
  }

  /// 恢复播放：若当前曲已播完（顺序模式队尾收尾或单曲播完），
  /// 先回到 0 处再播——否则 play() 会立刻再次 completed，表现为「按了没反应」。
  Future<void> _resumeOrReplay() async {
    if (player.processingState == ProcessingState.completed) {
      try {
        await player.seek(Duration.zero);
      } catch (_) {}
    }
    await player.play();
    _fadeIn();
  }

  /// 通知栏「播放」回调（settings.md §3.6）。
  Future<void> resumeFromNotifier() async {
    await _resumeOrReplay();
    notifyListeners();
    _syncSystemMedia();
  }

  /// 通知栏「暂停/停止」回调（settings.md §3.6）。
  Future<void> pauseFromNotifier() async {
    await _fadeOutThenPause();
    notifyListeners();
    _syncSystemMedia();
  }

  /// 通知栏「停止」/ 任务被划掉：停止播放；默认清断点（通知栏「停止」= 用户显式
  /// 停掉，与丢弃队列一致），划掉任务路径传 `clearResume: false` 保留断点/队列。
  /// 处理器的 `super.stop()` 随后把状态置 idle，前台服务/通知随之结束。
  Future<void> stopFromNotifier({bool clearResume = true}) async {
    _fadeTimer?.cancel();
    _fadingPause = false;
    try {
      await player.stop();
    } catch (_) {
      // 平台停止失败不阻塞退出流程。
    }
    if (clearResume) clearResumeState();
    notifyListeners();
  }

  Future<void> seek(Duration d) async {
    await player.seek(d);
    _syncSystemMedia();
  }

  // ---------- 断点（stage2.md §7） ----------

  void _maybeSaveState(Duration pos) {
    final now = DateTime.now();
    if (_lastStateSave == null ||
        now.difference(_lastStateSave!) >= const Duration(seconds: 2)) {
      _lastStateSave = now;
      unawaited(_saveState(pos));
    }
  }

  Future<void> _saveState(Duration pos) async {
    final idx = _index;
    if (idx == null || _queue.isEmpty || _current == null) return;
    await idx.savePlayState(
      jsonEncode(_queue.map((s) => s.toJson()).toList()),
      _idx,
      pos.inMilliseconds,
      playlistUuid: _syncPlaylistUuid,
      anchorKey: _anchorKey,
    );
    await _maybeEnqueueBreakpoint(idx, pos);
  }

  /// 阶段5 断点进 outbox（节流：同歌 25s 一次，切歌立即）。
  /// 队列归属已同步歌单且当前歌曲有身份即上报：服务器模式恒上报，
  /// 直连歌曲需连着服务器；其它情况只活本机。
  Future<void> _maybeEnqueueBreakpoint(LocalIndex idx, Duration pos) async {
    final uuid = _syncPlaylistUuid;
    final cur = _current;
    if (uuid == null || cur == null) return;
    if (cur.source.isEmpty ||
        cur.source == 'server' ||
        cur.sourceRef.isEmpty) {
      return;
    }
    if (cur.sourceKey != 'server' && !(_serverAvailable?.call() ?? false)) {
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final key = '$uuid|${cur.source}|${cur.sourceRef}';
    if (key != _lastBpKey || nowMs - _lastBpAtMs > 25000) {
      _lastBpKey = key;
      _lastBpAtMs = nowMs;
      final sourceId = idx.sourceUuidOf(cur.sourceKey);
      final dl = _deepList;
      // 深层列表以身份数组随断点携带（有序 {source, source_ref}），对端按身份重建。
      final deepList = [
        for (final s in (dl?.entries ?? const <Song>[]))
          if (s.source.isNotEmpty && s.sourceRef.isNotEmpty)
            {'source': s.source, 'source_ref': s.sourceRef},
      ];
      await idx.enqueueOutbox(SyncEventTypes.breakpointSet, {
        'playlist_uuid': uuid,
        'source': cur.source,
        'source_ref': cur.sourceRef,
        if (sourceId != null) 'source_id': sourceId,
        'position_ms': pos.inMilliseconds,
        'deep_list': deepList,
      });
    }
  }

  /// 启动恢复（仅本机断点）：装载上次队列与位置，暂停态不自动播放。
  Future<void> restoreIfAny() async {
    final idx = _index;
    if (idx == null || _restored) return;
    _restored = true;
    await _restoreLocal(idx, idx.getPlayState());
  }

  /// 启动恢复（跨设备优先）：本机与所有镜像断点中取最新者；
  /// 远端更新且其歌单在本机存在时，重建该歌单队列并从该进度恢复（暂停态）。
  Future<void> restorePreferRemote() async {
    final idx = _index;
    if (idx == null || _restored) return;
    _restored = true;
    final local = idx.getPlayState();
    BreakpointMirrorRow? best;
    DateTime? bestAt;
    for (final m in idx.allBreakpointMirrors()) {
      final t = DateTime.tryParse(m.updatedAt);
      if (t == null) continue;
      if (bestAt == null || t.isAfter(bestAt)) {
        best = m;
        bestAt = t;
      }
    }
    final localAt = local == null ? null : DateTime.tryParse(local.updatedAt);
    if (best != null &&
        bestAt != null &&
        (localAt == null || bestAt.isAfter(localAt))) {
      if (await _restoreFromMirror(idx, best)) return;
    }
    await _restoreLocal(idx, local);
  }

  Future<void> _restoreLocal(LocalIndex idx, PlayStateRow? st) async {
    if (st == null || st.queueJson.isEmpty) return;
    try {
      final list = (jsonDecode(st.queueJson) as List)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
      if (list.isEmpty) {
        idx.clearPlayState();
        return;
      }
      _queue = _resolveLiveAll(list);
      _idx = st.idx.clamp(0, _queue.length - 1);
      final storedCurrent = _queue[_idx];
      // 归属歌单仍在则保留（断点继续上报），否则清除。
      _syncPlaylistUuid = (st.playlistUuid != null &&
              idx.playlistIdOfUuid(st.playlistUuid!) != null)
          ? st.playlistUuid
          : null;
      // 锚定键：新版断点携带 anchorKey；旧行按 playlistUuid 推导。
      final anchorKey = st.anchorKey ??
          (st.playlistUuid != null
              ? PlayerProvider.anchorForPlaylist(st.playlistUuid!)
              : null);
      _bindDeepList(anchorKey, listSize: _queue.length);
      // 歌单上下文：用本机深层列表 + 当前歌单重建融合队列（不信任旧快照顺序）；
      // 找不到歌单时退回旧快照原样（融合基座为空，后续只走快照）。
      final pid =
          _syncPlaylistUuid == null ? null : idx.playlistIdOfUuid(_syncPlaylistUuid!);
      if (_syncPlaylistUuid != null && pid != null) {
        final base = _resolveLiveAll(idx.playlistSongs(pid));
        if (base.isNotEmpty) {
          _fusedBase = base;
          _queue = _fusedQueue(base);
          var targetI = _queue.indexWhere((s) => _same(s, storedCurrent));
          if (targetI < 0) targetI = 0;
          _idx = targetI.clamp(0, _queue.length - 1);
          _current = _queue[_idx];
        }
      } else if (anchorKey != null) {
        // 非歌单锚定：深层历史随锚定键恢复；基座无法离线重建，沿用队列快照。
        _fusedBase = null;
        var targetI = _queue.indexWhere((s) => _same(s, storedCurrent));
        if (targetI < 0) targetI = 0;
        _idx = targetI.clamp(0, _queue.length - 1);
        _current = _queue[_idx];
      }
      if (_current == null) {
        if (_queue.isEmpty) {
          idx.clearPlayState();
          return;
        }
        _current = _queue[0];
      }
      // 从断点位置起装载（暂停态）：目标歌曲本机无源（如同步来的歌单行但未配置
      // 对应源）时，静默退到其后第一首可播曲目（与 _restoreFromMirror 一致），
      // 全部不可播则保持队列暂停、不装载——启动恢复不弹「播放失败」。
      var resume = _idx;
      while (resume < _queue.length &&
          !_playable(_resolver?.call(_queue[resume].sourceKey))) {
        resume++;
      }
      if (resume < _queue.length) {
        final atBreakpoint = resume == _idx;
        _idx = resume;
        _current = _queue[resume];
        await _play(_current!, play: false);
        if (atBreakpoint && st.positionMs > 0) {
          await player.seek(Duration(milliseconds: st.positionMs));
        }
      }
      notifyListeners();
      _syncSystemMedia();
    } catch (e) {
      AppToast.error(e, '断点恢复失败');
      notifyListeners();
    }
  }

  /// 用远端断点重建歌单队列并恢复进度；目标歌本机无源时退到其后第一首可播条目。
  /// 镜像携带深层列表时，按身份重建该歌单的深层历史，并重建融合队列。
  Future<bool> _restoreFromMirror(LocalIndex idx, BreakpointMirrorRow m) async {
    final pid = idx.playlistIdOfUuid(m.playlistUuid);
    if (pid == null) return false;
    final songs = idx.playlistSongs(pid);
    if (songs.isEmpty) return false;
    final found = songs.indexWhere((s) => _refMatches(s.sourceRef, m.sourceRef));
    var start = found < 0 ? 0 : found;
    while (start < songs.length &&
        !_playable(_resolver?.call(songs[start].sourceKey))) {
      start++;
    }
    if (start >= songs.length) return false;
    _syncPlaylistUuid = m.playlistUuid;
    _bindDeepList(PlayerProvider.anchorForPlaylist(m.playlistUuid),
        listSize: songs.length);
    // 镜像深层列表（按身份匹配到本机歌单）→ 重建深层历史；缺失时保持本机。
    final dlEntries = _deepListFromMirror(m.deepListJson, songs);
    if (dlEntries.isNotEmpty) {
      _deepList = DeepListController(
          capacity: songs.length, entries: dlEntries);
      _persistDeepList();
    }
    _fusedBase = _resolveLiveAll(songs);
    _queue = _fusedQueue(_fusedBase!);
    _idx = _fusedIndexOf(start, songs).clamp(0, _queue.length - 1);
    _current = _queue[_idx];
    try {
      await _play(_current!, play: false);
      final pos = (found >= 0 && start == found) ? m.positionMs : 0;
      if (pos > 0) await player.seek(Duration(milliseconds: pos));
      notifyListeners();
      _syncSystemMedia();
      AppToast.show('已从其他设备继续播放（${_fmtMs(pos)}）', isError: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 镜像身份列表 → 本机歌单匹配后的深层条目（坏行/无匹配跳过，保持顺序）。
  List<Song> _deepListFromMirror(String? deepListJson, List<Song> songs) {
    if (deepListJson == null || deepListJson.isEmpty) return const [];
    try {
      final raw = jsonDecode(deepListJson);
      if (raw is! List) return const [];
      final out = <Song>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final ref = e['source_ref'];
        if (ref is! String || ref.isEmpty) continue;
        final i = songs.indexWhere((s) => _refMatches(s.sourceRef, ref));
        if (i >= 0 && !out.any((x) => _same(x, songs[i]))) out.add(songs[i]);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 「播放」：其他设备的断点更新时自动定位到该进度并提示。
  Future<void> _resumeFromMirrorIfAny(String playlistUuid) async {
    final idx = _index;
    if (idx == null) return;
    final m = idx.breakpointMirrorOf(playlistUuid);
    if (m == null || m.positionMs <= 0) return;
    final mAt = DateTime.tryParse(m.updatedAt);
    if (mAt == null) return;
    final local = idx.getPlayState();
    final localAt =
        (local?.playlistUuid == playlistUuid && local != null)
            ? DateTime.tryParse(local.updatedAt)
            : null;
    if (localAt != null && !mAt.isAfter(localAt)) return;
    final i = _queue.indexWhere((s) => _refMatches(s.sourceRef, m.sourceRef));
    if (i < 0) return;
    try {
      await playAt(i, source: _curSource);
      await player.seek(Duration(milliseconds: m.positionMs));
      AppToast.show('已从其他设备进度继续（${_fmtMs(m.positionMs)}）', isError: false);
    } catch (_) {
      // 定位失败不阻断播放。
    }
  }

  /// ref 匹配（兼容 WebDAV 编码变体）。
  static bool _refMatches(String a, String? b) {
    if (b == null || b.isEmpty) return false;
    if (a == b) return true;
    return webdavRefVariants(b).contains(a);
  }

  static String _fmtMs(int ms) {
    final d = Duration(milliseconds: ms);
    final mm = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$mm:$ss' : '$mm:$ss';
  }

  void clearResumeState() => _index?.clearPlayState();

  // ---------- 深层列表（隐藏历史栈，任意列表锚定上下文） ----------

  /// 绑定（或解绑）当前锚定列表的深层列表；同一锚定重复绑定仅更新容量。
  /// [listSize]：锚定列表当前歌曲总数（容量；>0 时更新）。
  /// [reset]：切换锚定（播放/从头播放）——清空深层历史后按空栈重建。
  void _bindDeepList(String? anchorKey, {int listSize = 0, bool reset = false}) {
    if (anchorKey == null) {
      // 解锚后 [_queue] 保留（其中已含「下一首播放」实际位置），暂存区必须清空：
      // 否则 [_nextUpOffset] 会退化成 0，推进时跳回队首。
      _nextUp = null;
      _deepList = null;
      _anchorKey = null;
      _fusedBase = null;
      return;
    }
    if (!reset && _deepList != null && _anchorKey == anchorKey) {
      if (listSize > 0) _deepList!.capacity = listSize;
      return;
    }
    _anchorKey = anchorKey;
    List<Song> entries = const [];
    if (!reset) {
      final raw = _index?.loadDeepList(anchorKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          entries = DeepListController.parseEntries(jsonDecode(raw));
        } catch (_) {
          entries = const [];
        }
      }
    }
    _deepList = DeepListController(
        capacity: listSize > 0 ? listSize : entries.length,
        entries: entries);
    if (reset) _persistDeepList();
  }

  void _persistDeepList() {
    final idx = _index;
    final key = _anchorKey;
    final dl = _deepList;
    if (idx == null || key == null || dl == null) return;
    idx.saveDeepList(key, jsonEncode(dl.toJson()));
  }

  /// 播放成功后的深层列表维护：锚定列表内播放推入末尾，外部点歌替换末尾。
  void _trackDeepList(Song s, {required bool push}) {
    final dl = _deepList;
    if (dl == null || _anchorKey == null) return;
    if (push) {
      dl.pushPlayed(s, same: _same);
    } else {
      dl.replaceTail(s, same: _same);
    }
    _persistDeepList();
    // 深层列表变化 → 重建融合队列（深层占前 N，基座第 N+1 位起接续）。
    _rebuildFusedQueue(target: _current);
  }

  /// 融合队列：队列 = 深层列表（前 N 位）+ 基座第 N+1 位起（后 M-N 位），
  /// 不按内容去重。锚定上下文（[_fusedBase] 非空）时启用；外部队列原样。
  /// 定位到 [target]（按身份）；找不到则退到深层末尾。返回是否命中目标。
  bool _rebuildFusedQueue({Song? target}) {
    final base = _fusedBase;
    final dl = _deepList;
    if (base == null || dl == null) return false;
    final n = dl.length;
    // 「下一首播放」预载项已播完（推进到它之后自然出队并让基座补位），避免重复出现在融合队列里。
    if (_nextUp != null && _current != null && _same(_nextUp!, _current!)) {
      _nextUp = null;
    }
    // 预载占掉基座第 n+1 首，故续播段从 n+1（或无预载时的 n）接续，总长守恒。
    final cut = n + (_nextUp != null ? 1 : 0);
    final rest = base.length > cut ? base.sublist(cut) : const <Song>[];
    _queue = [...dl.entries, if (_nextUp != null) _nextUp!, ...rest];
    final t = target ?? _current;
    final i = t == null ? -1 : _queue.indexWhere((s) => _same(s, t));
    if (i >= 0) {
      _idx = i;
      _current = _queue[i];
      return true;
    }
    _idx = n > 0 ? n - 1 : 0;
    if (_queue.isNotEmpty) _current = _queue[_idx.clamp(0, _queue.length - 1)];
    return false;
  }

  /// 歌单/锚定列表删歌联动：深层列表移除该歌引用（始终同步删）；
  /// 若删的是当前曲，则播放新末尾（从头开始）。[anchorKey] 只作用于当前锚定上下文。
  Future<void> onAnchorSongRemoved(String anchorKey, Song s,
      {int? newCount}) async {
    final dl = _deepList;
    if (_anchorKey != anchorKey || dl == null) return;
    // 歌单里删掉的这首若正排在「下一首播放」，一并撤掉。
    if (_nextUp != null && _same(_nextUp!, s)) _nextUp = null;
    if (newCount != null && newCount > 0) {
      dl.capacity = newCount;
    }
    final removedCurrent = _current != null && _same(_current!, s);
    dl.removeRef(s, same: _same);
    _persistDeepList();
    _rebuildFusedQueue(target: _current);
    if (!removedCurrent) return;
    final target = dl.tail;
    if (target == null) return;
    final i = _queue.indexWhere((x) => _same(x, target));
    if (i >= 0) _idx = i;
    await _play(target, source: _curSource);
  }

  /// 歌单删歌联动（转锚定键统一处理）。
  Future<void> onPlaylistSongRemoved(String playlistUuid, Song s,
      {int? newPlaylistCount}) {
    return onAnchorSongRemoved(PlayerProvider.anchorForPlaylist(playlistUuid),
        s,
        newCount: newPlaylistCount);
  }

  /// 歌单被整体删除：解绑其深层列表与断点归属。
  void onPlaylistDeleted(String playlistUuid) {
    final key = PlayerProvider.anchorForPlaylist(playlistUuid);
    if (_anchorKey == key) {
      _nextUp = null;
      _deepList = null;
      _anchorKey = null;
      _fusedBase = null;
      _index?.deleteDeepList(key);
    }
    if (_syncPlaylistUuid == playlistUuid) _syncPlaylistUuid = null;
  }

  /// 退出软件前清理：保存断点、停止并释放播放器（确保 mpv 等外部子进程退出）。
  Future<void> shutdown() async {
    _shuttingDown = true;
    _fadeTimer?.cancel();
    _sleepTick?.cancel();
    _warmTimer?.cancel();
    final p = _player;
    if (p == null) {
      // 从未播放过：没有实例可停，但断点/写队列仍要落库。
      await _saveState(Duration.zero);
      try {
        await _index?.flushWrites();
      } catch (_) {}
      return;
    }
    await _saveState(p.position);
    // 退出前等写隔离队列落库（否则最后断点/设置随进程一起消失）。
    try {
      await _index?.flushWrites();
    } catch (_) {}
    try {
      await p.stop();
    } catch (_) {}
    await _disposePlayer();
  }

  bool _same(Song a, Song b) =>
      a.sourceKey == b.sourceKey && a.sourceRef == b.sourceRef;

  @override
  void dispose() {
    if (!kIsWeb) WidgetsBinding.instance.removeObserver(this);
    _disposed = true;
    _fadeTimer?.cancel();
    _sleepTick?.cancel();
    _warmTimer?.cancel();
    // 退出前把最后一段播放时长结清（与 _saveState 同样不等待）。
    _playSecStop();
    final p = _player;
    _player = null;
    if (p != null) {
      unawaited(_saveState(p.position));
      unawaited(p.dispose());
    }
    super.dispose();
  }
}