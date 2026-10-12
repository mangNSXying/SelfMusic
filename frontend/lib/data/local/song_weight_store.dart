import 'dart:convert';
import 'dart:math' as math;

import '../local/local_index.dart';
import '../../models/song.dart';
import '../../utils/chunked_scheduler.dart' show yieldToEventLoop;
import '../../utils/main_thread_probe.dart';
import 'sync_event_types.dart';

/// 歌曲权重与收藏的统一点（stage2.md §1.5 / §2.1）。
///
/// - factor 连续取值 0.5 ≤ factor ≤ 1.5，步长 0.1，初始 1.0。
/// - 事件（complete/skip/liked/unfavorite/reset）驱动 factor 调整，写回 play_meta。
/// - 完播/跳过按「播放时长 >95% 记完播、<30% 记跳过」（30%~95% 不记）由上层判定后
///   分发到 [onCompleted]/[onSkipped]；同一首歌的完播与跳过次数互斥——每次事件
///   都会清零另一侧计数（后来者覆盖先前值），不会同时累计。
/// - 收藏状态统一收口到 play_meta（直连 + 服务器一致）。
class SongWeightStore {
  static const double minFactor = 0.5;
  static const double maxFactor = 1.5;
  static const double step = 0.1;
  static const double defaultFactor = 1.0;

  final LocalIndex index;

  /// 服务器可达性门控（DirectSourceManager 注入 `isServerAvailable`）：
  /// 直连歌曲仅在连着服务器时进 outbox，避免未配对用户 outbox 无限积压。
  final bool Function()? serverAvailable;

  SongWeightStore(this.index, {this.serverAvailable});

  /// play_meta 行缓存：列表每行 build 都读收藏/不喜欢态，逐行同步查库是滑动期
  /// 的主要重复 I/O。写路径（本 store / 同步落库回调）显式失效，保证即时性。
  final Map<String, PlayMetaRow> _metaCache = {};

  /// 缓存上限：快速滑过长列表时防止无界堆积（超限整体清空重新暖）。
  static const int _metaCacheCap = 20000;

  PlayMetaRow metaOf(Song s) {
    final key = '${s.sourceKey}\u0000${s.sourceRef}';
    final cached = _metaCache[key];
    if (cached != null) return cached;
    perfPhase('weight.metaOf.select'); // TEMP-PROBE
    final row = index.playMetaOf(s.sourceKey, s.sourceRef);
    if (_metaCache.length >= _metaCacheCap) _metaCache.clear();
    _metaCache[key] = row;
    return row;
  }

  /// 外部路径（同步引擎 pull 落库等）写 play_meta 后调用：失效行缓存。
  void notifyExternalWrite() => _metaCache.clear();

  /// 预热批大小（每批一次 IN 查询）：一次预热覆盖的歌曲子集**有界**，批间让出
  /// 事件循环，保证单次同步块 < 50ms（主线程长同步块治理 R-3 / FR-002）。旧实现
  /// 以整表一次性批量查 `play_meta`（真机探针 ~1470ms 单次阻塞）。
  static const int _warmBatch = 300;

  /// 批量预热列表元数据：按 sourceKey 分组、**分批** IN 查询填满 [_metaCache]。
  ///
  /// 供冷列表首帧后由 [SongRowCache] 编排（post-frame）调用，替代首进页面时
  /// 「整表逐行 metaOf = 数千条同步 SELECT 挤在同一帧」。无匹配行不写入，仍由
  /// [metaOf] 走默认行兜底；写路径（[_apply] / [notifyExternalWrite]）本就会清空
  /// 全缓存，此处填充不存在脏读。
  ///
  /// **主线程切片让出（R-3 / FR-002）**：不再整表一次同步查库；按 [_warmBatch]
  /// 分批、批间 `await` 让出，单次同步块有界。返回的 Future 调用方（`onWarm`）
  /// 通常不 await——预热在后台 tick 推进，语义（最终填满缓存）不变。
  Future<void> warmMetaOf(Iterable<Song> songs) async {
    perfPhase('weight.warmMetaOf'); // TEMP-PROBE
    final bySource = <String, List<String>>{};
    for (final s in songs) {
      if (s.sourceRef.isEmpty) continue;
      bySource.putIfAbsent(s.sourceKey, () => []).add(s.sourceRef);
    }
    for (final entry in bySource.entries) {
      final key = entry.key;
      final refs = entry.value;
      for (var start = 0; start < refs.length; start += _warmBatch) {
        final end = math.min(start + _warmBatch, refs.length);
        try {
          final rows = index.playMetasOf(key, refs.sublist(start, end));
          if (rows.isNotEmpty) {
            if (_metaCache.length + rows.length > _metaCacheCap) {
              _metaCache.clear();
            }
            _metaCache.addAll({
              for (final e in rows.entries) '$key\u0000${e.key}': e.value,
            });
          }
        } catch (_) {
          // 预热失败静默：逐行 [metaOf] 仍走同步兜底查询，不影响功能与结果。
        }
        if (end < refs.length) await yieldToEventLoop();
      }
    }
  }

