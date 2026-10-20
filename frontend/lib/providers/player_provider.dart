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
import '../data/sources/transcode_variant.dart';
import '../data/sources/direct_audio_source.dart';
import '../data/sources/meta_enrich.dart';
import '../data/sources/webdav_url.dart';
import '../data/local/local_index.dart';
import '../data/local/app_settings.dart';
import '../data/local/song_weight_store.dart';
import '../data/deep_list.dart';
import '../data/local/sync_event_types.dart';
import '../platform/app_background.dart';
import '../platform/harmonyos/ohos_bootstrap.dart' show isOhos;
import '../services/audio_focus_monitor.dart';
import '../services/playback_guard.dart';
import '../services/selfmusic_audio_handler.dart';
import '../utils/lrc_parser.dart';
import '../utils/perf_log.dart';
import '../utils/play_stats.dart';
import '../utils/song_title_format.dart';
import '../utils/weight_curve.dart';
import '../widgets/app_toast.dart';

// 转码门控定义见 `data/sources/transcode_variant.dart`（播放装载与预载变体
// 共用同一口径）；经本文件 re-export，单测 import 本文件即可。
export '../data/sources/transcode_variant.dart' show shouldUseTranscode;

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

/// 按源 key 返回播放候选（主 + 备用，按线路偏好排序）：
/// 每项为 `(source, lineIndex)`，lineIndex: 0=主用, 1=备用1, 2=备用2。
typedef LineCandidatesResolver = List<(MusicSource, int)> Function(
    String sourceKey);

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

  /// 当前曲实际走的线路（0=主用, 1=备用1, 2=备用2；供播放页线路菜单高亮）。
  int _curLine = 0;
  int get curLine => _curLine;
  SourceResolver? _resolver;

  /// 备用候选解析（main 经 direct.lineCandidates 注入；为空则单线路）。
  LineCandidatesResolver? _candidates;
  void attachLineCandidates(LineCandidatesResolver r) => _candidates = r;
  LocalIndex? _index;
  SongWeightStore? _weight;
  AppSettings? _appSettings;
  void Function(MusicSource src, Song s)? _onTrackStarted;
  void Function(Song s)? _onSongMetaRefreshed;
  SelfMusicAudioHandler? _audioHandler;

  /// 静音/断连暂停守卫（settings.md §3.2，Android/鸿蒙）：由 [attachAudioGuard]
  /// 装配，设置开关变动后经 [refreshPlaybackGuard] 同步订阅。
  PlaybackGuard? _playbackGuard;

  /// 音频焦点事件源（settings.md §3.2）：Android 由 just_audio 内部处理，
  /// 进入这里的是空流；鸿蒙由 AVPlayer 的 audioInterrupt 驱动。
  StreamSubscription<AudioFocusEvent>? _audioFocusSub;

  /// 系统焦点中断已经把播放器暂停，等待焦点恢复后按开关自动续播。
  bool _audioFocusPaused = false;

  /// 焦点暂停的 playing=false 收口还没到，用于只落一次最终断点。
  bool _audioFocusSavePending = false;

  /// 上一次 playerStateStream 的 playing：只在「实际播放态变化」时通知 UI。
  bool _lastPlayerStatePlaying = false;

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

  /// 顺序推进的接缝复本跳过（纯函数，供测试）：
  /// 融合队列 `深层(n) ‖ 续播段` 中，若落点 [landed] 恰为续播段首位（== n，
  /// 且 [anchored] 为真、无预载），而该歌与 [prev]（推进前当前曲）同一首——
  /// 它是深层尾的复本而非真正的下一首（手动点播换尾后常见，如深层 [s1,s3]
  /// 时续播段首位仍是 s3），推进/预取应越过它，否则下一首原地打转。
  /// 非锚定普通队列不用（没有融合接缝；歌单内本就重复的歌也不在此处理）。
  /// 返回实际落点；越过队尾（>= 队列长）时原样返回，由调用方收尾/回绕。
  @visibleForTesting
  static int skipSeamDupIndex(int landed, int deepLen, List<Song> queue,
      Song prev, bool Function(Song a, Song b) same,
      {required bool anchored}) {
    if (!anchored) return landed;
    if (landed == deepLen &&
        landed < queue.length &&
        same(queue[landed], prev)) {
      return landed + 1;
    }
    return landed;
  }

  /// 在融合队列中定位当前曲（纯函数，供测试）：深层尾与目标同首时取尾下标
  /// （刚播完的歌恒为深层尾；旧复本排在前面），否则取首个匹配；找不到返回 -1。
  /// [deepLen] 为深层长度（尾下标 = deepLen-1）。
  @visibleForTesting
  static int locateCurrentIndex(List<Song> queue, int deepLen, Song target,
      bool Function(Song a, Song b) same) {
    if (deepLen > 0 &&
        deepLen - 1 < queue.length &&
        same(queue[deepLen - 1], target)) {
      return deepLen - 1;
    }
    return queue.indexWhere((s) => same(s, target));
  }

  /// 阶段5：服务器可达性门控（main 经 [attachServerAvailable] 注入）。
  bool Function()? _serverAvailable;

  /// 阶段6：无状态转码 API（main 经 [attachApi] 注入；为空则转码关闭）。
  /// import 经上方案例避免循环：ApiClient 仅作动态调用（baseUrl/getAccessToken/
  /// transcodeStreamUrl），此处用 dynamic 持有以避开 provider→service 的导入环。
  dynamic _transcodeApi;

  /// 关联转码 API（阶段6）。
  void attachApi(dynamic api) {
    _transcodeApi = api;
  }

  /// 断点事件节流：同歌 25s 内不重复入队（切歌立即入队）。
  String? _lastBpKey;
  int _lastBpAtMs = 0;

  /// 上次入队（或恢复/采用）的断点位置：`occurred_at` 语义=「最后操作时间」，
  /// 暂停态原样补写（生命周期/退出落盘）不刷新时钟不重推（[-1]=从未上报）。
  int _lastBpPosMs = -1;

  /// 断点跳过原因去重（诊断日志）：同因连续出现只打一条，
  /// 原因变化或成功入队即重置（本方法约每 10s 被调一次，逐次打会刷屏）。
  String? _lastBpSkipReason;

  /// F1 启动收敛闸门：进程启动恢复出本机断点后、首个 [applyNewerMirrorIfAny]
  /// 跑完（或兜底超时）前，断点一律不入队——本机恢复态可能已被远端更新，
  /// 此时用 now 盖上 occurred_at 推上去正是「旧数据覆盖新数据」的毒源
  /// （服务端 LWW 按时间戳收下它），随后本机又把自己的回声拉回来（回退旧曲
  /// 的完整回路）。默认已开：无恢复路径（未开断点续播/测试）不受影响。
  bool _bootConverged = true;
  Timer? _bootGateTimer;

  /// 闸门关闭期间被挡下的「暂停/停止强制断点」：开闸后补跑一次。
  bool _bootForcedPending = false;

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

  /// 断点落库周期（真机取证 2026-10-15）：旧值 2s 太密——每次都要
  /// `jsonEncode` 整个队列并重写 `play_state` 整行（队列 1207 首时实测
  /// 序列化 28~61ms + 当时 ohos 内联写库 9~24ms，均在 UI 线程），表现为
  /// 每两秒一次的掉帧。写层现已默认后台隔离，但队列序列化仍在 UI；故保留
  /// 10s 周期。暂停/切歌/退后台/退出仍强制落库（见 [_saveForcedAndPoke]
  /// 与 [onPause] 链路），崩溃最多丢 10s 位置。
  static const Duration _stateSaveInterval = Duration(seconds: 10);

  /// 上次落库的曲目身份：切歌立即落一次（不等 [_stateSaveInterval]），
  /// 避免崩溃后回到上一首。
  String? _lastSavedSongKey;

  /// 队列 JSON 缓存（含缓存键）。
  ///
  /// 键取 `Object.hashAll(_queue)`：`Song` 字段全 `final` 且无自定义
  /// `hashCode`/`==`，即对象身份哈希——队列内任何元素替换（元数据回填
  /// `refreshSongMeta` 就是整对象替换）、增删、重排都会改哈希；代价仅 O(n)
  /// 次指针读取（1207 首约数十微秒），远低于重编码的 28~61ms。
  Object? _queueJsonKey;
  String? _queueJsonCache;

  /// 取队列 JSON（队列未变化则复用缓存，避免每 2s 周期性重编码大队列）。
  String _encodedQueue() {
    final key = Object.hashAll(_queue);
    final cached = _queueJsonCache;
    if (cached != null && key == _queueJsonKey) return cached;
    final encoded = jsonEncode(_queue.map((s) => s.toJson()).toList());
    _queueJsonKey = key;
    _queueJsonCache = encoded;
    return encoded;
  }

  /// 用户在启动恢复后是否主动接管过播放（播放/暂停/切歌/seek/改队列）：
  /// 首轮同步晚到的远端断点此时不再回切，避免打断用户操作。
  bool _userTookOver = false;

  /// 当前会话所依据的断点时间（本机恢复或远端镜像 adopted 时的 `updated_at`）。
  ///
  /// 与 `play_state.updated_at` **分离**：后者每次 `_saveState`（含 `_play` 起播、
  /// 周期节流写入）都会被刷新为客户端 `now`，不能用作「远端断点是否更新」的基准
  /// （否则启动恢复 `_play` 覆盖本地时间后，远端镜像恒判更旧，跨设备续播永不生效）。
  DateTime? _breakpointBaselineAt;

  /// 启动恢复的飞行中 Future：远端断点套用前先等它收尾。恢复的同步前缀已经在
  /// 首帧前完成，但音频装载/seek 的异步尾在跑；两者并发会双重装载、状态抖动
  /// （main.dart 的「先恢复、后拉取、再补切」约束）。
  Future<void>? _restoreFuture;

  /// 启动恢复期间用户连点播放/暂停的待应用目标态。
  ///
  /// 非 null 时表示恢复尚未收尾：true=恢复完播放，false=恢复完保持暂停。
  /// 连点只翻转这里，恢复尾统一执行一次，避免多次 `play()`/淡入叠加；
  /// [playing] 在等待期直接返回它，按钮目标态仍能即时响应。
  bool? _restoreResumeTarget;

  /// 等启动恢复收尾后统一应用待办目标态的 single-flight。
  Future<void>? _restoreResumeFuture;

  /// 断点套用 single-flight：恢复/套用进行中再触发只记一次待办，结束后用最新
  /// 镜像补跑一次，避免并发 `_play` 与多页 pull 期间的连续换曲（冷启动卡顿根因）。
  bool _applyingMirror = false;
  bool _mirrorApplyQueued = false;
  bool _mirrorApplyViaSync = false;

  /// 启动恢复的同步前缀（Root.initState 的 build 期内）抑制通知：此时
  /// markNeedsBuild 会被 framework 断言 "setState during build"。同步前缀由
  /// 首个 await 结束，微任务里解除；首帧直接读同步前缀已置好的状态，不依赖通知。
  bool _suppressSyncNotify = false;

  /// 断点恢复的乐观位置（毫秒）：`_restoreLocal/_restoreFromMirror` 在装载音频前
  /// 的同步前缀即设置，供首帧进度显示；真实 `seek` 完成后（或用户接管/失败）
  /// 清空。[position] 在非空**且归属仍是当前曲**时优先返回它，音频尚未装载
  /// 即有正确进度；中途切到别的歌自动失效（见 [_restorePositionKey]）。
  int? _restorePositionMs;

  /// 乐观位置归属的歌曲（`sourceKey\0sourceRef`，与 [_completedKey] 同口径）：
  /// 用户在恢复装载完成前切歌时，[position] 不再返回旧曲的乐观值。
  String? _restorePositionKey;

  /// 恢复装载完成/接管/失败时收口乐观位置。
  void _clearRestorePosition() {
    _restorePositionMs = null;
    _restorePositionKey = null;
  }

  /// 音量梯度引擎：16ms 周期单定时器（淡入/淡出共用一条梯度，cancel 即打断）。
  Timer? _fadeTimer;

  /// pending-pause 意图位：true = 已请求暂停、实际 pause() 尚未执行（淡出进行中）。
  /// 对外经 [playing] getter 表达为目标态「已暂停」；provider 内部对**实际**播放
  /// 状态的判断（睡眠定时/断点保存/切歌复位/toggle 分支等）一律直引
  /// `player.playing`，不经此位。
  bool _fadingPause = false;

  /// 挂起中的 [_fadeOutThenPause] 的收口器：实际暂停完成**或渐变被取消**
  /// （切歌/停止/重建/反向打断）时 complete，保证 await 方不悬挂。
  Completer<void>? _fadeOutCompleter;
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

  /// 睡眠定时最终收口：先读退出开关再清定时（清空会复位该位）。
  /// [advance] 为 true 表示停止恰好落在曲末：按当前播放模式预切到下一首并暂停
  /// （无下一首则原地暂停）；否则在当前进度原地暂停。
  /// 「播放结束退出软件」为开则先落库断点再退进程。
  void _sleepStop({bool advance = false}) {
    final exitApp = _sleepExitApp;
    _clearSleep();
    if (exitApp) {
      unawaited(advance ? _advancePausedThenQuit() : _quitAfterSleep());
    } else if (advance) {
      unawaited(_advancePausedForSleep());
    } else {
      unawaited(_pauseNowForSleep());
    }
  }

  /// 「播放结束退出软件」：先走正常停机（落库断点/停播放器），再走退出
  /// 收口（鸿蒙侧销毁播控卡/停长时任务，见 app_background）后退进程。
  Future<void> _quitAfterSleep() async {
    await shutdown();
    await exitAppGracefully();
  }

  Future<void> _pauseNowForSleep() async {
    if (player.playing) await _fadeOutThenPause();
    notifyListeners();
    _syncSystemMedia();
  }

  /// 曲末预切：装载下一首后立即暂停（位置 0，不发声）。
  /// 无下一首时 [_advance] 自行走 [_finishQueue] 原地暂停；坏歌仍按自动链路
  /// 跳过（透传 play=false，跳歌同样不发声）。
  Future<void> _advancePausedForSleep() async {
    await _advance(play: false, autoAdvanceOnFailure: true);
    notifyListeners();
    _syncSystemMedia();
  }

  /// 曲末预切后退软件：断点落在下一首 0 处，再走正常停机，最后经退出
  /// 收口（鸿蒙侧销毁播控卡/停长时任务）退进程。
  Future<void> _advancePausedThenQuit() async {
    await _advance(play: false, autoAdvanceOnFailure: true);
    await shutdown();
    await exitAppGracefully();
  }

  /// 曲目自然播放结束时被调用：返回 true 表示由睡眠定时接管（不再自动切歌）。
  bool _handleTrackCompletedSleep() {
    if (_sleepPendingStop) {
      _sleepStop(advance: true);
      return true;
    }
    final kind = _sleepKind;
    if (kind == SleepTimerKind.count) {
      if (_sleepCountLeft > 0) _sleepCountLeft--;
      if (_sleepCountLeft <= 0) {
        _sleepStop(advance: true);
        return true;
      }
      notifyListeners();
      return false;
    }
    if (kind == SleepTimerKind.endOfList &&
        _idx == _queue.length - 1 &&
        _current != null) {
      // 列表结尾：语义即「播到列表末尾停」，没有下一首，原地暂停。
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
      // Android 上让 ExoPlayer 自带请求头（setDefaultRequestProperties），
      // 绕开 just_audio 的 Dart 回环代理。该代理用自己的 HttpClient，不认
      // 我们的「允许自签」开关，故自签 NAS（https + 权威 CA 不认的证书）
      // 走代理必然 TLS 失败——扫描/探测都好好的，一到播放就报错。
      // 顺带好处：原生 Range/seek 比代理转发的自建字节流更稳。
      // Android（ExoPlayer）与鸿蒙（AVPlayer）都能原生发请求头：前者走
      // setDefaultRequestProperties，后者走 setMediaSource(headers)
      // （见 just_audio_avplayer.dart）。
      // 其余平台（桌面 mpv）仍依赖代理转发，不能一起关。
      useProxyForRequestHeaders: !_nativeRequestHeadersSupported,
      audioPipeline: _eq != null
          ? AudioPipeline(androidAudioEffects: [_eq!])
          : null,
    );
  }

  /// 当前平台能否由原生播放器直接发送请求头（不经过 just_audio 的 Dart 代理）。
  /// Android=ExoPlayer；鸿蒙=AVPlayer（`setMediaSource(url, headers)`）。鸿蒙上那个回环代理
  /// 会在 fork 引擎主 isolate 死锁/空转（2026-10-12 播放卡死根因），必须绕开。
  static bool get _nativeRequestHeadersSupported =>
      !kIsWeb && (Platform.isAndroid || isOhos);

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
      // 清理路径：取消渐变的同时收口挂起的淡出 Future（不暂停）+ 复位意图位。
      _cancelFadeAndComplete();
      _fadingPause = false;
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
      // 播放门控同步引擎：后台播放中仍同步，暂停/停止回落到前台门控。
      _onPlayingChanged?.call(st.playing);
      final playingChanged = st.playing != _lastPlayerStatePlaying;
      _lastPlayerStatePlaying = st.playing;
      // 暂停/停止：结清当前挂钟窗口（positionStream 停止跳动，不再有 tick）。
      if (!st.playing) {
        unawaited(_playSecStop());
        // 鸿蒙焦点抢占的最终断点：正常用户暂停由 toggle/notifier 自己落，
        // 这里只收口焦点路径，避免在 _play 换曲时的“先 pause 再 load”
        // 用旧曲位置写新曲断点。
        if (_audioFocusSavePending) {
          _audioFocusSavePending = false;
          if (st.processingState == ProcessingState.ready) {
            _saveForcedAndPoke();
          }
        }
      }
      if (playingChanged && !_disposed) {
        // Android just_audio 因音频焦点自动 pause 时 playing 会变，但此前
        // 没有 notifyListeners，按钮图标/播放态文案滞留在“播放中”。
        notifyListeners();
        _syncSystemMedia();
      }
      if (st.processingState != ProcessingState.completed) return;
      // 到点暂停会把 playing 置 false 并再发一次 completed：
      // 这种「已暂停」的完成事件不再处理，否则暂停后又被自动切歌。
      if (!st.playing) return;
      final finished = _current;
      if (finished == null) return;
      // 同一首歌的 completed 事件兜底去重。
      final key = _positionKeyOf(finished);
      if (_completedKey == key) return;
      _completedKey = key;
      _emitWeight(finished, completed: true,
          position: player.duration ?? Duration.zero);
      if (_handleTrackCompletedSleep()) return;
      _advance(autoAdvanceOnFailure: true);
    });
    // 播放时长采集挂在这里：位置流在播放中持续跳动，暂停/停止时停止。
    p.positionStream.listen((pos) {
      // 直播转码态：流内位置叠加服务端偏移才是绝对位置（断点/权重同口径）。
      final abs = (_liveTranscode && _transcodeStartSec > 0)
          ? pos + Duration(milliseconds: _transcodeOffsetMs)
          : pos;
      _maybeSaveState(abs);
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

  /// 歌曲身份 key（`sourceKey\0sourceRef`）：completed 去重与乐观位置归属共用。
  static String _positionKeyOf(Song s) => '${s.sourceKey}\u0000${s.sourceRef}';

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

  /// 装载看门狗：原生装载器（ohos AVPlayer、桌面 mpv）对「主机不可达/
  /// 无响应」的 open 可能没有应用层超时——历史实测（mdk）IPv6 路由丢失时
  /// prepare 永久挂起，UI 卡 00:00/00:00、点播放无响应（2026-09-30）。
  /// AVPlayer 自带 15s 网络超时，本看门狗仍作兜底。
  /// 超时后交 [loadBackoff] 退避重试，重试耗尽走既有装载失败提示/跳曲。
  /// ExoPlayer 自带连接超时通常先于此报错（对 Android 无感）。
  static const Duration _loadUrlTimeout = Duration(seconds: 15);

  /// 装载前探针看门狗：[MusicSource.probe] 的 HttpClient 只有 15s 连接超时，
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
  Future<(MusicSource, int)> debugLoadDirect(Song s, MusicSource src,
          {required bool Function() alive}) =>
      _playDirect(s, src, alive: alive);

  /// 测试入口：把断点节流时钟拨老（模拟「距上次入队 >25s」），验证节流
  /// 过期后暂停态原样补写仍不回推（无变化不刷 occurred_at 的回归防线）。
  @visibleForTesting
  void debugAgeBreakpointThrottle(Duration age) {
    _lastBpAtMs = DateTime.now().millisecondsSinceEpoch - age.inMilliseconds;
  }

  // ---------- 任务被划掉（Android 通知栏路径） ----------

  /// 已 dispose：生命周期回调可能晚于释放，迟到的通知栏/生命周期事件要挡住。
  bool _disposed = false;

  /// 任务被划掉（Android 通知栏路径）：停止播放但**保留断点/队列**。
  ///
  /// 之前这里走 `stopFromNotifier()`（会清断点），导致划掉/退出后再进入是空队列
  /// 重新从头播放（改进.txt 修复项）。划掉任务只是结束可见 Activity，用户没说要
  /// 丢掉进度——下次启动由断点恢复接回队列（受 resumeOnStartup 开关控制）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_disposed || _shuttingDown) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 退到后台（后台播放照常继续），但先把在途的本地累计/落库结清：
        // Android 常在进程被杀时根本不给 detached，这段就白丢了；同时把写隔离
        // 里攒的批量落盘，别指望它在后台还能按时刷。
        // 必须等待断点落盘：避免进程被 LMK/Doze 在写入完成前杀掉导致断点丢失。
        // 播放时长先结清（含强制推送），再冲写隔离，保证 outbox 事件不丢。
        await _playSecStop();
        await _flushWritesQuietly();
        break;
      case AppLifecycleState.resumed:
        // 回前台：对账播放时长窗口（后台被节流后位置流可能停过），
        // 并补写断点。注意 [playing]/[position] 都会构造播放器，所以先看有没有
        // 播放现场——冷启动时不该为了这两个值把 AudioPlayer 建出来。
        if (_hasPlayScene) {
          _playSecReconcile(playing: playing);
          unawaited(_saveStateNow());
        }
        break;
      case AppLifecycleState.detached:
        _onDetached();
      case AppLifecycleState.inactive:
        // 短暂失去焦点（通知栏下拉、来电、多任务切换）：播放与累计都不该被打断。
        break;
    }
  }

  /// 有没有可持久化的播放现场（没有就别去碰 [player]——那会为了读一个 position
  /// 把播放器构造出来，冷启动时纯属白做）。
  bool get _hasPlayScene => _queue.isNotEmpty && _current != null;

  /// 落库待结算的播放时长与断点，失败只记日志（生命周期回调不该抛）。
  Future<void> _flushWritesQuietly() async {
    final idx = _index;
    if (idx == null) return;
    try {
      await idx.flushWrites();
      if (_hasPlayScene) await _saveState(position);
    } catch (e) {
      debugPrint('[play] 退后台落库失败（忽略）: $e');
    }
  }

  /// 回前台：强制写一次断点（跳过 [_maybeSaveState] 的 [_stateSaveInterval] 节流）。
  Future<void> _saveStateNow() async {
    if (!_hasPlayScene) return;
    try {
      await _saveState(position);
    } catch (e) {
      debugPrint('[play] 回前台写断点失败（忽略）: $e');
    }
  }

  /// 任务被划掉：按媒体应用惯例停止播放，但保留断点/队列供下次启动续播。
  void _onDetached() {
    if (kIsWeb || !Platform.isAndroid) return;
    // 不再按 notificationControls 分流：前台服务恒注册（见 main.dart）。
    debugPrint('[play] 任务被划掉，停止播放（保留断点）');
    unawaited(stopFromNotifier(clearResume: false));
  }

  // ---------- 下一首预载/预读（由 DirectSourceManager 的优先级队列统一调度） ----------

  /// 「下一首」：当前播放模式下接下来会是谁。预载与预读都按它来，
  /// 不能另采一次随机样本，否则预载会落到不会播的那首。
  ///
  /// 单曲循环没有下一首（播放器里已有缓冲，也没有不同的歌要准备）。
  Song? get nextUpSong => _mode == PlayMode.loopOne ? null : peekNext();

  /// 「当前曲元数据/封面」排进直连任务队列（最高优先级，接线见 main.dart）。
  /// 未接线时退回裸并发执行（单测与未接 manager 的场景）。
  void Function(String key, Future<void> Function() body)? _submitCurrentMeta;

  /// 下一首变了（插队/删曲/切模式）：通知外部重排下一两级任务。
  void Function(Song? next)? _onNextChanged;

  /// 与当前转码设置一致的变体缓存路径（无则 null）：由 DirectSourceManager
  /// 按当前码率/响度查变体缓存（接线见 main.dart）。未接线时按无变体处理。
  Future<String?> Function(MusicSource src, Song s)? _resolveTranscodeCache;

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
      // 清理路径：取消渐变 + 收口挂起的淡出 Future（不暂停）+ 复位意图位。
      _cancelFadeAndComplete();
      _fadingPause = false;
      await _disposePlayer();
      _buildAndWire();
      notifyListeners();
      return;
    }
    final pos = position;
    final wasPlaying = player.playing;
    final current = _current!;
    final source = _curSource;
    // 清理路径：同上——重建期间旧渐变作废，挂起的淡出 Future 解挂。
    _cancelFadeAndComplete();
    _fadingPause = false;
    await _disposePlayer();
    _buildAndWire();
    await _play(current, source: source, play: wasPlaying);
    // 直播转码态走分支 seek（带偏移重载），其余原生 seek。
    try {
      await seek(pos);
    } catch (_) {}
    notifyListeners();
  }

  /// 播放链路/转码设置变化后重载当前曲（直连↔代理、码率、响度均衡即时生效，无需重启）。
  ///
  /// 语义：
  /// - 保位置/保播放态：暂停态重载后仍暂停，播放态重载后从原位置继续；
  /// - 不碰队列/深层历史/睡眠定时/权重手动标记（与 [_play] 全量起播不同，
  ///   这里只换音频源，不视为一次新的播放）；
  /// - 已缓存歌曲恒播本地原文件（缓存优先，见 [_loadOnce]），链路/转码变化
  ///   对它无影响，直接返回 false 跳过重载，避免无谓打断；
  /// - 无当前曲或播放器未建时返回 false。
  ///
  /// 返回 true=已重载，false=跳过（无当前曲/未建播放器/已缓存/无源）。
  Future<bool> reloadCurrentForPlaybackRoute() async {
    final cur = _current;
    if (cur == null || _player == null || _shuttingDown || _disposed) {
      return false;
    }
    // 经 resolver 取最新源（含编辑后的新 route），并同步 _curSource，
    // 使后续切歌也走新链路（即使本次因缓存跳过重载）。
    final fresh = _resolver?.call(cur.sourceKey) ?? _curSource;
    if (fresh == null) return false;
    _curSource = fresh;
    // 缓存优先：已缓存恒播本地原文件，链路/转码变化不影响本次播放，无需重载。
    try {
      final cached = await fresh.cachedFilePath(cur);
      if (cached != null) return false;
    } catch (_) {
      // 查缓存失败按未缓存处理，继续重载。
    }
    final pos = position;
    final wasPlaying = player.playing && !_fadingPause;
    // 重载期间旧渐变作废，与 _play/applyAudioConfig 同口径。
    _cancelFadeAndComplete();
    _fadingPause = false;
    final token = ++_playToken;
    bool alive() => token == _playToken;
    try {
      // 保位置：把绝对位置当作转码偏移透给装载（命中变体则本地 seek，
      // 命中转码流则服务端 start_sec；直连/字节流装载后仍需原生 seek）。
      final (used, line) = await _playDirect(cur, fresh,
          alive: alive, startSec: pos.inMilliseconds / 1000.0);
      if (!alive()) return false;
      _curSource = used;
      _curLine = line;
      _loadFailStreak = 0;
      if (wasPlaying) {
        // 与 _play 同口径：自然播完时 playing 不复位，直接 play() 会空转，
        // 先复位再播，避免自动切歌无声。
        if (player.playing) {
          try {
            await player.pause();
          } catch (_) {}
        }
        unawaited(player.play().catchError((Object e) {
          if (!alive() || _shuttingDown) return;
          debugPrint('[play] 重载后 play 异常《${cur.title}》: $e');
        }));
        _fadeIn();
      } else if (player.playing) {
        try {
          await player.pause();
        } catch (_) {}
      }
      if (!alive()) return false;
      // 直播转码流已从偏移处起播（变体命中亦已本地 seek），无需再 seek；
      // 其余链路（直连/字节流）仍需原生 seek 回原位置。
      if (!_liveTranscode) {
        try {
          await player.seek(pos);
        } catch (_) {}
      }
      _saveState(player.position);
      notifyListeners();
      _syncSystemMedia();
      return true;
    } catch (e) {
      if (!alive()) return false;
      debugPrint('[play] 重载当前曲失败《${cur.title}》: $e');
      return false;
    }
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

  /// 平台音量调用：异常一律静默（headless 测试环境的 MissingPluginException、
  /// 播放器重建后的迟到写等），渐变状态机不因平台侧失败而中断。
  void _setVolumeSafe(double v) {
    try {
      unawaited(player.setVolume(v).catchError((Object e) {
        // 静默：见上。
      }));
    } catch (_) {
      // setVolume 同步抛出同样静默。
    }
  }

  /// 平台暂停调用：异常静默（理由同 [_setVolumeSafe]）。
  Future<void> _pauseSafe() async {
    try {
      await player.pause();
    } catch (_) {}
  }

  /// 取消进行中的音量梯度（渐变被切歌/停止/重建/反向打断接管时调用）。
  /// 只停梯度本身，不执行任何暂停/复位副作用。
  void _cancelFade() {
    _fadeTimer?.cancel();
    _fadeTimer = null;
  }

  /// 取消渐变并收口挂起的淡出 Future（不执行暂停）：
  /// [_fadeOutThenPause] 的 await 方在渐变被接管时靠这里解挂，不悬挂。
  void _cancelFadeAndComplete() {
    _cancelFade();
    final c = _fadeOutCompleter;
    if (c != null) {
      _fadeOutCompleter = null;
      if (!c.isCompleted) c.complete();
    }
  }

  /// 统一音量梯度引擎：16ms 周期单定时器，把音量从 `player.volume` **当前值**
  /// 线性推到 [to]（淡入=1.0 / 淡出=0.0），走完触发 [onDone]。
  ///
  /// - 一律从当前音量出发：反向打断时自然形成「从当前音量平滑过渡」，
  ///   不出现音量跳变（淡出若预设 setVolume(1.0)，打断回播瞬间会爆音）；
  /// - 进度按 tick 步进（每 16ms 走 16/duration），单定时器天然可 cancel；
  /// - 新梯度启动前先取消旧梯度（同一时刻至多一条活跃渐变）。
  void _startFade({
    required double to,
    required Duration duration,
    VoidCallback? onDone,
  }) {
    _cancelFade();
    if (duration <= Duration.zero) {
      _setVolumeSafe(to);
      onDone?.call();
      return;
    }
    final from = player.volume;
    final step = 16 / duration.inMilliseconds; // 每 tick（16ms）的进度增量
    var p = 0.0;
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      p += step;
      if (p >= 1.0) p = 1.0;
      _setVolumeSafe(from + (to - from) * p);
      if (p >= 1.0) {
        t.cancel();
        if (identical(_fadeTimer, t)) _fadeTimer = null;
        onDone?.call();
      }
    });
  }

  /// 淡入：音量渐变回升到 1.0（关闭时直接置 1）。
  ///
  /// [fromZero] 为 true（默认）：从真实暂停恢复——先归零再渐升，维持既有听感；
  /// false：淡出中被反向打断回播——从当前音量平滑回升（引擎还在播，无需重调
  /// play()）。
  void _fadeIn({bool fromZero = true}) {
    _cancelFade();
    if (!_fadeOn) {
      _setVolumeSafe(1.0);
      return;
    }
    if (fromZero) _setVolumeSafe(0.0);
    _startFade(to: 1.0, duration: _fadeDuration);
  }

  /// 淡出后真正暂停（关闭淡入淡出时直接暂停）。
  ///
  /// 返回的 Future 到**实际暂停完成**时才完成（睡眠定时/通知栏暂停依赖此
  /// 语义）；渐变被清理路径（切歌/停止/退出/重建）或反向打断取消时，Future
  /// 同样会完成——但**不**执行暂停，由接管方决定后续状态。
  Future<void> _fadeOutThenPause() async {
    // 启动恢复期已有待播放目标时，主动暂停直接取消它；恢复尾看到 false
    // 就不会再补一次 play。
    if (_restoreResumeTarget != null) _restoreResumeTarget = false;
    // 用户/守卫/通知栏/睡眠/写盘等主动暂停：取消“焦点暂停后自动续播”意图。
    // 焦点抢占本身不经过这里（原生桥已暂停），故不会误清标记。
    _audioFocusPaused = false;
    _audioFocusSavePending = false;
    if (!_fadeOn) {
      // 直接暂停路径同样复位意图位：淡出进行中把开关关掉后再暂停，不能让
      // pending-pause 标志卡死（否则 playing 目标态恒为已暂停）。
      _fadingPause = false;
      await _pauseSafe();
      return;
    }
    _cancelFadeAndComplete();
    _fadingPause = true;
    final completer = Completer<void>();
    _fadeOutCompleter = completer;
    _startFade(
      to: 0.0,
      duration: _fadeDuration,
      onDone: () async {
        await _pauseSafe();
        // 仅当本回调仍是活跃的淡出收尾时才做复位：收尾窗口被新的渐变/
        // 恢复/重入淡出接管时（[_fadeOutCompleter] 已被收口或替换），
        // 迟到的音量/意图位复位会破坏接管的渐变（跳变、目标态错乱）。
        if (identical(_fadeOutCompleter, completer)) {
          if (_fadeTimer == null) _setVolumeSafe(1.0);
          _fadingPause = false;
        }
        _completeFadeOut(completer);
      },
    );
    return completer.future;
  }

  /// 收口挂起的淡出 Future（暂停完成或渐变被取消都走这里）。
  void _completeFadeOut(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
    if (identical(_fadeOutCompleter, completer)) _fadeOutCompleter = null;
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
    void Function(Song? next)? onNextChanged,
    void Function(String key, Future<void> Function() body)? submitCurrentMeta,
    Future<String?> Function(MusicSource src, Song s)? resolveTranscodeCache,
  }) {
    _index = index;
    _weight = weight;
    _onTrackStarted = onTrackStarted;
    _onSongMetaRefreshed = onSongMetaRefreshed;
    _onNextChanged = onNextChanged;
    _submitCurrentMeta = submitCurrentMeta;
    _resolveTranscodeCache = resolveTranscodeCache;
  }

  /// 播放器实例，**首次使用时才构造**。
  ///
  /// 构造 PlayerProvider 时 [attachAppSettings] 还没调用，若此时建播放器，
  /// 音频焦点/均衡器只能读到默认值——「忽略音频焦点」冷启动永远失效，必须进
  /// 设置页手动切一次开关才生效。延迟构造保证第一次建时就拿到真实设置。
  AudioPlayer get player => _player ??= _buildAndWire();

  AudioPlayer _buildAndWire() {
    // 重建播放器即放弃旧的焦点暂停意图，避免旧实例的 RESUME 事件误触发。
    _audioFocusPaused = false;
    _audioFocusSavePending = false;
    final p = _buildPlayer();
    _lastPlayerStatePlaying = p.playing;
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
      unawaited(_playSecStop());
      return;
    }
    if (_playSecSong == null || !_same(_playSecSong!, s)) {
      unawaited(_playSecFlush(forcePush: true)); // 换歌：先结清上一首并强制推送
      _playSecSong = s;
    }
    final win = _playSecWindow ??= DateTime.now();
    final r = settlePlaySecWindow(win, DateTime.now());
    if (r.sec > 0) {
      _playSecPending += r.sec;
      _playSecWindow = r.window;
      if (_playSecPending >= _playSecFlushAt) unawaited(_playSecFlush());
    }
  }

  /// 暂停/停止/退出：结清窗口并立即落库 + 强制推送播放时长。
  Future<void> _playSecStop() async {
    final win = _playSecWindow;
    if (win != null) {
      final r = settlePlaySecWindow(win, DateTime.now());
      _playSecPending += r.sec;
      _playSecWindow = null;
    }
    await _playSecFlush(forcePush: true);
  }

  /// 落库待结算秒数 + 节流推送 `song.state`（5 分钟心跳，暂停/切歌/退出强制）。
  /// 播放次数由时长派生，无需单独同步。
  Future<void> _playSecFlush({bool forcePush = false}) async {
    final s = _playSecSong;
    final sec = _playSecPending;
    final w = _weight;
    if (s == null || sec <= 0 || w == null) return;
    _playSecPending = 0;
    try {
      await w.addPlaySec(s, sec);
      await w.syncPlaySec(s, force: forcePush);
    } catch (_) {
      // 落库/入队失败静默：下次 flush 重试，不打断播放。
    }
  }

  /// 关联用户设置：套用默认播放模式（settings.md §3.2 `play_mode_default`），
  /// 之后每次切模式写回。顺带校正播放器构造时读到的音频配置（冷启动）。
  void attachAppSettings(AppSettings settings) {
    _appSettings = settings;
    final m = PlayModeParse.fromStored(settings.playModeDefault);
    if (_mode != m) _mode = m;
    _applyAudioConfigIfNeeded();
    refreshPlaybackGuard();
  }

  /// 装配静音/断连暂停守卫（main 注入 `AudioGuardPlatform.forCurrentPlatform()`；
  /// Android/鸿蒙为原生通道实现，其余平台为 no-op，行为不变）。装配后立即按当前开关同步订阅。
  void attachAudioGuard(AudioGuardPlatform platform) {
    _playbackGuard?.dispose();
    _playbackGuard = PlaybackGuard(
      platform: platform,
      volumePauseEnabled: () => _appSettings?.pauseOnZeroVolume ?? false,
      disconnectPauseEnabled: () => _appSettings?.pauseOnDeviceDisconnect ?? false,
      isPlaying: () => _player?.playing ?? false,
      onPause: pauseByGuard,
    );
    _playbackGuard!.refresh();
  }

  /// 设置开关变动后同步守卫订阅（开启则订阅原生信号，全关则注销）。
  void refreshPlaybackGuard() => _playbackGuard?.refresh();

  /// 装配音频焦点事件源（main 注入 `AudioFocusPlatform.forCurrentPlatform()`）。
  ///
  /// Android 的 just_audio 已自行处理焦点，事件流为空；鸿蒙 AVPlayer 必须
  /// 由应用在 audioInterrupt 回调里暂停并同步状态，这里负责 UI/断点收口与
  /// 按 `audio_focus_enabled` 自动续播。
  void attachAudioFocus(AudioFocusPlatform platform) {
    unawaited(_audioFocusSub?.cancel());
    _audioFocusSub = platform.events.listen(
      _onAudioFocusEvent,
      onError: (Object e) => debugPrint('[play] 音频焦点事件流错误（忽略）：$e'),
    );
  }

  void _onAudioFocusEvent(AudioFocusEvent e) {
    if (_shuttingDown || _disposed) return;
    switch (e.type) {
      case AudioFocusEventType.pause:
        if (!e.wasPlaying) return;
        // 用户刚点了暂停、淡出收尾尚未完成时，系统焦点中断不应在恢复时
        // 抢回播放：是否自动续播只由用户最后一次明确意图决定。
        _audioFocusPaused = !_fadingPause;
        final p = _player;
        if (p == null || !p.playing) {
          // 原生暂停/适配层 playing=false 已先到：position 已是原生停顿点，
          // 直接落最终断点；UI 与系统媒体由随后的状态流刷新。
          _finishAudioFocusPause();
        } else {
          _audioFocusSavePending = true;
        }
        notifyListeners();
        break;
      case AudioFocusEventType.resume:
        if (!_audioFocusPaused) return;
        _audioFocusPaused = false;
        if (_appSettings?.audioFocusEnabled ?? true) {
          unawaited(_resumeFromAudioFocus());
        }
        break;
      case AudioFocusEventType.stop:
        // 永久失去焦点：不自动恢复，用户可手动继续；断点仍要收口。
        _audioFocusPaused = false;
        if (!e.wasPlaying) return;
        final p = _player;
        if (p == null || !p.playing) {
          _finishAudioFocusPause();
        } else {
          _audioFocusSavePending = true;
        }
        break;
    }
  }

  void _finishAudioFocusPause() {
    _audioFocusSavePending = false;
    final p = _player;
    // 只在“可续播的暂停”上落断点：stop()/idle 的暂停位置恒为 0，写入会
    // 覆盖已有断点（与状态流里的 ready 限定保持同一口径）。
    if (p != null && p.processingState == ProcessingState.ready) {
      _saveForcedAndPoke();
    }
  }

  Future<void> _resumeFromAudioFocus() async {
    if (_shuttingDown || _disposed) return;
    final p = _player;
    if (p == null || p.playing) return;
    // 焦点暂停期间可能有挂起的淡出 Future（用户刚点暂停又切走）：先收口，
    // 避免恢复后迟到的淡出回调把音量/意图位复位。
    _cancelFadeAndComplete();
    _fadingPause = false;
    // 焦点恢复也是明确的播放意图：覆盖恢复期被连点取消的目标态。
    if (_restoreFuture != null) _restoreResumeTarget = true;
    await _resumeOrReplay();
    if (_disposed || _shuttingDown) return;
    notifyListeners();
    _syncSystemMedia();
    _onSyncPoke?.call();
  }

  /// 静音/断连守卫请求暂停：仅在**实际正在播放**且未在淡出暂停中时执行，
  /// 走与通知栏暂停同一路径（含淡出），并标记用户接管以阻止迟到的远端镜像回切。
  Future<void> pauseByGuard() async {
    final p = _player;
    if (p == null || _shuttingDown || _disposed) return;
    if (_fadingPause || !p.playing) return;
    _userTookOver = true;
    await _fadeOutThenPause();
    notifyListeners();
    _syncSystemMedia();
    _saveForcedAndPoke();
  }

  /// 文件写盘/上传前暂停（嵌入等外部写操作调用）：走与暂停同一路径（含
  /// 淡出），并**等待引擎实际暂停完成后**才返回，保证写盘时无人读文件。
  ///
  /// 返回 true 表示本次调用把播放暂停了（调用方写完后应恢复播放）；
  /// 未在播 / 用户刚点的暂停仍在收尾 → 返回 false（不接管、不替用户恢复）。
  Future<bool> pauseForFileWrite() async {
    final p = _player;
    if (p == null || _shuttingDown || _disposed) return false;
    if (_fadingPause) {
      // 淡出在途：等实际暂停落地再放行写盘，但不接管恢复。
      final f = _fadeOutCompleter?.future;
      if (f != null) {
        try {
          await f;
        } catch (_) {}
      }
      return false;
    }
    if (!p.playing) return false;
    _userTookOver = true;
    await _fadeOutThenPause();
    notifyListeners();
    _syncSystemMedia();
    _saveForcedAndPoke();
    return true;
  }

  /// 关联服务器可达性门控（main 注入 `direct.isServerAvailable`）：
  /// 直连歌曲断点仅在连着服务器时上报，避免未配对用户 outbox 积压。
  void attachServerAvailable(bool Function() fn) {
    _serverAvailable = fn;
  }

  /// 同步引擎钩子（main 注入；未注入时播放不受影响）：
  /// - [onPlayingChanged]：实际播放态（播放状态流驱动，含自动续播/守卫全路径），
  ///   供 SyncEngine 做“后台播放中仍同步”门控；
  /// - [onSyncPoke]：播放/暂停/切歌后的即时同步（单飞合并，不断网锤）。
  void Function(bool playing)? _onPlayingChanged;
  void Function()? _onSyncPoke;
  void attachSyncHooks({
    void Function(bool playing)? onPlayingChanged,
    void Function()? onSyncPoke,
  }) {
    _onPlayingChanged = onPlayingChanged;
    _onSyncPoke = onSyncPoke;
  }

  /// 切歌后的即时同步：断点先落 outbox，再 poke（保证本轮 push 能带走新事件）。
  void _pokeSyncAfterSave(Future<void> Function() save) {
    final poke = _onSyncPoke;
    if (poke == null) return;
    unawaited(save().then((_) => poke()));
  }

  List<Song> get queue => List.unmodifiable(_queue);
  Song? get current => _current;

  /// 当前曲在运行时队列中的下标（面板/队列页高亮与定位用）：
  /// 按下标比较，融合队列里的同首复本不会两行同亮（[isCurrent] 按身份，
  /// 复本行都会亮）。[_idx] 恒被钳在队内；空队时为 0（调用方自行判空）。
  int get currentIndex => _idx;
  bool get hasCurrent => _current != null;
  /// 展示用当前位置：断点恢复的乐观值（[_restorePositionMs]）在装载/seek 完成前
  /// 优先——首帧进度条即停在上次位置；之后与真实播放器位置一致。
  /// 归属校验：中途切到别的歌（恢复装载期用户点播/切歌）时自动失效，不用
  /// 逐个接管点位手动清理。
  Duration get position {
    final r = _restorePositionMs;
    final c = _current;
    if (r != null &&
        c != null &&
        _restorePositionKey == _positionKeyOf(c)) {
      return Duration(milliseconds: r);
    }
    final base = player.position;
    // 直播转码流：播放器位置从流起点（偏移处）计，展示需叠加服务端 start_sec。
    if (_liveTranscode && _transcodeStartSec > 0) {
      return base + Duration(milliseconds: _transcodeOffsetMs);
    }
    return base;
  }

  /// 展示用总时长：播放器未装载出真实时长时，回退到当前歌曲元数据时长
  /// （[Song.duration] 为秒）——首帧即有正确的总时长，不再显示 0:00/0:00。
  Duration? get duration {
    final loaded = _player?.duration;
    if (loaded != null) return loaded;
    final sec = _current?.duration;
    return sec == null ? null : Duration(seconds: sec);
  }
  /// 界面/目标播放态：淡出暂停进行中（pending-pause，[_fadingPause]）时提前
  /// 翻转为 false——播放/暂停按钮点击后一帧内响应目标意图，不等音频淡出完成；
  /// 启动恢复等待期返回 [_restoreResumeTarget]（连点后的待应用目标态）；
  /// 其余渐变之外的任意时刻与实际播放状态一致。
  ///
  /// provider 内部对**实际**播放状态的判断（睡眠定时、断点保存、切歌复位、
  /// [toggle] 分支等）不经此 getter，一律直引 `player.playing`。
  bool get playing {
    if (_fadingPause) return false;
    final restoreTarget = _restoreResumeTarget;
    if (restoreTarget != null) return restoreTarget;
    return player.playing;
  }
  PlayMode get mode => _mode;

  /// 是否为当前播放曲（按 sourceKey + sourceRef，避免多源 id 碰撞）。
  bool isCurrent(Song s) {
    final c = _current;
    return c != null && _same(c, s);
  }

  /// 按「歌曲标题显示格式」格式化（通知栏等无 BuildContext 场景）。
  String displayTitle(Song s) => formatSongTitleWith(s, _appSettings);

  /// 当前歌曲权重因子（无存储时为空；用于播放页展示，可选）。
  /// 展示口径与抽样一致：「不喜欢」锁定态显示 0.1（[SongWeightStore.dislikedFactor]）。
  double? get currentWeightFactor {
    final s = _current;
    final w = _weight;
    if (s == null || w == null) return null;
    return w.effectiveFactorOf(s);
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
  /// - 手动点播一律替换深层末尾（不增长）：首个列表即锚定并建融合队列；
  ///   同锚定键点歌 / 其它列表点歌都不切 base、不重建队列，仅换尾；
  /// - 自动推进（自然播完 / 失败跳歌 / 加权抽样 / 删当前曲续播 / 断点恢复）
  ///   才推入深层末尾；
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
      // 远端断点更新（歌曲+进度+深层列表）优先：起播前消费，整体委托
      // [_restoreFromMirror]（重建融合队列/套用镜像深层列表/暂停态装载+seek）。
      // 必须在 `_play` **之前**比较：`_play` 的 `_saveState` 会把本地
      // play_state.updated_at 刷成 now，令远端镜像恒判更旧（打开歌单续播失效）。
      if (resumeFromBreakpoint && playlistUuid != null) {
        final idx = _index;
        final m = idx?.breakpointMirrorOf(playlistUuid);
        if (idx != null && m != null) {
          final local = idx.getPlayState();
          final localAt = (local != null && local.playlistUuid == playlistUuid)
              ? DateTime.tryParse(local.updatedAt)
              : null;
          final mAt = DateTime.tryParse(m.compareClock);
          if (mAt != null && (localAt == null || mAt.isAfter(localAt))) {
            if (await _restoreFromMirror(idx, m)) return;
          }
        }
      }
      final target = resolved[index.clamp(0, resolved.length - 1)];
      _idx = _fusedIndexOf(index.clamp(0, resolved.length - 1), resolved);
      _leaveFor(target);
      notifyListeners();
      await _play(target, source: source, fromPlaylist: false, manual: true);
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
      await _play(target, source: source, fromPlaylist: false, manual: true);
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
      await _play(target, source: source, fromPlaylist: false, manual: true);
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
    await _play(_queue[_idx], source: source, fromPlaylist: false, manual: true);
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
    _userTookOver = true;
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
    notifyListeners();
    _syncSystemMedia();
    _onNextChanged?.call(nextUpSong);
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
    // 清理路径：取消渐变 + 收口挂起的淡出 Future（不暂停）+ 复位意图位。
    _cancelFadeAndComplete();
    _fadingPause = false;
    _peekedNext = null;
    _onNextChanged?.call(null);
    _current = null;
    _curSource = null;
    _clearRestorePosition();
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
  /// 批量 IN 查询（非逐首 SELECT），启动恢复大队列不再 N+1 阻塞 UI。
  List<Song> _resolveLiveAll(List<Song> songs) {
    final idx = _index;
    if (idx == null || songs.isEmpty) return List<Song>.of(songs);
    return idx.resolveLiveSongs(songs);
  }

  /// 两列引用一致性（sourceKey+sourceRef 逐位）：供 mirror 复用基座判定（D），
  /// O(n) 纯内存比较，无 DB。长度先比对，基座被删歌等变更即失配走全量路径。
  bool _sameSongRefs(List<Song> a, List<Song> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_same(a[i], b[i])) return false;
    }
    return true;
  }

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

  /// 在线歌词保存后：若 [song] 正在播放，重载歌词展示。
  /// 非当前曲无需动作（下次播放时 `_loadLyrics` 会从索引读到新值）。
  void reloadLyricsIfCurrent(Song song) {
    final cur = _current;
    if (cur == null || !_same(cur, song)) return;
    unawaited(_loadLyrics(cur, _curSource));
  }

  /// [fromPlaylist]：true = 自动推进（推入深层末尾）；false = 手动点播
  /// （替换深层末尾，不增长）。调用方约定：playAt / playQueue 手动路径一律
  /// false；_advance / _playWeighted / 删当前曲续播 / 断点恢复一律 true。
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
    // 用户手动起播新曲：恢复期等待中的播放/暂停目标态作废，避免旧意图
    // 在恢复收尾后又对新曲补一次 play。恢复自身的 `_play(play:false)` 不能
    // 取消——用户可能在恢复的异步前缀期间已经点过播放。
    if (manual && _restoreResumeTarget != null) {
      _restoreResumeTarget = false;
    }
    // 新曲开始前清掉上一首的预取结果与 completed 去重标记。
    _peekedNext = null;
    _completedKey = null;
    // 切歌接管：上一首进行中的渐变与挂起的淡出作废——收口挂起 Future
    //（不暂停），意图位随本曲装载/起播重新确立。
    _cancelFadeAndComplete();
    _fadingPause = false;
    _audioFocusPaused = false;
    _audioFocusSavePending = false;
    // 上一首的预载/预读目标已作废（新曲装载成功后由 _onTrackStarted 重排）。
    _onNextChanged?.call(null);
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
      _curLine = 0;
      // 新曲装载前复位直播转码态（旧曲的偏移不得漏到新曲的位置展示里；
      // 实际链路由 _loadOnce 各成功分支重记）。
      _liveTranscode = false;
      _transcodeStartSec = 0;
      // 记录本次起始是否用户手动点播（改进.txt 功能7 完播判定用；任何新起始都会覆盖）。
      _startedManual = manual;
      // 用户主动起播 → 首轮同步晚到的远端断点不再回切。
      if (manual) {
        _userTookOver = true;
        // 恢复期的乐观位置随用户接管失效（当前曲将换成用户点的）。
        _clearRestorePosition();
        // 本机成为最新状态：远端旧断点不得再覆盖（基准=now）。
        // 注意仅用户起播时刷新；恢复装载（manual=false）不刷新，否则恢复时
        // `_saveState` 会把基准抬到现在，令远端更新的镜像永远套用不上。
        _breakpointBaselineAt = DateTime.now();
      }
      if (!_suppressSyncNotify) notifyListeners();
      if (src == null || !src.supportsDirect) {
        // 无本地源（如同步快照行且本机未配置对应源）：不崩，提示后由调用方决定。
        throw StateError('找不到该歌曲的播放源，请先配置对应播放源');
      }
      // 睡眠定时曲末预切（play=false）：装载前先暂停，避免 just_audio 因
      // playing 仍为 true（自然播完不复位）而在 setUrl 后自动续播下一首，
      // 从装载开始一路发声到暂停写回，漏出可闻的下一首片段。
      if (!play && player.playing) {
        try {
          await player.pause();
        } catch (_) {}
      }
      final (used, line) = await _playDirect(cur, src, alive: alive);
      if (!alive()) return; // 已被更新的切歌接管
      // Failover 成功：后续缓存/补读/歌词/预热一律走实际线路。
      _curSource = used;
      _curLine = line;
      if (line != 0) {
        AppToast.show('主源不可用，已切换到备用$line', isError: false);
      }
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
        // play() 的 Future 要到本曲播完/被暂停才 complete（just_audio 契约；
        // Android 插件把 playResult 延迟到 STATE_ENDED/pause 才回调）。不能
        // await：否则后面的 _syncSystemMedia()（驱动 audio_service 前台服务 +
        // 播放期 wake lock）、元数据补读、下一首预热全被推迟到曲末——后台播放
        // 期间没有前台服务/唤醒锁，息屏/Doze 下进程被冻结回收，表现为
        // 「放着放着就没声了」。错误仍按原 catch 的口径处理（toast/自动跳歌）。
        unawaited(player.play().catchError((Object e) {
          if (!alive() || _shuttingDown) return;
          debugPrint('[play] play 调用异常《${cur.title}》: $e');
          if (!autoAdvanceOnFailure) {
            AppToast.error(e, '播放失败');
          } else {
            unawaited(_autoSkipAfterFailure(e, play));
          }
        }));
        _fadeIn();
      } else if (player.playing) {
        // play=false 兜底：装载完成后若仍在发声（平台差异）立即暂停。
        await player.pause();
      }
      if (!alive()) return;
      unawaited(_applyEqualizerBands());
      // 切歌即时同步：断点先落 outbox 再 poke（自动续播/手动点播同一路径）。
      _pokeSyncAfterSave(() => _saveState(position));
      // 深层列表维护：歌单内播放推入末尾；外部点歌替换末尾。
      _trackDeepList(cur, push: fromPlaylist);
      _onTrackStarted?.call(_curSource ?? src, cur);
      // 播放即重读当前歌曲元数据（不管之前是否读过，保证展示最新）。
      // 走直连任务队列：它必须抢在「下一首预载」和全库后台补读前面——
      // 界面上正显示着的那一行的标题/封面，比什么都急。
      final enrichSrc = _curSource ?? src;
      Future<void> enrichCurrent() => _enrichLazily(cur, enrichSrc);
      final submitMeta = _submitCurrentMeta;
      if (submitMeta != null) {
        submitMeta('${cur.sourceKey}\u0000${cur.sourceRef}', enrichCurrent);
      } else {
        unawaited(enrichCurrent());
      }
      unawaited(_loadLyrics(cur, enrichSrc));
      notifyListeners();
      _syncSystemMedia();
    } catch (e) {
      if (!alive()) return; // 旧切歌被接管后的 abort：静默丢弃
      debugPrint('[play] 装载失败《${s.title}》: $e');
      // 自动续播链路：后台切歌失败不逐首弹 toast（人不在屏幕前），跳下一首；
      // 连败到上限才提示。手动点播仍逐次提示。
      if (!autoAdvanceOnFailure) AppToast.error(e, '播放失败');
      notifyListeners();
      if (autoAdvanceOnFailure) unawaited(_autoSkipAfterFailure(e, play));
    }
  }

  /// 直连源装载（带退避重试 + 备用 Failover）：「切后台后还能播一两首、
  /// 播完静默停住」的主因是后台网络被回收/连接超时，失败后没有重试也没有
  /// 下一首兜底。重试会重建连接；主源耗尽后按线路候选自动试备用（同
  /// `sourceRef` 相对路径对应，跨类型亦可）；锁定线路时只走该路。
  /// [alive] 为假（已被更新的切歌接管）或正在退出时立即放弃，不再触碰播放器。
  /// 成功返回实际使用的 `(source, line)`，调用方据此更新 [_curSource]/[_curLine]。
  /// [startSec] 透传 [_loadOnce]（保位置重载用；首播/重试为 0）。
  Future<(MusicSource, int)> _playDirect(Song s, MusicSource src,
      {required bool Function() alive, double startSec = 0}) async {
    List<(MusicSource, int)> cands;
    try {
      cands = _candidates?.call(s.sourceKey) ?? [(src, 0)];
    } catch (_) {
      cands = [(src, 0)];
    }
    if (cands.isEmpty) cands = [(src, 0)];
    Object? last;
    for (var c = 0; c < cands.length; c++) {
      final (cand, line) = cands[c];
      final isLast = c == cands.length - 1;
      // 主线路（首候选）走完整退避；备用只单次尝试，避免 44s×3 的漫长卡死。
      final attempts = (c == 0 && cands.length > 1)
          ? loadBackoff.length + 1
          : (cands.length == 1 ? loadBackoff.length + 1 : 1);
      var probeUsable = true;
      for (var i = 0; i < attempts; i++) {
        if (!alive() || _shuttingDown) return (cand, line);
        if (i > 0) {
          final wait = loadBackoff[i - 1];
          debugPrint('[play] ${wait.inSeconds}s 后重试装载《${s.title}》');
          await Future.delayed(wait);
          if (!alive() || _shuttingDown) return (cand, line);
        }
        try {
          final injected = loadOverride;
          if (injected != null) {
            await injected(s, cand);
          } else {
            // 重试轮跳过转码（首轮已试过，见 _loadOnce.skipTranscode）。
            await _loadOnce(s, cand,
                probe: probeUsable, skipTranscode: i > 0, startSec: startSec);
          }
          if (c > 0) {
            final label = line == 0 ? '主源' : '备用$line';
            debugPrint('[play] 主源不可用，已切换到$label《${s.title}》');
            // toast 交给调用方（有 context 的是 _play 的 catch，这里只记日志；
            // 成功切换的提示在 _play 成功路径统一弹，避免 _loadOnce 内重复）。
          }
          return (cand, line);
        } catch (e) {
          if (e is PlayerInterruptedException) rethrow;
          // 鉴权被拒重试也不会好：单线路立即失败；多线路则继续试下一备。
          if (e is SourceAuthException && isLast) rethrow;
          if (e is SourceAuthException) {
            last = e;
            break;
          }
          last = e;
          if (probeTimedOut) {
            probeUsable = false;
            probeTimedOut = false;
          }
        }
      }
      if (!alive() || _shuttingDown) return (cand, line);
      if (!isLast) {
        debugPrint('[play] 线路${c == 0 ? '主源' : '备用$c'}失败，试下一线路《${s.title}》: $last');
      }
    }
    throw last ?? StateError('装载失败');
  }

  /// 本次 [_loadOnce] 探针是否以超时收场（供 [_playDirect] 决定后续尝试还做不做）。
  bool probeTimedOut = false;

  /// 当前播放是否为直播转码流（服务端无时长/不可 Range，见 S1）。
  /// 为 true 时展示/存档位置 = [_transcodeStartSec] + 播放器位置；
  /// seek 走带偏移重载（[_seekLiveTranscode]），不调原生 seek。
  bool _liveTranscode = false;

  /// 直播转码流的起始偏移（秒）：服务端 `start_sec`，首播/重载为 0。
  double _transcodeStartSec = 0;

  /// 偏移毫秒（position 叠加/positionStream 映射共用，避免重复换算）。
  int get _transcodeOffsetMs => (_transcodeStartSec * 1000).round();

  /// 阶段6 无状态转码装载：成功返回 true（已 setUrl），失败/未启用返回 false
  /// 由调用方回落。原文件缓存作转码失败/断网兜底（见 [_loadOnce]）；整曲转码
  /// 不支持 Range，seek 走带偏移重载（[startSec] → 服务端输出端 -ss，R8）。
  /// 成功时记 [_liveTranscode]/[_transcodeStartSec]（供 [position]/[seek]）。
  Future<bool> _tryTranscodeLoad(
      Song s, MusicSource src, String originUrl, dynamic tag,
      {double startSec = 0}) async {
    try {
      final settings = _appSettings;
      final api = _transcodeApi;
      if (settings == null || api == null) return false;
      if (!shouldUseTranscode(
        enabled: settings.transcodeEnabled,
        apiBaseUrl: (api.baseUrl as String?) ?? '',
        src: src,
      )) {
        return false;
      }
      final int bitrate = settings.transcodeBitrate;
      final String loudnorm = settings.transcodeLoudnorm;
      final String? turl = api.transcodeStreamUrl(originUrl, bitrate,
          loudnorm: loudnorm, startSec: startSec) as String?;
      if (turl == null) return false;
      final headers = <String, String>{};
      try {
        final token = await api.getAccessToken() as String?;
        if (token != null && token.isNotEmpty) {
          headers['Authorization'] = 'Bearer $token';
        }
      } catch (_) {}
      // 回源鉴权随请求转发（不落地）：各源经 proxyAuthHeaders 自备
      // （WebDAV Basic / SFTP 信封），默认空。
      headers.addAll(await src.proxyAuthHeaders(s));
      debugPrint('[play] 转码代理 ${bitrate}k loudnorm=$loudnorm'
          '${startSec > 0 ? ' start_sec=$startSec' : ''}: $turl');
      final load = player.setUrl(turl, headers: headers, tag: tag);
      try {
        await load.timeout(_loadUrlTimeout);
      } on TimeoutException {
        load.ignore();
        debugPrint('[play] 转码装载超时，回落直连');
        return false;
      }
      _liveTranscode = true;
      _transcodeStartSec = startSec;
      return true;
    } catch (e) {
      // 429 并发满 / 503 无 ffmpeg / 502 源失败：一律静默回落直连原文件。
      debugPrint('[play] 转码失败回落直连: $e');
      return false;
    }
  }

  /// 单次装载（转码开时）：
  /// 变体缓存（与当前码率/响度一致的转码产物，本地秒开）→ 转码流 →
  /// 原文件缓存（转码失败/断网兜底）→ 原生 URL（Range/seek 更稳）→
  /// 自建字节流 [DirectAudioSource]。
  /// （转码关时）原文件缓存 → 原生 URL → 自建字节流（旧行为不变）。
  /// [probe] 为 false 时跳过装载前探针（该源已探明无响应，别再白等）。
  /// [skipTranscode] 为 true 时跳过转码分支（同一 [_playDirect] 内首轮已试过
  /// 转码：429/502/超时几秒后重试大概率还是失败，别再占服务端转码许可
  /// 反复 spawn ffmpeg；重试只走缓存/直连/字节流）。
  /// [startSec] > 0 时转码分支带偏移重开流（seek/保位置重载用；变体命中则
  /// 本地原生 seek，不走流式）。
  Future<void> _loadOnce(Song s, MusicSource src,
      {bool probe = true, bool skipTranscode = false, double startSec = 0}) async {
    final tag = mediaItemOf(s, title: displayTitle(s));
    final settings = _appSettings;
    final api = _transcodeApi;
    final transcodeOn = settings != null &&
        api != null &&
        shouldUseTranscode(
          enabled: settings.transcodeEnabled,
          apiBaseUrl: (api.baseUrl as String?) ?? '',
          src: src,
        );
    // 先按非直播态复位：各成功分支按实际链路重记（转码分支记 true）。
    _liveTranscode = false;
    _transcodeStartSec = 0;
    if (transcodeOn && !skipTranscode) {
      // 与当前设置一致的预载转码产物：本地文件，原生 seek、无需重建请求。
      try {
        final variant = await _resolveTranscodeCache?.call(src, s);
        if (variant != null) {
          debugPrint('[play] ${src.kind} 转码变体缓存: $variant');
          await player.setFilePath(variant, tag: tag);
          if (startSec > 0) {
            // 保位置重载命中变体：本地文件直接 seek，无需流式。
            try {
              await player.seek(
                  Duration(milliseconds: (startSec * 1000).round()));
            } catch (_) {}
          }
          return;
        }
        // 未命中才值得打一行（命中行在上面）：排查“预载了但没用上”时
        // 与 [preload] 侧的 key 日志对照（接线缺失 vs 缓存行缺失）。
        debugPrint('[play] ${src.kind} 无变体缓存'
            '${_resolveTranscodeCache == null ? '（未接线）' : ''}《${s.title}》');
      } catch (_) {
        // 变体损坏等：继续走流式，下面原文件缓存仍可兜底。
      }
    }
    final cached = await src.cachedFilePath(s);
    if (cached != null && !transcodeOn) {
      if (await _playCachedFile(cached, src, tag)) return;
    }
    final direct = src.directStream(s);
    // 代理转码：开关开 + 后端可达 + 该源选了代理链路时优先走服务端；
    // origin 与鉴权头由源自备（WebDAV https URL + Basic / SFTP sftp:// + 信封 /
    // SMB smb:// + 信封）。
    // 变体缓存命中已在上方返回；转码失败静默回落（原文件缓存 → 直连）。
    final proxyUrl = src.proxyOrigin(s);
    if (!skipTranscode &&
        proxyUrl != null &&
        await _tryTranscodeLoad(s, src, proxyUrl, tag, startSec: startSec)) {
      return;
    }
    // 转码开但流失败（429 并发满 / 503 / 断网）：原文件缓存兜底，
    // 不行再走直连（旧行为里原缓存恒首位，转码开时不再让它抢跑）。
    if (transcodeOn && cached != null) {
      if (await _playCachedFile(cached, src, tag)) return;
    }
    if (direct != null) {
      debugPrint('[play] ${src.kind} URL: ${direct.url}'
          '${direct.headers != null && direct.headers!.isNotEmpty ? ' (headers: ${direct.headers!.keys.join(",")})' : ' (无 headers)'}');
      // 装载前快速鉴权探针：1 字节 Range 走完 DNS/TCP/TLS/鉴权。401/403
      // 直接失败——原生播放器（AVPlayer/ExoPlayer）对错误响应只会无限缓冲，
      // 进度停 0:00 无任何提示（2026-09-29 真机实测，密码过期即此表现）。
      // 其余探针异常不阻塞装载（网络抖动交给播放器自身重试）。
      probeTimedOut = false;
      if (probe) {
        try {
          final probeTask = src.probe(s);
          try {
            await probeTask.timeout(_probeTimeout);
          } on TimeoutException {
            probeTask.ignore(); // 看门狗放弃后，迟到的失败静默丢弃防 unhandled
            // 记下超时：仍在本次尝试里继续装载（首字节慢的源本可成功），
            // 但让 [_playDirect] 后续重试别再重复白等这 10s。
            probeTimedOut = true;
            rethrow;
          }
        } on SourceAuthException {
          rethrow;
        } catch (e) {
          debugPrint('[play] 装载前探针失败（忽略，继续装载）: $e');
        }
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

  /// 播本地缓存文件（原文件缓存 / 转码变体缓存共用）：成功 true；
  /// 失败 false（调用方继续走流式，不让可播歌曲卡死）。
  Future<bool> _playCachedFile(
      String path, MusicSource src, dynamic tag) async {
    debugPrint('[play] ${src.kind} 缓存文件: $path');
    try {
      await player.setFilePath(path, tag: tag);
      return true;
    } catch (e) {
      // 缓存文件装载失败（如 ohos 沙箱真路径 mdk 打不开、缓存文件损坏）：
      // 回落自建字节流，不让可播歌曲卡死在直连失败上（2026-10-07 ohos
      // 直连改造的配套兜底；直连失败时字节流分支仍可用）。
      debugPrint('[play] 缓存文件装载失败（回退字节流）: $e');
      return false;
    }
  }

  /// 懒补全：播放后把解析出的完整元数据（标题/歌手/专辑/专辑歌手/时长/曲目/年份/封面）
  /// 回填索引。从头完整读取（采样不足时读满整个文件，不截断），失败静默不影响播放。
  /// 成功后刷新队列与当前歌曲对象并通知，播放页即时展示新读到的信息；
  /// 另有变化时通过 [_onSongMetaRefreshed] 通知全局库就地刷新，并失效旧封面图像缓存。
  /// 当前曲封面变化时补一次 [_syncSystemMedia]（问题2：晚到封面也要进通知栏；
  /// 无图→有图换图，有图→无图（极少）同样刷新，避免残留）。
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
        final coverChanged = updated.coverPath != s.coverPath;
        refreshSongMeta(updated);
        if (changed) {
          final cover = updated.coverPath;
          if (cover != null) {
            // 同一路径封面被重写时 Flutter 图像缓存会留旧图，主动失效。
            unawaited(FileImage(File(cover)).evict());
          }
          _onSongMetaRefreshed?.call(updated);
        }
        // 晚到封面是当前曲才推系统媒体（通知栏/OHOS 播控卡），非当前曲只刷列表。
        if (coverChanged) {
          final cur = _current;
          if (cur != null && _same(cur, updated)) {
            _syncSystemMedia();
          }
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
  /// 直播转码态叠加服务端偏移（歌词按绝对时间轴对齐）。
  Stream<Duration> get lyricPositionStream {
    final base = lyricsPositionOverride ?? player.positionStream;
    return base.map((p) {
      final s = _transcodeStartSec;
      return (_liveTranscode && s > 0)
          ? p + Duration(milliseconds: _transcodeOffsetMs)
          : p;
    });
  }

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
    // 问题2修复：悬空路径（文件被删/半图被清理/尚未落盘）不得发 file://，
    // 否则原生解码失败后部分系统 Controller 不清旧图，残留上一首封面。
    // 校验失败一律发 null，原生侧走清图分支。
    Uri? art;
    final cover = s.coverPath;
    if (cover != null && cover.isNotEmpty) {
      try {
        if (File(cover).existsSync()) art = Uri.file(cover);
      } catch (_) {
        art = null;
      }
    }
    return MediaItem(
      id: '${s.sourceKey}:${s.sourceRef}',
      album: s.albumName,
      artist: s.artist,
      title: t.isEmpty ? '未知曲目' : t,
      duration: duration,
      artUri: art,
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

  // ---------- 加权随机削峰（冷却） ----------

  /// 次数冷却计数（规则1）：键 `sourceKey\u0000sourceRef` → 自上次播放以来
  /// 被抽中却抛弃的次数（落账时结算；起播落账时本歌清零为 0 而不删映射——落账
  /// 即「播放过」，下次被抽中时规则1 生效）。曲数冷却（规则2）不走计数——取
  /// 深层列表末尾的曲数窗口（见 [weightedCooldownWindowOf]，天生持久化），窗口
  /// 内的歌进轮盘前即从候选池剔除（见 [excludeCooldownCandidates]），不参与
  /// 随机、不再给规则1 供数，两规则彻底解耦（实验 ⑥）。
  final Map<String, int> _weightedDrawCounts = {};

  /// 最近一次 [_weightedPickIndex] 抽样链中被抛弃的抽中次数（键→次数），
  /// 待 [_commitWeightedPlay] 落账；预取结果被作废时直接丢弃、不落账。
  Map<String, int> _pendingWeightedRejections = const <String, int>{};

  /// 歌曲身份键（`sourceKey\0sourceRef`，与 completed 去重同口径）。
  static String weightedKeyOf(Song s) => '${s.sourceKey}\u0000${s.sourceRef}';

  /// 【削峰补丁】加权抽样的次数冷却判定（规则1，纯函数，便于单测）：
  /// 自上次播放起被抽中的前 [drawLimit] 次抛弃（[draws] 为含本次的抽中次数，
  /// 第 drawLimit+1 次才作数）；上限按权重档由设置决定，`0`=关闭规则1。
  /// 曲数冷却（规则2）不再经由这里判定——窗口内的歌在进轮盘前已被
  /// [excludeCooldownCandidates] 从候选池剔除、不参与随机（实验 ⑥：池排除
  /// 覆盖更好、重抽更省，且不再给规则1 供数）。
  static bool weightedCooldownReject({
    required int draws,
    required int drawLimit,
  }) {
    return draws <= drawLimit;
  }

  /// 【削峰补丁】曲数冷却窗口：深层列表（各锚定上下文持久化的播放历史）末尾
  /// [window] 条的身份集合。窗口随列表长度走比例，跨重启/跨设备同步后仍在
  /// （深层列表本就落库）。[window]<=0 或历史为空 → 空集（规则2 关闭）。
  @visibleForTesting
  static Set<String> weightedCooldownWindowOf(
      Iterable<Song> history, int window) {
    if (window <= 0) return const <String>{};
    final list = history is List<Song> ? history : history.toList();
    final start = list.length > window ? list.length - window : 0;
    return <String>{
      for (var i = start; i < list.length; i++) weightedKeyOf(list[i]),
    };
  }

  /// 【削峰补丁】规则2 的候选池剔除（纯函数，便于单测）：从 [candidates] 中剔除
  /// 身份落在 [cooldownKeys]（[weightedCooldownWindowOf] 给出的深层列表末尾窗口）
  /// 内的下标——窗口内的歌不参与随机。若剔除后为空（窗口覆盖整表）则原样返回
  /// 全量（交由规则1 兜底，避免空池）。
  @visibleForTesting
  static List<int> excludeCooldownCandidates(
      List<int> candidates, List<Song> pool, Set<String> cooldownKeys) {
    if (cooldownKeys.isEmpty) return candidates;
    final kept = <int>[
      for (final i in candidates)
        if (!cooldownKeys.contains(weightedKeyOf(pool[i]))) i,
    ];
    return kept.isEmpty ? candidates : kept;
  }

  /// 【削峰补丁】加权随机实际播放落账：结算上一次抽样链的抛弃次数，并把本首歌
  /// 的次数计数重置为 0（不清映射——落账即「播放过」，离开曲数窗口后被抽中时
  /// 规则1 生效；规则2 的「近期已播」由深层列表末端自然承担）。
  /// 必须在歌曲真正起播时调用一次（见 [_playWeighted] 与 [startIndexForPlaylist]）。
  void _commitWeightedPlay(Song s) {
    _pendingWeightedRejections.forEach((key, times) {
      _weightedDrawCounts[key] = (_weightedDrawCounts[key] ?? 0) + times;
    });
    _pendingWeightedRejections = const <String, int>{};
    _weightedDrawCounts[weightedKeyOf(s)] = 0;
  }

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
      // 预取口径与 [_advance] 一致：越过接缝复本，越过队尾则回绕。
      var landed = (_idx + 1) % _queue.length;
      final cur = _current;
      if (cur != null) {
        landed = skipSeamDupIndex(landed, _deepList?.length ?? 0, _queue,
                cur, _same,
                anchored: _fusedBase != null && _deepList != null) %
            _queue.length;
      }
      _peekedNext = _queue[landed];
      return _peekedNext;
    }
    if (_mode == PlayMode.weighted) {
      _peekedNext = _pickWeighted();
      return _peekedNext;
    }
    // 预取口径与 [_advance] 一致：落到接缝复本上则越过一位，越过队尾即无下一首。
    var landed = _idx + 1;
    final curSeq = _current;
    if (curSeq != null) {
      landed = skipSeamDupIndex(landed, _deepList?.length ?? 0, _queue,
          curSeq, _same,
          anchored: _fusedBase != null && _deepList != null);
    }
    if (landed < _queue.length) {
      _peekedNext = _queue[landed];
      return _peekedNext;
    }
    // 队尾：顺序模式会清零深层从头播放（与 [_advance] 同口径）→ 预取基座首曲；
    // 非锚定则无下一首（收尾停止口径）。
    final base = _fusedBase;
    if (base != null && _deepList != null && base.isNotEmpty) {
      _peekedNext = base[0];
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
    _userTookOver = true;
    _leaveFor(null);
    return _advance();
  }

  /// 推进到下一首。[autoAdvanceOnFailure] 为 true 表示这是自动续播链路
  /// （自然播完、失败跳歌、播放错误恢复），装载失败时继续跳下一首而非停住。
  /// [play] 为 false 时只装载下一首并暂停（睡眠定时曲末预切），不发声。
  Future<void> _advance(
      {bool autoAdvanceOnFailure = false, bool play = true}) async {
    if (_queue.isEmpty || _current == null) return;
    // 单曲循环是显式的「不要推进」：连 [_nextUp] 也压住，等用户切模式或手动下一首。
    if (_mode == PlayMode.loopOne) {
      await _replay(play: play);
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
          source: _curSource,
          autoAdvanceOnFailure: autoAdvanceOnFailure,
          play: play);
      return;
    }
    if (_mode == PlayMode.weighted) {
      await _playWeighted(
          autoAdvanceOnFailure: autoAdvanceOnFailure, play: play);
      return;
    }
    if (_mode == PlayMode.loopList) {
      // 接缝复本（深层尾在续播段首位的复本）不是真正的下一首，越过它；
      // 越过队尾则回绕到深层头部（既有列表循环口径）。
      final prev = _current;
      var landed = (_idx + 1) % _queue.length;
      if (prev != null) {
        landed = skipSeamDupIndex(landed, _deepList?.length ?? 0, _queue,
                prev, _same,
                anchored: _fusedBase != null && _deepList != null) %
            _queue.length;
      }
      _idx = landed;
      await _play(_queue[_idx],
          source: _curSource,
          autoAdvanceOnFailure: autoAdvanceOnFailure,
          play: play);
      return;
    }
    // 顺序推进：落到接缝复本上则越过一位；越过队尾（>= 队长）即播完收尾。
    var landed = _idx + 1;
    final prevSeq = _current;
    if (prevSeq != null) {
      landed = skipSeamDupIndex(landed, _deepList?.length ?? 0, _queue,
          prevSeq, _same,
          anchored: _fusedBase != null && _deepList != null);
    }
    if (landed < _queue.length) {
      _idx = landed;
      await _play(_queue[_idx],
          source: _curSource,
          autoAdvanceOnFailure: autoAdvanceOnFailure,
          play: play);
      return;
    }
    // 顺序模式播到队尾：深层清零后从头播放（仅锚定融合队列；非锚定仍收尾停止）。
    // 即深层「播完一轮清空重来」在顺序模式的形态：自动历史不断推入，
    // 到队尾时不清零就会停住（此前即 `_finishQueue`）。
    final dlEnd = _deepList;
    if (_fusedBase != null && dlEnd != null) {
      dlEnd.clear();
      _persistDeepList();
      _rebuildFusedQueue();
      _idx = 0;
      await _play(_queue[_idx],
          source: _curSource,
          autoAdvanceOnFailure: autoAdvanceOnFailure,
          play: play);
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
  /// [play] 透传给 [_advance]：睡眠定时曲末预切的跳歌仍保持暂停不发声。
  Future<void> _autoSkipAfterFailure([Object? reason, bool play = true]) async {
    _loadFailStreak++;
    debugPrint('[play] 装载连续失败 $_loadFailStreak 次: $reason');
    if (_loadFailStreak >= _loadFailSkipLimit) {
      _loadFailStreak = 0;
      await _finishQueue();
      AppToast.show('连续 $_loadFailSkipLimit 首无法加载，已停止播放');
      return;
    }
    // 自动续播链路每首都弹 toast 会在后台连刷屏，故只在开始跳歌时说明一次：
    // 原先从第一次失败到最终「已停止」之间完全无反馈，而这段最坏要几十秒
    // （每首 3 次尝试 × 探针/装载超时 + 退避），人不在屏幕前时看着像程序死了。
    if (_loadFailStreak == 1) {
      final hint =
          reason is TimeoutException ? '（网络超时）' : '';
      AppToast.show('无法加载，正在尝试下一首$hint');
    }
    await _advance(autoAdvanceOnFailure: true, play: play);
  }

  Future<void> prev() {
    _userTookOver = true;
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

  /// 单曲循环：同一首重播。[play] 为 false 时只回到开头并暂停（睡眠定时曲末预切）。
  Future<void> _replay({bool play = true}) async {
    _completedKey = null;
    await player.seek(Duration.zero);
    if (play) {
      await player.play();
    } else if (player.playing) {
      await player.pause();
    }
  }

  /// 加权随机下一首（stage2.md §2.2）：优先采用 peekNext 已抽样的结果
  /// （保证预载的就是实际要播的），失效则重新从队列全量排除上一首按 factor 采样。
  Future<void> _playWeighted(
      {bool autoAdvanceOnFailure = false, bool play = true}) async {
    final picked = _takePeeked() ?? _pickWeighted();
    if (picked == null) return;
    // 【削峰补丁】抽样已确定、即将起播 → 落账冷却（结算抛弃次数 + 重置本歌）。
    _commitWeightedPlay(picked);
    // 定位优先深层尾（同 [_rebuildFusedQueue]；播后重建还会再纠一次）。
    final i = locateCurrentIndex(
        _queue, _deepList?.length ?? 0, picked, _same);
    _idx = i < 0 ? 0 : i;
    await _play(picked,
        source: _curSource,
        autoAdvanceOnFailure: autoAdvanceOnFailure,
        play: play);
  }

  /// 按权重随机抽一首（排除当前曲；只剩当前曲时允许重播）。
  Song? _pickWeighted() {
    final i = _weightedPickIndex(_queue, _current);
    return i == null ? null : _queue[i];
  }

  /// 加权抽样的下标版（队列下一首与歌单起播共用）：
  /// 在 [pool] 中排除 [exclude] 后按 factor 抽样，返回**池内下标**；池空返回 null。
  /// 已应用时长削弱（改进.txt 功能8）：effective = factor × 时长系数，钳回 [0.5,1.5]；
  /// 「不喜欢」锁定行例外，恒按 0.1 计权（见 [effectiveWeight]）。
  ///
  /// 【削峰补丁】规则2 改为候选池剔除：深层列表末尾 [window] 条内的歌先从候选池
  /// 拿掉（见 [excludeCooldownCandidates]），不参与随机、不再给规则1 供数；
  /// 规则1（次数冷却）仍对池内已播过的歌做拒绝采样，抛弃计入
  /// [_pendingWeightedRejections]，实际起播时由 [_commitWeightedPlay] 落账。
  /// [useHistoryCooldown]：歌单「播放/从头播放」即将重锚清空深层列表，起播抽样
  /// 不带历史冷却（false）；常规推进取锚定上下文深层列表作冷却（true）。
  int? _weightedPickIndex(List<Song> pool, Song? exclude,
      {bool useHistoryCooldown = true}) {
    if (pool.isEmpty) return null;
    final curve = _durationCurve;
    var candidates = <int>[
      for (var i = 0; i < pool.length; i++)
        if (exclude == null || !_same(pool[i], exclude)) i,
    ];
    // 只剩当前曲（或全被排除）时退回全量，允许重播。
    if (candidates.isEmpty) candidates = [for (var i = 0; i < pool.length; i++) i];
    // 规则2 窗口 = 列表长度 × 设置比例（默认 20%；比例 0=关闭规则2）；
    // 冷却集合 = 深层列表（持久化播放历史）末尾 window 条，直接从候选池剔除
    // （窗口覆盖整表时保留全量，交由规则1 兜底）。
    final cooldown = _appSettings?.weightedDrawCooldown ??
        WeightedDrawCooldown.normal;
    final ratio = _appSettings?.weightedCountCooldownRatio ??
        AppSettings.defaultWeightedCountCooldownRatio;
    final window = (pool.length * ratio).round();
    final dl = _deepList;
    final cooldownKeys = useHistoryCooldown && dl != null
        ? PlayerProvider.weightedCooldownWindowOf(dl.entries, window)
        : const <String>{};
    candidates =
        PlayerProvider.excludeCooldownCandidates(candidates, pool, cooldownKeys);
    final store = _weight;
    // 整队一次性取回权重行（按 sourceKey 分组批量查询），循环内不再逐首同步查库。
    final rows = store == null
        ? const <String, Map<String, ({double factor, bool frozen})>>{}
        : store.weightRowsOf(pool);
    final weights = <double>[];
    final baseFactors = <double>[];
    for (final i in candidates) {
      final row = rows[pool[i].sourceKey]?[pool[i].sourceRef];
      final f = row?.factor ?? SongWeightStore.defaultFactor;
      baseFactors.add(f);
      weights.add(PlayerProvider.effectiveWeight(
        factor: f,
        frozen: row?.frozen ?? false,
        curveMultiplier: curve.multiplierFor(pool[i].duration?.toDouble()),
      ));
    }
    // 规则1 拒绝采样：已播过的歌（计数非空）按档位抛弃前 N 次抽中。
    final overlay = <String, int>{};
    var rejects = 0;
    while (true) {
      final k = weightedPickByWheel(weights, _rng.nextDouble());
      final i = candidates[k];
      final key = weightedKeyOf(pool[i]);
      final count = _weightedDrawCounts[key];
      // 从未播放（计数为空）：次数冷却不适用，直接命中。
      if (count != null) {
        final draws = count + (overlay[key] ?? 0) + 1;
        final reject = PlayerProvider.weightedCooldownReject(
          draws: draws,
          drawLimit: cooldown.limitFor(baseFactors[k]),
        );
        // 硬上限兜底：极端情况下避免死循环。
        if (reject && rejects < 100000) {
          overlay[key] = (overlay[key] ?? 0) + 1;
          rejects++;
          continue;
        }
      }
      _pendingWeightedRejections = overlay;
      return i;
    }
  }

  /// 单曲有效抽样权重（纯函数，便于直接单测）：
  /// 「不喜欢」锁定态（[frozen]）恒为 [SongWeightStore.dislikedFactor]——这是低于
  /// 自动调权下限的唯一取值，不乘时长削弱曲线、不被下限钳回（用户手动确认的
  /// 「不想听」优先级高于一切自动调整）；其余歌曲 = `factor × 时长系数` 钳回
  /// [SongWeightStore.minFactor, SongWeightStore.maxFactor]。
  static double effectiveWeight({
    required double factor,
    required bool frozen,
    required double curveMultiplier,
  }) =>
      frozen
          ? SongWeightStore.dislikedFactor
          : (factor * curveMultiplier)
              .clamp(SongWeightStore.minFactor, SongWeightStore.maxFactor);

  /// 加权轮盘：把 [weights] 按比例铺成 `[0,total)` 上的连续区段，取随机点 [r]
  /// （`[0,1)`，由调用方注入）落中哪段即返回该下标。
  ///
  /// 纯函数（不依赖实例状态），随机值由调用方注入——同 [startIndexForOrder]
  /// 的约定，便于确定性单测。每次命中概率 = `weights[i] / total`。
  /// [weights] 需非空（调用方已保证池非空），且各权重恒为正（上层 [effectiveWeight]
  /// 保证：常规钳回 `[minFactor, maxFactor]`，锁定态取 [SongWeightStore.dislikedFactor]，
  /// 杜绝零概率空槽）。
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
  /// 「播放/从头播放」会重锚清空深层列表，故起播抽样不带历史冷却
  /// （[useHistoryCooldown] = false）。
  int startIndexForPlaylist(List<Song> songs) {
    if (songs.isEmpty) return 0;
    final cur = _current;
    final currentIndex =
        cur == null ? -1 : songs.indexWhere((s) => _same(s, cur));
    final weightedIndex = _mode == PlayMode.weighted
        ? _weightedPickIndex(songs, cur, useHistoryCooldown: false)
        : null;
    final start = startIndexForOrder(_mode, songs.length,
        currentIndex: currentIndex < 0 ? null : currentIndex,
        weightedIndex: weightedIndex);
    // 【削峰补丁】加权起播：抽样已确定起始曲，落账冷却。
    if (weightedIndex != null && start >= 0 && start < songs.length) {
      _commitWeightedPlay(songs[start]);
    }
    return start;
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
    _emitWeight(c, completed: false, position: position);
  }

  // ---------- 播放控制 ----------

  /// 播放/暂停切换：目标态（[playing]）一帧内响应点击，音频渐变在后台完成；
  /// 渐变进行中再次点击 = 反向打断，任意时刻点击都有响应：
  /// - 淡出中点「播放」→ 取消暂停意图，音量从当前值平滑回升（引擎从未停，
  ///   不重新调 play()）；
  /// - 淡入中点「暂停」→ 自然落入暂停分支，从当前音量淡出（两个方向对称）；
  /// - 淡出收尾窗口（实际已暂停、完成回调仍在途）点「播放」→ 正常恢复，
  ///   归零淡入（此刻音量≈0，无跳变）。
  Future<void> toggle() async {
    _userTookOver = true;
    // 用户主动点按钮（含“系统暂停后点恢复”）：取消焦点恢复意图。
    _audioFocusPaused = false;
    _audioFocusSavePending = false;
    // 启动恢复还没收尾：连点只翻转待应用目标态。奇数次恢复完播放，
    // 偶数次保持暂停；恢复尾只执行一次，不会叠多次 play()/淡入。
    final restoreTarget = _restoreResumeTarget;
    if (restoreTarget != null) {
      _restoreResumeTarget = !restoreTarget;
      notifyListeners();
      return;
    }
    if (player.playing) {
      if (_fadingPause) {
        // 淡出进行中反向打断：取消暂停意图，音量从当前值平滑回升。
        // 引擎从未实际暂停（playing 仍 true），无需也不应重新调 play()。
        _cancelFadeAndComplete();
        _fadingPause = false;
        _fadeIn(fromZero: false);
        notifyListeners();
        return;
      }
      // 暂停方向不再阻塞等待淡出：目标态（[playing]）经 pending-pause 位
      // 一帧内翻转为「已暂停」，音频淡出在后台完成，实际 pause() 发生在
      // 淡出完成回调里（[_fadeOutThenPause] 内部 onDone）。
      _fadingPause = true;
      notifyListeners();
      // 暂停即时同步：先推一次积压，实际暂停完成后强制落最终断点再推一次。
      _onSyncPoke?.call();
      unawaited(_fadeOutThenPause().then((_) {
        // 实际暂停完成后（或渐变被清理路径/反向打断取消）再通知与回推
        // 系统媒体：通知栏/媒体中心以**实际**状态为准（规格假设），
        // 不随按钮提前翻转。
        notifyListeners();
        _syncSystemMedia();
        _saveForcedAndPoke();
      }));
      return;
    }
    if (_fadingPause) {
      // 淡出收尾窗口：实际已暂停（player.playing==false 才会走到这里）、
      // 完成回调仍在途。收口挂起 Future 并复位意图位；随后的恢复走归零
      // 淡入（此刻音量≈0，无跳变），迟到的 onDone 检测到新渐变已接管，
      // 不会再动音量。
      _cancelFadeAndComplete();
      _fadingPause = false;
    }
    if (_restoreFuture != null) {
      // 恢复装载/seek 还没收尾：先立目标态（按钮立即翻「播放中」），
      // 由 [_resumeOrReplay] 等恢复完再真正下发 play。
      _restoreResumeTarget = true;
      notifyListeners();
    }
    await _resumeOrReplay();
    notifyListeners();
    _syncSystemMedia();
    // 恢复播放即时同步（播放态门控由状态流驱动，这里只推积压）。
    _onSyncPoke?.call();
  }

  /// 恢复播放：若当前曲已播完（顺序模式队尾收尾或单曲播完），
  /// 先回到 0 处再播——否则 play() 会立刻再次 completed，表现为「按了没反应」。
  ///
  /// 启动恢复（[_restoreFuture]）尚未收尾时先等它：恢复链的 `_play(play:false)`
  /// 仍在装载/seek，此时直接下发 play 会与恢复尾的 pause 打架——冷启动/
  /// 播控卡点播放无声即此竞态。等待期间连点由 [_restoreResumeTarget] 记录，
  /// 恢复完后只执行一次，避免多次 play()/淡入叠加。
  Future<void> _resumeOrReplay() async {
    if (_shuttingDown || _disposed) return;
    final restoring = _restoreFuture;
    if (restoring != null) {
      final inFlight = _restoreResumeFuture;
      if (inFlight != null) {
        await inFlight;
        return;
      }
      final f = _resumeAfterRestore(restoring);
      _restoreResumeFuture = f;
      try {
        await f;
      } finally {
        if (identical(_restoreResumeFuture, f)) _restoreResumeFuture = null;
      }
      return;
    }
    await _resumePlaybackNow();
  }

  /// 等启动恢复收尾后按最新目标态执行一次恢复。
  Future<void> _resumeAfterRestore(Future<void> restoring) async {
    try {
      try {
        await restoring;
      } catch (e) {
        debugPrint('[play] 等待启动恢复失败（忽略）：$e');
        return;
      }
      if (_shuttingDown || _disposed) return;
      // 连点偶数次：恢复完保持暂停；无现场也不 play（避免本地 playing
      // 置真却没有音源）。目标态在真正下发 play 前还可能被再次翻转。
      final target = _restoreResumeTarget;
      if (target == false) return;
      if (_current == null) return;
      await _resumePlaybackNow();
    } finally {
      // 无论正常/取消/异常，等待期目标态都不留到恢复之后。
      _restoreResumeTarget = null;
    }
  }

  Future<void> _resumePlaybackNow() async {
    if (player.processingState == ProcessingState.completed) {
      try {
        await player.seek(Duration.zero);
      } catch (_) {}
    }
    // 恢复期目标态可能在上面的 seek 期间又被连点翻转；以最新值为准。
    if (_restoreResumeTarget == false) return;
    _restoreResumeTarget = null;
    // 同 [_play]：play() 的 Future 到播完/暂停才 complete，不能 await，否则
    // toggle()/通知栏「播放」的 _syncSystemMedia() 被推迟（前台服务/唤醒锁
    // 起不来，后台播放不成立）。
    unawaited(player.play().catchError((Object e) {
      debugPrint('[play] play 调用异常（忽略）：$e');
    }));
    _fadeIn();
  }

  /// 通知栏「播放」回调（settings.md §3.6）。
  Future<void> resumeFromNotifier() async {
    // 无播放现场且没有在途恢复（队列为空/已被清空）：播控卡点播放不应白建
    // 播放器、把本地 playing 置真。恢复中即使当前曲还没落位也要继续，
    // 交给 [_resumeOrReplay] 等恢复收尾后再判断。
    if (_current == null && _restoreFuture == null) return;
    if (_restoreFuture != null) _restoreResumeTarget = true;
    _userTookOver = true;
    _audioFocusPaused = false;
    _audioFocusSavePending = false;
    // 淡出被通知栏「播放」打断（系统侧反向打断）：收口挂起的淡出 Future
    //（不暂停）+ 复位意图位，随后正常恢复（归零淡入）。
    _cancelFadeAndComplete();
    _fadingPause = false;
    await _resumeOrReplay();
    notifyListeners();
    _syncSystemMedia();
    _onSyncPoke?.call();
  }

  /// 播控中心 PlayMusicList 意图调用（鸿蒙「冷启动续播/历史歌单」，经
  /// ohos_media_session.dart 'insightPlay' 转发）。[playlistId] 为播控中心
  /// 回传的歌单标识（avQueueId 口径），v1 语义统一为「续播最近队列」：
  /// 有播放现场（含恢复中）先等恢复尾收尾再续播；无现场（冷启动未恢复——
  /// 含「断点续播」开关关闭场景，卡片播放是显式用户动作，恢复链照走）
  /// 先走断点恢复（暂停态装载）再续播。无可恢复队列时空转（不抛错）。
  Future<void> insightPlayFromSystem(String? playlistId) async {
    debugPrint('[player] 播控中心意图播放：playlistId=$playlistId');
    if (_shuttingDown) return;
    if (!_hasPlayScene) {
      // 幂等恢复入口（_restored 守卫）：未恢复才发起，恢复中/已恢复立即返回。
      await restorePreferRemote();
    } else {
      final restoring = _restoreFuture;
      if (restoring != null) await restoring;
    }
    if (_shuttingDown || !_hasPlayScene) return;
    await resumeFromNotifier();
  }

  /// 通知栏「暂停/停止」回调（settings.md §3.6）。
  Future<void> pauseFromNotifier() async {
    _userTookOver = true;
    await _fadeOutThenPause();
    notifyListeners();
    _syncSystemMedia();
    _saveForcedAndPoke();
  }

  /// 通知栏「停止」/ 任务被划掉：停止播放；默认清断点（通知栏「停止」= 用户显式
  /// 停掉，与丢弃队列一致），划掉任务路径传 `clearResume: false` 保留断点/队列。
  /// 处理器的 `super.stop()` 随后把状态置 idle，前台服务/通知随之结束。
  Future<void> stopFromNotifier({bool clearResume = true}) async {
    // 启动恢复期已有待播放目标时，停止直接取消它。
    if (_restoreResumeTarget != null) _restoreResumeTarget = false;
    // 清理路径：取消渐变 + 收口挂起的淡出 Future（不暂停）+ 复位意图位。
    _cancelFadeAndComplete();
    _fadingPause = false;
    _audioFocusPaused = false;
    _audioFocusSavePending = false;
    // 显式停止：恢复期的乐观位置一并失效（停后位置恒为 0）。
    _clearRestorePosition();
    try {
      await player.stop();
    } catch (_) {
      // 平台停止失败不阻塞退出流程。
    }
    if (clearResume) clearResumeState();
    notifyListeners();
    _onSyncPoke?.call();
  }

  Future<void> seek(Duration d) async {
    _userTookOver = true;
    // 用户手动 seek 接管：恢复期的乐观位置失效，之后走真实位置。
    _clearRestorePosition();
    // 直播转码流不可原生 seek：带偏移重开流（服务端输出端 -ss）。
    if (_liveTranscode) {
      await _seekLiveTranscode(d);
    } else {
      await player.seek(d);
    }
    _syncSystemMedia();
  }

  /// 直播转码流 seek：用目标位置作 `start_sec` 重开一条转码流，保播放态。
  /// 旧链由 [_playToken] 作废（setUrl 打断旧流，迟到结果静默丢弃）；
  /// 新流起不来时先回退原偏移（不断流），都不行才整曲重装。
  Future<void> _seekLiveTranscode(Duration target) async {
    final cur = _current;
    final src = _curSource;
    if (cur == null || src == null) return;
    var ms = target.inMilliseconds;
    if (ms < 0) ms = 0;
    final dur = duration;
    if (dur != null && ms > dur.inMilliseconds) ms = dur.inMilliseconds;
    final prevSec = _transcodeStartSec;
    final wasPlaying = player.playing && !_fadingPause;
    final token = ++_playToken;
    bool alive() => token == _playToken;
    try {
      final proxyUrl = src.proxyOrigin(cur);
      final tag = mediaItemOf(cur, title: displayTitle(cur));
      if (proxyUrl == null) return;
      var ok = await _tryTranscodeLoad(cur, src, proxyUrl, tag,
          startSec: ms / 1000.0);
      if (!alive()) return;
      if (!ok) {
        // 新偏移起不来：回退原偏移保住不断流。
        debugPrint('[play] 转码 seek 回退原偏移《${cur.title}》');
        ok = await _tryTranscodeLoad(cur, src, proxyUrl, tag,
            startSec: prevSec);
        if (!alive()) return;
        if (!ok) {
          AppToast.show('转码 seek 失败，已保持原进度', isError: true);
          return;
        }
      }
      // 与 _play 同口径：先复位再播，避免自然播完态的 play() 空转。
      if (wasPlaying) {
        if (player.playing) {
          try {
            await player.pause();
          } catch (_) {}
        }
        unawaited(player.play().catchError((Object e) {
          if (!alive() || _shuttingDown) return;
          debugPrint('[play] seek 后 play 异常《${cur.title}》: $e');
        }));
        _fadeIn();
      } else if (player.playing) {
        try {
          await player.pause();
        } catch (_) {}
      }
      if (!alive()) return;
      _saveState(position);
      notifyListeners();
      _syncSystemMedia();
    } catch (e) {
      if (!alive()) return;
      debugPrint('[play] 转码 seek 失败《${cur.title}》: $e');
    }
  }

  // ---------- 断点（stage2.md §7） ----------

  void _maybeSaveState(Duration pos) {
    final now = DateTime.now();
    final key = _current == null ? null : _positionKeyOf(_current!);
    // 切歌：立即落一次（否则崩溃后回到上一首）；其余按 [_stateSaveInterval] 节流。
    final songChanged = key != _lastSavedSongKey;
    if (songChanged ||
        _lastStateSave == null ||
        now.difference(_lastStateSave!) >= _stateSaveInterval) {
      _lastStateSave = now;
      _lastSavedSongKey = key;
      unawaited(_saveState(pos));
    }
  }

  Future<void> _saveState(Duration pos, {bool forceBreakpoint = false}) async {
    final idx = _index;
    if (idx == null || _queue.isEmpty || _current == null) return;
    await idx.savePlayState(
      _encodedQueue(),
      _idx,
      pos.inMilliseconds,
      playlistUuid: _syncPlaylistUuid,
      anchorKey: _anchorKey,
    );
    await _maybeEnqueueBreakpoint(idx, pos, force: forceBreakpoint);
  }

  /// 暂停/停止后的最终断点：强制进一次 outbox（不受 25s 节流限），
  /// 落库完成后再 poke 即时同步，保证本轮 push 带走最终位置。
  void _saveForcedAndPoke() {
    if (_onSyncPoke == null || !_hasPlayScene) return;
    Duration pos;
    try {
      pos = position;
    } catch (_) {
      return;
    }
    _pokeSyncAfterSave(() => _saveState(pos, forceBreakpoint: true));
  }

  /// 关闸（启动恢复发起时）：见 [_bootConverged]。兜底超时防「同步从未
  /// 回调、闸门永闭」；30s 远大于快路径/首拉 + 恢复尾的耗时量级。
  void _closeBootGate() {
    _bootConverged = false;
    _bootGateTimer?.cancel();
    _bootGateTimer = Timer(const Duration(seconds: 30), () {
      _openBootGate('超时兜底');
    });
    perfLog('bp.bootGate close', '等待首个远端镜像判定');
  }

  /// 开闸（首个镜像判定跑完/超时兜底）：被挡下的强制断点在闸开后补跑一次。
  void _openBootGate(String why) {
    if (_bootConverged) return;
    _bootConverged = true;
    _bootGateTimer?.cancel();
    _bootGateTimer = null;
    perfLog('bp.bootGate open', why);
    if (_bootForcedPending) {
      _bootForcedPending = false;
      _saveForcedAndPoke();
    }
  }

  /// 阶段5 断点进 outbox（节流：同歌 25s 一次，切歌立即；暂停/停止强制一次）。
  /// 队列归属已同步歌单且当前歌曲有身份即上报：服务器模式恒上报，
  /// 直连歌曲需连着服务器；其它情况只活本机。
  /// 跳过/入队均有日志（[bp.skip]/[bp.enqueue]）：排查「断点没推上去」用。
  Future<void> _maybeEnqueueBreakpoint(LocalIndex idx, Duration pos,
      {bool force = false}) async {
    if (!_bootConverged) {
      // F1：启动恢复出的本机断点可能已被远端更新——等首个镜像判定给出
      // 结论（套用远端 / 确认本机最新）再入队；强制断点开闸后补跑。
      if (force) _bootForcedPending = true;
      _logBpSkip('启动收敛未完成（暂不推送，防旧态盖新）');
      return;
    }
    final uuid = _syncPlaylistUuid;
    final cur = _current;
    if (uuid == null || cur == null) {
      _logBpSkip(cur == null ? '无当前曲' : '无归属歌单（未绑定已同步歌单）');
      return;
    }
    if (cur.source.isEmpty ||
        cur.source == 'server' ||
        cur.sourceRef.isEmpty) {
      _logBpSkip('歌曲无同步身份（source/sourceRef 空）');
      return;
    }
    if (cur.sourceKey != 'server' && !(_serverAvailable?.call() ?? false)) {
      _logBpSkip('直连源且服务器不可用');
      return;
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final key = '$uuid|${cur.source}|${cur.sourceRef}';
    // occurred_at 语义=「最后操作时间」：非强制的落盘补写（回前台/退后台/退出
    // 落盘、周期保存）只在断点**真的变了**（切歌/位置前进）时才入队；暂停态
    // 原样补写直接跳过——否则会把本机陈旧断点盖上 now 推上服务端，被 LWW 收下
    // 后覆盖其它设备更新的进度（回前台补写毒源，与冷启动恢复同款）。
    if (!force && key == _lastBpKey && pos.inMilliseconds == _lastBpPosMs) {
      _logBpSkip('断点无变化（补写不刷新 occurred_at）');
      return;
    }
    if (force || key != _lastBpKey || nowMs - _lastBpAtMs > 25000) {
      _lastBpKey = key;
      _lastBpPosMs = pos.inMilliseconds;
      _lastBpAtMs = nowMs;
      _lastBpSkipReason = null;
      final sourceId = idx.sourceUuidOf(cur.sourceKey);
      final dl = _deepList;
      // 深层列表以身份数组随断点携带（有序 {source, source_ref}），对端按身份重建。
      final deepList = [
        for (final s in (dl?.entries ?? const <Song>[]))
          if (s.source.isNotEmpty && s.sourceRef.isNotEmpty)
            {'source': s.source, 'source_ref': s.sourceRef},
      ];
      final eventUuid = await idx.enqueueOutbox(SyncEventTypes.breakpointSet, {
        'playlist_uuid': uuid,
        'source': cur.source,
        'source_ref': cur.sourceRef,
        if (sourceId != null) 'source_id': sourceId,
        'position_ms': pos.inMilliseconds,
        'deep_list': deepList,
      });
      perfLog('bp.enqueue',
          'uuid=$eventUuid playlist=$uuid ref=${cur.sourceRef} pos=${pos.inMilliseconds}ms force=$force skew=${idx.clockSkew.inMilliseconds}ms');
    } else {
      _logBpSkip('节流中（同歌 25s 一次）');
    }
  }

  /// 断点跳过原因日志（同因只打一次，见 [_lastBpSkipReason]）。
  void _logBpSkip(String reason) {
    if (_lastBpSkipReason == reason) return;
    _lastBpSkipReason = reason;
    perfLog('bp.skip', reason);
  }

  /// 启动恢复（仅本机断点）：装载上次队列与位置，暂停态不自动播放。
  Future<void> restoreIfAny() {
    final idx = _index;
    if (idx == null || _restored) return Future<void>.value();
    _restored = true;
    _closeBootGate();
    _suppressSyncNotify = true;
    scheduleMicrotask(() => _suppressSyncNotify = false);
    final f = _restoreLocal(idx, idx.getPlayState());
    _restoreFuture = f;
    return f;
  }

  /// 启动恢复（跨设备优先）：本机与所有镜像断点中取最新者；
  /// 远端更新且其歌单在本机存在时，重建该歌单队列并从该进度恢复（暂停态）。
  Future<void> restorePreferRemote() {
    final idx = _index;
    if (idx == null || _restored) return Future<void>.value();
    _restored = true;
    _closeBootGate();
    // 同步恢复前缀在 Root.initState 的 build 期内执行，期间的 notify 会被
    // framework 断言（setState during build）；同步前缀结束时（首个 await 后
    // 的微任务）解除，后续异步阶段的通知照常。
    _suppressSyncNotify = true;
    scheduleMicrotask(() => _suppressSyncNotify = false);
    final f = _restorePreferRemoteInner(idx);
    _restoreFuture = f;
    return f;
  }

  Future<void> _restorePreferRemoteInner(LocalIndex idx) async {
    final local = idx.getPlayState();
    final best = _newestMirror(idx);
    final bestAt =
        best == null ? null : DateTime.tryParse(best.compareClock);
    final localAt = local == null ? null : DateTime.tryParse(local.updatedAt);
    if (best != null &&
        bestAt != null &&
        (localAt == null || bestAt.isAfter(localAt))) {
      if (await _restoreFromMirror(idx, best)) return;
    }
    await _restoreLocal(idx, local);
  }

  /// 当前全部断点镜像里「最后操作时间」最新的一行（无则 null；F4 比较时钟 =
  /// `lastEventAt ?? updatedAt`，与推送 LWW/服务端 /playstates/latest 同口径）。
  BreakpointMirrorRow? _newestMirror(LocalIndex idx) {
    BreakpointMirrorRow? best;
    DateTime? bestAt;
    for (final m in idx.allBreakpointMirrors()) {
      final t = DateTime.tryParse(m.compareClock);
      if (t == null) continue;
      if (bestAt == null || t.isAfter(bestAt)) {
        best = m;
        bestAt = t;
      }
    }
    return best;
  }

  /// 有比「当前会话所依据的断点」更新的远端镜像时切过去（歌曲+进度+深层列表）。
  ///
  /// 基准用 [_breakpointBaselineAt]（恢复时 adopted 的时间，或用户起播时的 now），
  /// **不是** `play_state.updated_at`——后者在 `_play` 起播时即被 `_saveState`
  /// 覆盖为客户端 now，用它比较会使远端镜像恒判更旧（跨设备续播永不生效的回归根因）。
  ///
  /// [viaSync]：由同步回调（手动「立即同步」/回前台）触发——此时不再受
  /// [_userTookOver] 限制（用户明确要套用）；无论何时，**正在播放时不打断**。
  ///
  /// single-flight：进行中再触发只记待办，收尾后用最新镜像补跑一次；且先等
  /// 首次恢复的异步尾（音频装载/seek）结束——两者并发会双重装载、连续换曲
  /// （冷启动断点快路径 + 多页 pull 回调解锁后的卡顿根因）。
  Future<void> applyNewerMirrorIfAny({bool viaSync = false}) async {
    final idx = _index;
    if (idx == null || !_restored || _shuttingDown) return;
    if (_applyingMirror) {
      _mirrorApplyQueued = true;
      if (viaSync) _mirrorApplyViaSync = true;
      perfLog('mirror.apply queued', 'viaSync=$viaSync（进行中，收尾后补跑）');
      return;
    }
    _applyingMirror = true;
    _mirrorApplyViaSync = viaSync;
    try {
      do {
        final sync = _mirrorApplyViaSync;
        _mirrorApplyQueued = false;
        _mirrorApplyViaSync = false;
        // 播放中绝不打断领播端（缓冲中的瞬态 false 由基准比较再兜一层）。
        if (_hasPlayScene && playing) {
          perfLog('mirror.apply skip', '正在播放不打断');
          return;
        }
        // 启动补切：用户已主动交互过则不再回切（viaSync 的显式同步不受此限）。
        if (!sync && _userTookOver) {
          perfLog('mirror.apply skip', '用户已接管');
          return;
        }
        final swWait = Stopwatch()..start();
        final restoring = _restoreFuture;
        if (restoring != null) await restoring;
        perfLog('mirror.apply waitRestore',
            '${swWait.elapsedMilliseconds}ms viaSync=$sync');
        if (_shuttingDown) {
          perfLog('mirror.apply skip', '应用退出中');
          return;
        }
        if (_hasPlayScene && playing) {
          perfLog('mirror.apply skip', '正在播放不打断（恢复尾后）');
          return;
        }
        if (!sync && _userTookOver) {
          perfLog('mirror.apply skip', '用户已接管（恢复尾后）');
          return;
        }
        final swLookup = Stopwatch()..start();
        final best = _newestMirror(idx);
        if (best == null) {
          perfLog('mirror.apply skip', '无断点镜像');
          return;
        }
        final bestAt = DateTime.tryParse(best.compareClock);
        if (bestAt == null) {
          perfLog('mirror.apply skip',
              '镜像比较时钟无效 uuid=${best.playlistUuid} clock=${best.compareClock} updated=${best.updatedAt}');
          return;
        }
        final base = _breakpointBaselineAt;
        perfLog('mirror.apply lookup', '${swLookup.elapsedMilliseconds}ms');
        if (base != null && !bestAt.isAfter(base)) {
          perfLog('mirror.apply skip',
              '镜像不新于基准 uuid=${best.playlistUuid} clock=${bestAt.toIso8601String()} base=${base.toIso8601String()}');
          return;
        }
        perfLog('mirror.apply adopt',
            'uuid=${best.playlistUuid} device=${best.deviceId} pos=${best.positionMs}ms clock=${bestAt.toIso8601String()} lastEvent=${best.lastEventAt} updated=${best.updatedAt} base=${base?.toIso8601String()} viaSync=$sync');
        final swApply = Stopwatch()..start();
        await _restoreFromMirror(idx, best);
        perfLog('mirror.apply restoreFromMirror',
            '${swApply.elapsedMilliseconds}ms uuid=${best.playlistUuid} viaSync=$sync');
      } while (_mirrorApplyQueued);
    } finally {
      _applyingMirror = false;
      // F1：首个镜像判定跑完即开闸——无论套用与否，「远端有什么」已掌握，
      // 此后本机状态（套用了远端或确认本机最新）可以正常上报。
      _openBootGate('首个镜像判定完成');
    }
  }

  Future<void> _restoreLocal(LocalIndex idx, PlayStateRow? st) async {
    final swAll = Stopwatch()..start();
    // 基准取「本机断点自身时间」：后续 `_play` 的 `_saveState` 会刷新
    // play_state.updated_at，但不会改这里，故远端更新的镜像仍可被套用。
    _breakpointBaselineAt = st == null ? null : DateTime.tryParse(st.updatedAt);
    if (st == null || st.queueJson.isEmpty) return;
    try {
      final list = (jsonDecode(st.queueJson) as List)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
      perfLog('restoreLocal decode',
          '${swAll.elapsedMilliseconds}ms n=${list.length}');
      if (list.isEmpty) {
        idx.clearPlayState();
        return;
      }
      final swResolve = Stopwatch()..start();
      _queue = _resolveLiveAll(list);
      perfLog('restoreLocal resolveLiveAll',
          '${swResolve.elapsedMilliseconds}ms n=${list.length}');
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
      // 恢复本机断点同样不立即回推（复用 25s 节流 + 装载后记录位置进
      // [_lastBpPosMs]：暂停态原样补写不再入队）：避免本机旧位置以更新的
      // occurred_at 覆盖正在播放的领播端；随后真实播放位置流会重新入队。
      _lastBpKey = '$_syncPlaylistUuid|${_current!.source}|${_current!.sourceRef}';
      _lastBpAtMs = DateTime.now().millisecondsSinceEpoch;
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
        // 乐观位置（同步前缀即设）：首帧进度条即停在断点，未在断点曲上则为 0。
        _restorePositionMs =
            (atBreakpoint && st.positionMs > 0) ? st.positionMs : 0;
        _restorePositionKey = _positionKeyOf(_current!);
        final restoredSong = _current!;
        await _play(_current!, play: false);
        // 装载期间用户可能已切歌：只对仍是恢复目标的当前曲 seek，不把新歌
        // 拽回旧断点（用户接管优先）。
        final cur = _current;
        if (cur != null &&
            _same(cur, restoredSong) &&
            atBreakpoint &&
            st.positionMs > 0) {
          await player.seek(Duration(milliseconds: st.positionMs));
        }
        // 真实 seek 完成（装载失败/no-op 同样经过这里）：乐观值退场。
        _clearRestorePosition();
        // 记录恢复后的真实位置：暂停态原样补写不再回推（无变化不刷 occurred_at）。
        _lastBpPosMs = position.inMilliseconds;
      }
      notifyListeners();
      _syncSystemMedia();
    } catch (e) {
      _clearRestorePosition();
      AppToast.error(e, '断点恢复失败');
      notifyListeners();
    }
  }

  /// 用远端断点重建歌单队列并恢复进度；目标歌本机无源时退到其后第一首可播条目。
  /// 镜像携带深层列表时，按身份重建该歌单的深层历史，并重建融合队列。
  Future<bool> _restoreFromMirror(LocalIndex idx, BreakpointMirrorRow m) async {
    final swAll = Stopwatch()..start();
    final pid = idx.playlistIdOfUuid(m.playlistUuid);
    if (pid == null) {
      perfLog('restoreMirror', 'no local playlist uuid=${m.playlistUuid}');
      return false;
    }
    final swSongs = Stopwatch()..start();
    final songs = idx.playlistSongs(pid);
    perfLog('restoreMirror playlistSongs',
        '${swSongs.elapsedMilliseconds}ms n=${songs.length}');
    if (songs.isEmpty) return false;
    final swFind = Stopwatch()..start();
    final refIndex = _refIndexMap(songs);
    final mirrorRef = m.sourceRef;
    final found = mirrorRef == null ? -1 : _refIndexOf(refIndex, mirrorRef);
    perfLog('restoreMirror findRef',
        '${swFind.elapsedMilliseconds}ms found=$found');
    var start = found < 0 ? 0 : found;
    while (start < songs.length &&
        !_playable(_resolver?.call(songs[start].sourceKey))) {
      start++;
    }
    if (start >= songs.length) return false;
    // 复用基座判定（D）：本机已绑定同一歌单时暂存旧基座；引用一致则跳过
    // 整队 resolve（单设备自回显的常见情形，1262 首 ~670ms UI 线程）。
    // 深层历史/融合队列/seek 照常按镜像重建，仅省掉 DB 查询与行映射。
    final prevBase =
        (_syncPlaylistUuid == m.playlistUuid) ? _fusedBase : null;
    _syncPlaylistUuid = m.playlistUuid;
    _bindDeepList(PlayerProvider.anchorForPlaylist(m.playlistUuid),
        listSize: songs.length);
    // 镜像深层列表（按身份匹配到本机歌单）→ 重建深层历史；缺失时保持本机。
    final swDeep = Stopwatch()..start();
    final dlEntries = _deepListFromMirror(m.deepListJson, songs, refIndex);
    perfLog('restoreMirror deepList',
        '${swDeep.elapsedMilliseconds}ms entries=${dlEntries.length}');
    if (dlEntries.isNotEmpty) {
      _deepList = DeepListController(
          capacity: songs.length, entries: dlEntries);
      _persistDeepList();
    }
    final swResolve = Stopwatch()..start();
    if (prevBase != null && _sameSongRefs(songs, prevBase)) {
      _fusedBase = prevBase;
      perfLog('restoreMirror resolveLiveAll',
          'reused ${swResolve.elapsedMilliseconds}ms n=${songs.length}');
    } else {
      _fusedBase = _resolveLiveAll(songs);
      perfLog('restoreMirror resolveLiveAll',
          '${swResolve.elapsedMilliseconds}ms n=${songs.length}');
    }
    _queue = _fusedQueue(_fusedBase!);
    _idx = _fusedIndexOf(start, songs).clamp(0, _queue.length - 1);
    _current = _queue[_idx];
    // 采用远端断点为当前状态：基准=镜像比较时钟（最后操作时间，F4），
    // 并对刚 adopted 的状态做一次回推节流——跟随端不应以更新的 occurred_at
    // 把暂停位置写回服务端、反过来覆盖正在播放的领播端（25s 节流 + 装载后
    // 记录位置：无变化补写永不回推）。
    _breakpointBaselineAt = DateTime.tryParse(m.compareClock);
    final adopted = _current!;
    _lastBpKey = '$_syncPlaylistUuid|${adopted.source}|${adopted.sourceRef}';
    _lastBpAtMs = DateTime.now().millisecondsSinceEpoch;
    // 乐观位置（同步前缀即设）：退到断点曲之后的首曲时为 0。
    final pos = (found >= 0 && start == found) ? m.positionMs : 0;
    perfLog('restoreMirror adopt',
        'uuid=${m.playlistUuid} device=${m.deviceId} ref=${m.sourceRef} pos=${pos}ms base=${m.compareClock} lastEvent=${m.lastEventAt} updated=${m.updatedAt} found=$found');
    _restorePositionMs = pos;
    _restorePositionKey = _positionKeyOf(_current!);
    final swPlay = Stopwatch()..start();
    try {
      await _play(_current!, play: false);
      perfLog('restoreMirror playLoad', '${swPlay.elapsedMilliseconds}ms');
      // 装载期间用户可能已切歌：只对仍是恢复目标的当前曲 seek（见 _restoreLocal）。
      final cur = _current;
      if (cur != null && _same(cur, adopted) && pos > 0) {
        await player.seek(Duration(milliseconds: pos));
      }
      // 真实 seek 完成：乐观值退场。
      _clearRestorePosition();
      // 记录采用后的真实位置：暂停态原样补写不再回推（无变化不刷 occurred_at）。
      _lastBpPosMs = position.inMilliseconds;
      notifyListeners();
      _syncSystemMedia();
      AppToast.show('已从其他设备继续播放（${_fmtMs(pos)}）', isError: false);
      perfLog('restoreMirror total',
          '${swAll.elapsedMilliseconds}ms uuid=${m.playlistUuid} pos=$pos');
      return true;
    } catch (_) {
      perfLog('restoreMirror FAILED', '${swAll.elapsedMilliseconds}ms');
      _clearRestorePosition();
      return false;
    }
  }

  /// 镜像身份列表 → 本机歌单匹配后的深层条目（坏行/无匹配跳过，保持顺序）。
  ///
  /// [refIndex] 为 [_refIndexMap] 预建的 ref→下标映射：此前对每条深层条目都
  /// `indexWhere` 全量扫描且每次比较重建 WebDAV 变体集合，O(条目×歌曲) 的
  /// 同步热点（启动恢复 366 条 × 1262 首实测 14.8s 卡死 UI 的根因）。
  List<Song> _deepListFromMirror(
      String? deepListJson, List<Song> songs, Map<String, int> refIndex) {
    if (deepListJson == null || deepListJson.isEmpty) return const [];
    try {
      final raw = jsonDecode(deepListJson);
      if (raw is! List) return const [];
      final out = <Song>[];
      final seen = <String>{};
      for (final e in raw) {
        if (e is! Map) continue;
        final ref = e['source_ref'];
        if (ref is! String || ref.isEmpty) continue;
        final i = _refIndexOf(refIndex, ref);
        if (i < 0) continue;
        final s = songs[i];
        if (seen.add('${s.sourceKey}\u0000${s.sourceRef}')) out.add(s);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// ref→歌单位（含 WebDAV 编码变体）预建索引；配合 [_refIndexOf] 使用。
  static Map<String, int> _refIndexMap(List<Song> songs) {
    final map = <String, int>{};
    for (var i = 0; i < songs.length; i++) {
      for (final v in webdavRefVariants(songs[i].sourceRef)) {
        map.putIfAbsent(v, () => i);
      }
    }
    return map;
  }

  /// 在 [_refIndexMap] 索引中按 ref（含编码变体）取下标；未命中返回 -1。
  static int _refIndexOf(Map<String, int> refIndex, String ref) {
    final direct = refIndex[ref];
    if (direct != null) return direct;
    for (final v in webdavRefVariants(ref)) {
      final i = refIndex[v];
      if (i != null) return i;
    }
    return -1;
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

  /// 播放成功后的深层列表维护：自动推进推入末尾，手动点播替换末尾。
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
    // 定位优先深层尾：刚播完的歌恒为深层尾，旧复本在前时不再指回旧行。
    final i = t == null
        ? -1
        : locateCurrentIndex(_queue, dl.length, t, _same);
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
  /// 若删的是当前曲，则播放下一首（被删曲在基座中的后一首，从头开始）——
  /// [deletedBaseIndex] 为被删曲在旧基座中的下标（歌单路径由调用方传入，
  /// 定位不到/删的是基座末尾时退回播新深层尾）。[anchorKey] 只作用于当前锚定上下文。
  Future<void> onAnchorSongRemoved(String anchorKey, Song s,
      {int? newCount, int? deletedBaseIndex}) async {
    final dl = _deepList;
    if (_anchorKey != anchorKey || dl == null) return;
    // 歌单里删掉的这首若正排在「下一首播放」，一并撤掉。
    if (_nextUp != null && _same(_nextUp!, s)) _nextUp = null;
    // 基座快照同步去掉死引用：删歌后旧基座里的残留不再参与续播拼接
    //（歌单路径基座已整体刷新，这里兜住喜欢/专辑等快照锚定）。
    _fusedBase?.removeWhere((e) => _same(e, s));
    if (newCount != null && newCount > 0) {
      dl.capacity = newCount;
    }
    final removedCurrent = _current != null && _same(_current!, s);
    dl.removeRef(s, same: _same);
    _persistDeepList();
    _rebuildFusedQueue(target: _current);
    if (!removedCurrent) return;
    Song? target;
    final fresh = _fusedBase;
    if (deletedBaseIndex != null &&
        fresh != null &&
        deletedBaseIndex >= 0 &&
        deletedBaseIndex < fresh.length) {
      target = fresh[deletedBaseIndex];
    }
    target ??= dl.tail;
    final resolved = target;
    if (resolved == null) return;
    final i = _queue.indexWhere((x) => _same(x, resolved));
    if (i >= 0) _idx = i;
    await _play(resolved, source: _curSource);
  }

  /// 歌单删歌联动（转锚定键统一处理）。
  Future<void> onPlaylistSongRemoved(String playlistUuid, Song s,
      {int? newPlaylistCount}) {
    // 歌单变了 → 融合基座同步刷新为最新歌单，否则续播段仍按删歌前的旧快照
    // 接续：删当前曲会从旧基座里复活、删已播曲会把前面的歌顶到当前曲后面。
    // 仅当前锚定且能读到非空新歌单时刷新；读不到沿用旧基座（既有行为）。
    // 另记下被删曲在旧基座中的下标，供删当前曲时定位「下一首」。
    final key = PlayerProvider.anchorForPlaylist(playlistUuid);
    int? deletedBaseIndex;
    if (_anchorKey == key && _fusedBase != null) {
      final stale = _fusedBase!;
      for (var i = 0; i < stale.length; i++) {
        if (_same(stale[i], s)) {
          deletedBaseIndex = i;
          break;
        }
      }
      final idx = _index;
      if (idx != null) {
        final pid = idx.playlistIdOfUuid(playlistUuid);
        if (pid != null) {
          final fresh = _resolveLiveAll(idx.playlistSongs(pid));
          if (fresh.isNotEmpty) _fusedBase = fresh;
        }
      }
    }
    return onAnchorSongRemoved(key, s,
        newCount: newPlaylistCount, deletedBaseIndex: deletedBaseIndex);
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
    unawaited(_audioFocusSub?.cancel());
    _audioFocusSub = null;
    // 清理路径：取消渐变 + 收口挂起的淡出 Future（不暂停）+ 复位意图位。
    _cancelFadeAndComplete();
    _fadingPause = false;
    _sleepTick?.cancel();
    // 先结清播放时长（含强制推送），再落库，保证最后一段不丢。
    try {
      await _playSecStop();
    } catch (_) {}
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
    _restoreResumeTarget = null;
    // 清理路径：取消渐变 + 收口挂起的淡出 Future（不暂停）+ 复位意图位。
    _cancelFadeAndComplete();
    _fadingPause = false;
    _sleepTick?.cancel();
    _bootGateTimer?.cancel();
    _bootGateTimer = null;
    _playbackGuard?.dispose();
    _playbackGuard = null;
    unawaited(_audioFocusSub?.cancel());
    _audioFocusSub = null;
    // 退出前把最后一段播放时长结清（与 _saveState 同样不等待）。
    unawaited(_playSecStop());
    final p = _player;
    _player = null;
    if (p != null) {
      unawaited(_saveState(p.position));
      unawaited(p.dispose());
    }
    super.dispose();
  }
}