  double factorOf(Song s) => metaOf(s).factor;

  /// 批量读整队权重（加权抽样用）：按 sourceKey 分组各一次批量查询，
  /// 返回 map<sourceKey, map<songRef, factor>>；未记录的歌曲不放入，
  /// 上层取 [defaultFactor]，避免对每首歌在主连接做一次同步查库。
  Map<String, Map<String, double>> factorsOf(List<Song> songs) {
    final bySource = <String, List<String>>{};
    for (final s in songs) {
      bySource.putIfAbsent(s.sourceKey, () => []).add(s.sourceRef);
    }
    final result = <String, Map<String, double>>{};
    bySource.forEach((key, refs) {
      final factors = index.playFactorsOf(key, refs);
      if (factors.isNotEmpty) result[key] = factors;
    });
    return result;
  }

  /// 批量读整队播放时长（秒）：与 [factorsOf] 同款分组，供播放时长/次数排序。
  Map<String, Map<String, int>> playSecsOf(List<Song> songs) {
    final bySource = <String, List<String>>{};
    for (final s in songs) {
      bySource.putIfAbsent(s.sourceKey, () => []).add(s.sourceRef);
    }
    final result = <String, Map<String, int>>{};
    bySource.forEach((key, refs) {
      final secs = index.playSecsOf(key, refs);
      if (secs.isNotEmpty) result[key] = secs;
    });
    return result;
  }

  /// 排序键预取：权重/播放统计排序一次批量查询，替代逐首 `factorOf/playSecOf`
  /// 同步查库（几千首 = 几千条 SELECT，正是切页/初始化那一帧的卡顿来源）。
  SongSortKeys sortKeysOf(List<Song> songs,
      {bool factors = false, bool playSecs = false}) {
    perfPhase('weight.sortKeysOf'); // TEMP-PROBE
    return SongSortKeys(
      factors: factors ? factorsOf(songs) : const {},
      playSecs: playSecs ? playSecsOf(songs) : const {},
    );
  }

  /// 累计播放时长（秒）（播放时长/播放次数排序用；播放次数由其派生）。
  int playSecOf(Song s) => metaOf(s).playSec;

  bool isFavorite(Song s) => metaOf(s).favorite;

  /// 完播（播放时长 >95%，通常为自然结束）：like_streak++，dislike 清零（覆盖先前跳过）；
  /// streak≥3 → factor+0.1（≤1.5）并清零。
  /// 「不喜欢」（frozen）态只记 streak，不自动调权（权重锁定最低）。
  Future<void> onCompleted(Song s) async {
    await _apply(s, 'complete');
    await _emit(s, SyncEventTypes.songComplete);
  }

  /// 中途跳过（播放时长 <30% 被打断）：dislike_streak++，like 清零（覆盖先前完播）；
  /// streak≥3 → factor−0.1（≥0.5）并清零。
  /// 「不喜欢」（frozen）态只记 streak，不自动调权。
  Future<void> onSkipped(Song s) async {
    await _apply(s, 'skip');
    await _emit(s, SyncEventTypes.songSkipped);
  }

  /// 手动点播后自然完播（改进.txt 功能7）：与 [onCompleted] 的 streak 门槛制不同，
  /// 权重直接提高一档（f=clamp(f+0.1)）并清零累计的完播/切歌次数——用户主动
  /// 点选并听完一首，本身就是强正面信号。「不喜欢」锁定态不动权重。
  Future<void> onCompletedManual(Song s) async {
    await _apply(s, 'complete_manual');
    await _emit(s, SyncEventTypes.songCompleteManual);
  }

  /// 主动喜欢 / 收藏：factor 直接拉到 1.5，同时解除「不喜欢」锁定。
  Future<void> setLiked(Song s) async {
    await _apply(s, 'liked', songJson: jsonEncode(s.toJson()));
    await _emit(s, SyncEventTypes.songLiked);
  }

  /// 取消喜欢 / 收藏：非锁定态 factor 回落 1.0；「不喜欢」锁定态保持最低权重。
  Future<void> setUnliked(Song s) async {
    await _apply(s, 'unfavorite');
    await _emit(s, SyncEventTypes.songUnfavorite);
  }

  /// 是否处于「不喜欢」态（权重锁定最低）。
  bool isDisliked(Song s) => metaOf(s).frozen;

  /// 手动「不喜欢」开关：开 → 权重直接降到最低并锁定（跳过自动调权）；
  /// 关 → 解锁并回到 1.0；不影响收藏状态。
  Future<void> setDisliked(Song s, bool disliked) async {
    await _apply(s, 'disliked', enabled: disliked);
    await _emit(s, SyncEventTypes.songDisliked, {'enabled': disliked});
  }

  /// 手动重置：双 streak 清零，factor=1.0，解除「不喜欢」锁定。
  Future<void> reset(Song s) {
    return _apply(s, 'reset');
  }

  /// 累计播放时长（秒）入账：改进.txt 要求「播放时长精确到秒、播放次数由它派生」。
  ///
  /// 采集侧（[PlayerProvider]）按挂钟累计，只在暂停/切歌/退出时成批落库，
  /// 不逐秒写。不同步事件：播放时长是本地累计量，同步走 `song.state` 绝对态
  /// （见 [backfill] 与同步引擎的快照回写），避免 outbox 被逐秒事件刷屏。
  Future<void> addPlaySec(Song s, int seconds) {
    if (seconds <= 0) return Future<void>.value();
    if (s.sourceRef.isEmpty) return Future<void>.value();
    return index.addPlaySec(s.sourceKey, s.sourceRef, seconds);
  }

  /// 阶段5：有歌曲身份（source/sourceRef 非空、可解析）即进 outbox；服务端按
  /// (source, source_ref) 解析，直连歌曲无行则建影子行（DEVELOPER.md「播放算法与同步协议」）。
  /// 服务器模式行恒进（行存在即配过服务器）；直连歌曲需连着服务器
  ///（[serverAvailable] 为假时跳过，避免未配对用户 outbox 积压）。
  /// source=='server' 占位（归属源未知）仍跳过，避免跨源误归属。
  /// 权重事件落库：读改写整段在写连接内完成（见 LocalIndex.applyWeightEvent）。
  Future<void> _apply(Song s, String event,
      {bool? enabled, String? songJson}) async {
    await index.applyWeightEvent(s.sourceKey, s.sourceRef, event,
        enabled: enabled,
        songJson: songJson,
        minFactor: minFactor,
        maxFactor: maxFactor,
        step: step,
        defaultFactor: defaultFactor);
    _metaCache.clear();
  }

  Future<void> _emit(Song s, String type, [Map<String, dynamic>? extra]) async {
    if (s.source.isEmpty || s.source == 'server' || s.sourceRef.isEmpty) {
      return;
    }
    if (s.sourceKey != 'server' && !(serverAvailable?.call() ?? false)) {
      return;
    }
    final sourceId = index.sourceUuidOf(s.sourceKey);
    await index.enqueueOutbox(type, {
      'source': s.source,
      'source_ref': s.sourceRef,
      if (sourceId != null) 'source_id': sourceId,
      if (extra != null) ...extra,
    });
  }

  /// 补推存量权重（配对前数据无事件用）：为非默认 play_meta 行补 song.state
  /// 绝对态事件（streak/factor/frozen/favorite 全量，服务端 LWW）。
  /// source_key=='server' 的行走常规 outbox（恒进事件），跳过；
  /// 门控与 [_emit] 一致。返回补推歌曲数。
  Future<int> backfill() async {
    var n = 0;
    for (final m in index.listDirtyPlayMeta()) {
      if (m.sourceKey == 'server') continue;
      final protocol = index.getSource(m.sourceKey)?.kind ?? '';
      if (protocol.isEmpty || protocol == 'server') continue;
      if (!(serverAvailable?.call() ?? false)) continue;
      final sourceId = index.sourceUuidOf(m.sourceKey);
      await index.enqueueOutbox(SyncEventTypes.songState, {
        'source': protocol,
        'source_ref': m.songRef,
        if (sourceId != null) 'source_id': sourceId,
        'like_streak': m.likeStreak,
        'dislike_streak': m.dislikeStreak,
        'weight': m.factor,
        'frozen': m.frozen,
        'is_favorite': m.favorite,
        'play_sec': m.playSec,
      });
      n++;
    }
    return n;
  }
}

/// [SongWeightStore.sortKeysOf] 的批量排序键：按 sourceKey 分组预取，
/// 排序比较阶段零查询；未记录的歌曲取默认值（factor 1.0 / playSec 0）。
class SongSortKeys {
  final Map<String, Map<String, double>> factors;
  final Map<String, Map<String, int>> playSecs;

  const SongSortKeys({this.factors = const {}, this.playSecs = const {}});

  double factorOf(Song s) =>
      factors[s.sourceKey]?[s.sourceRef] ?? SongWeightStore.defaultFactor;

  int playSecOf(Song s) => playSecs[s.sourceKey]?[s.sourceRef] ?? 0;
}
