import 'dart:convert';
import 'dart:math' as math;

import '../local/local_index.dart';
import '../../models/song.dart';
import '../../utils/chunked_scheduler.dart' show yieldToEventLoop;
import '../../utils/main_thread_probe.dart';
import '../../utils/play_progress.dart';
import 'sync_event_types.dart';

/// 歌曲权重与收藏的统一点（stage2.md §1.5 / §2.1）。
///
/// - factor 连续取值 0.5 ≤ factor ≤ 1.5，步长 0.1，初始 1.0；唯一例外是
///   「不喜欢」锁定态 [dislikedFactor]（0.1，仅手动开关写入，不参与自动调权）。
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

  /// 「不喜欢」锁定态的固定权重：低于自动调权下限 [minFactor] 的**唯一**取值，
  /// 只由手动不喜欢开关（[setDisliked]）写入。抽样侧按原值计权——不乘时长削弱、
  /// 不被 [minFactor] 钳回（见 `PlayerProvider.effectiveWeight`）。
  static const double dislikedFactor = 0.1;

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

  String _metaKey(String sourceKey, String ref) => '$sourceKey\u0000$ref';

  bool hasMetaCached(Song s) =>
      _metaCache.containsKey(_metaKey(s.sourceKey, s.sourceRef));

  PlayMetaRow metaOf(Song s) {
    final key = _metaKey(s.sourceKey, s.sourceRef);
    final cached = _metaCache[key];
    if (cached != null) return cached;
    perfPhase('weight.metaOf.select'); // TEMP-PROBE
    final row = index.playMetaOf(s.sourceKey, s.sourceRef);
    if (_metaCache.length >= _metaCacheCap) _metaCache.clear();
    _metaCache[key] = row;
    return row;
  }

  void ensureMetaOf(Iterable<Song> songs) {
    final missing = <String, Set<String>>{};
    for (final s in songs) {
      if (s.sourceRef.isEmpty) continue;
      if (hasMetaCached(s)) continue;
      missing.putIfAbsent(s.sourceKey, () => <String>{}).add(s.sourceRef);
    }
    if (missing.isEmpty) return;
    for (final entry in missing.entries) {
      final refs = entry.value.toList(growable: false);
      if (_metaCache.length + refs.length > _metaCacheCap) _metaCache.clear();
      Map<String, PlayMetaRow> rows = const {};
      try {
        rows = index.playMetasOf(entry.key, refs);
      } catch (_) {
        continue;
      }
      for (final ref in refs) {
        _metaCache[_metaKey(entry.key, ref)] = rows[ref] ??
            PlayMetaRow(
              sourceKey: entry.key,
              songRef: ref,
              likeStreak: 0,
              dislikeStreak: 0,
              factor: defaultFactor,
              frozen: false,
              favorite: false,
            );
      }
    }
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
      if (hasMetaCached(s)) continue;
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

  /// 展示用有效权重：锁定态（「不喜欢」）恒为 [dislikedFactor]，其余取存储 factor。
  /// 抽样侧的同类口径见 `PlayerProvider.effectiveWeight`（还叠加时长削弱曲线）。
  double effectiveFactorOf(Song s) {
    final m = metaOf(s);
    return m.frozen ? dislikedFactor : m.factor;
  }

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

  /// 批量读整队抽样权重行（加权抽样用）：与 [factorsOf] 同款分组批量查询，
  /// 额外带 `frozen`（「不喜欢」锁定态）——抽样侧据此把锁定行按 [dislikedFactor]
  /// 计权。整行 [metaOf] 会带 `song_json` 大字段，队列每次推进都整表读不划算，
  /// 故单列查询。
  Map<String, Map<String, ({double factor, bool frozen})>> weightRowsOf(
      List<Song> songs) {
    final bySource = <String, List<String>>{};
    for (final s in songs) {
      bySource.putIfAbsent(s.sourceKey, () => []).add(s.sourceRef);
    }
    final result = <String, Map<String, ({double factor, bool frozen})>>{};
    bySource.forEach((key, refs) {
      final rows = index.playWeightRowsOf(key, refs);
      if (rows.isNotEmpty) result[key] = rows;
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

  /// 全历史播放进度中位数；无样本返回 null。
  double? medianProgressPercentOf(Song s) =>
      PlayProgressHistogram.fromJson(metaOf(s).progressHist).medianPercent;

  /// 记录一次播放进度样本（30%~95% 等无权重事件的离开）：只进直方图，
  /// 不改权重/streak/收藏/播放时长。与推送给服务端的 `song.progress` 同值。
  Future<void> recordProgress(Song s, int progressPct) async {
    if (s.sourceRef.isEmpty) return;
    final pct = clampProgressPercent(progressPct);
    await index.recordProgress(s.sourceKey, s.sourceRef, pct);
    _metaCache.clear();
    await _emit(s, SyncEventTypes.songProgress, {'progress_pct': pct});
  }

  /// 完播（播放时长 >95%，通常为自然结束）：like_streak++，dislike 清零（覆盖先前跳过）；
  /// streak≥3 且中位进度闸门通过 → factor+0.1（≤1.5）并清零；闸门未过保留 streak。
  /// 「不喜欢」（frozen）态只记 streak，不自动调权（权重锁定 [dislikedFactor]）。
  ///
  /// [progressPct] 为本次离开时的最终进度；有值时视为 tracked：同一写事务内先记样本
  /// 再评比，事件载荷带 `progress_pct`。旧调用不传则沿用单线规则。
  Future<void> onCompleted(Song s, {int? progressPct}) async {
    await _apply(s, 'complete',
        progressPct: progressPct, tracked: progressPct != null);
    await _emit(s, SyncEventTypes.songComplete,
        progressPct == null ? null : {'progress_pct': progressPct});
  }

  /// 中途跳过（播放时长 <30% 被打断）：dislike_streak++，like 清零（覆盖先前完播）；
  /// streak≥3 → factor−0.1（≥0.5）并清零。降权不看中位进度。
  /// 「不喜欢」（frozen）态只记 streak，不自动调权。
  Future<void> onSkipped(Song s, {int? progressPct}) async {
    await _apply(s, 'skip', progressPct: progressPct, tracked: progressPct != null);
    await _emit(s, SyncEventTypes.songSkipped,
        progressPct == null ? null : {'progress_pct': progressPct});
  }

  /// 手动点播后自然完播（改进.txt 功能7）：与 [onCompleted] 的 streak 门槛制不同，
  /// 权重直接提高一档（f=clamp(f+0.1)）并清零累计的完播/切歌次数——用户主动
  /// 点选并听完一首，本身就是强正面信号。
  ///
  /// [tracked] 为 true 时同样要过中位进度闸门（升权）；失败保留权重与 streak。
  /// 本次播放的进度样本已由前一条 complete 记录，本事件不重复采样。
  /// 「不喜欢」锁定态不动权重。
  Future<void> onCompletedManual(Song s, {bool tracked = false}) async {
    await _apply(s, 'complete_manual', tracked: tracked);
    await _emit(s, SyncEventTypes.songCompleteManual,
        tracked ? {'tracked': true} : null);
  }

  /// 主动喜欢 / 收藏：factor 直接拉到 1.5，同时解除「不喜欢」锁定。
  Future<void> setLiked(Song s) async {
    await _apply(s, 'liked', songJson: jsonEncode(s.toJson()));
    await _emit(s, SyncEventTypes.songLiked);
  }

  /// 取消喜欢 / 收藏：非锁定态 factor 回落 1.0；「不喜欢」锁定态保持 [dislikedFactor]。
  Future<void> setUnliked(Song s) async {
    await _apply(s, 'unfavorite');
    await _emit(s, SyncEventTypes.songUnfavorite);
  }

  /// 是否处于「不喜欢」态（权重锁定 [dislikedFactor]）。
  bool isDisliked(Song s) => metaOf(s).frozen;

  /// 手动「不喜欢」开关：开 → 权重直接降到 [dislikedFactor]（低于自动调权下限
  /// 的特殊档）并锁定（跳过自动调权）；关 → 解锁并回到 1.0；不影响收藏状态。
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
  /// 采集侧（[PlayerProvider]）按挂钟累计，只在 20s 批量/暂停/切歌/退出时成批落库，
  /// 不逐秒写。跨设备同步走 `song.state` 绝对态节流推送（见 [syncPlaySec]），
  /// 避免 outbox 被逐秒事件刷屏。
  Future<void> addPlaySec(Song s, int seconds) {
    if (seconds <= 0) return Future<void>.value();
    if (s.sourceRef.isEmpty) return Future<void>.value();
    return index.addPlaySec(s.sourceKey, s.sourceRef, seconds);
  }

  /// 播放时长上推节流：同首歌两次推送至少间隔 [playSecPushInterval]，
  /// `force=true`（暂停/切歌/退出）不受限。调用方须先 `await addPlaySec`，
  /// 此处读到的即含本次增量的累计值，随 `song.state` 绝对态上推
  /// （服务端按 `max` 合并，旧值晚到不回退；缺键保持权重字段，见 SyncService）。
  static Duration playSecPushInterval = const Duration(minutes: 5);

  final Map<String, DateTime> _lastPlaySecPush = {};

  /// 测试用：清空节流记忆。
  void clearPlaySecPushThrottleForTest() => _lastPlaySecPush.clear();

  Future<bool> syncPlaySec(Song s,
      {bool force = false, DateTime? nowForTest}) async {
    if (s.sourceRef.isEmpty) return false;
    if (s.source.isEmpty || s.source == 'server') return false;
    if (s.sourceKey != 'server' && !(serverAvailable?.call() ?? false)) {
      return false;
    }
    final key = '${s.sourceKey}\u0000${s.sourceRef}';
    final now = nowForTest ?? DateTime.now();
    final last = _lastPlaySecPush[key];
    if (!force &&
        last != null &&
        now.difference(last) < playSecPushInterval) {
      return false;
    }
    PlayMetaRow m;
    try {
      m = index.playMetaOf(s.sourceKey, s.sourceRef);
    } catch (_) {
      return false;
    }
    if (m.playSec <= 0) return false;
    var protocol = s.source;
    if (protocol.isEmpty || protocol == 'server') {
      protocol = index.getSource(s.sourceKey)?.kind ?? '';
    }
    if (protocol.isEmpty || protocol == 'server') return false;
    final sourceId = index.sourceUuidOf(s.sourceKey);
    await index.enqueueOutbox(SyncEventTypes.songState, {
      'source': protocol,
      'source_ref': s.sourceRef,
      if (sourceId != null) 'source_id': sourceId,
      'like_streak': m.likeStreak,
      'dislike_streak': m.dislikeStreak,
      'weight': m.factor,
      'frozen': m.frozen,
      'is_favorite': m.favorite,
      'play_sec': m.playSec,
    });
    if (_lastPlaySecPush.length > 20000) _lastPlaySecPush.clear();
    _lastPlaySecPush[key] = now;
    return true;
  }

  /// 阶段5：有歌曲身份（source/sourceRef 非空、可解析）即进 outbox；服务端按
  /// (source, source_ref) 解析，直连歌曲无行则建影子行（DEVELOPER.md「播放算法与同步协议」）。
  /// 服务器模式行恒进（行存在即配过服务器）；直连歌曲需连着服务器
  ///（[serverAvailable] 为假时跳过，避免未配对用户 outbox 积压）。
  /// source=='server' 占位（归属源未知）仍跳过，避免跨源误归属。
  /// 权重事件落库：读改写整段在写连接内完成（见 LocalIndex.applyWeightEvent）。
  Future<void> _apply(Song s, String event,
      {bool? enabled,
      String? songJson,
      int? progressPct,
      bool tracked = false}) async {
    await index.applyWeightEvent(s.sourceKey, s.sourceRef, event,
        enabled: enabled,
        songJson: songJson,
        progressPct: progressPct,
        tracked: tracked,
        minFactor: minFactor,
        maxFactor: maxFactor,
        step: step,
        defaultFactor: defaultFactor,
        dislikedFactor: dislikedFactor);
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
  /// 绝对态事件（streak/factor/frozen/favorite 全量）。
  /// source_key=='server' 的行走常规 outbox（恒进事件），跳过；
  /// 门控与 [_emit] 一致。返回补推歌曲数。
  ///
  /// 事件带 `backfill:true`：服务端对补录事件“只建行、不赢现行行”
  /// （首配空库照常建；重配旧设备不再冲掉现行数据，判输回 correction 自纠）。
  Future<int> backfill() async {
    var n = 0;
    for (final m in index.listDirtyPlayMeta()) {
      if (m.sourceKey == 'server') continue;
      final protocol = index.getSource(m.sourceKey)?.kind ?? '';
      if (protocol.isEmpty || protocol == 'server') continue;
      if (!(serverAvailable?.call() ?? false)) continue;
      final sourceId = index.sourceUuidOf(m.sourceKey);
      await index.enqueueOutbox(SyncEventTypes.songState, {
        'backfill': true,
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
      // 配对前的进度样本没有逐条事件：补一条基线直方图（服务端按桶 max，
      // 与普通样本事件共存也不会重复计数）。
      final hist = PlayProgressHistogram.fromJson(m.progressHist);
      if (!hist.isEmpty) {
        await index.enqueueOutbox(SyncEventTypes.songProgress, {
          'baseline': true,
          'source': protocol,
          'source_ref': m.songRef,
          if (sourceId != null) 'source_id': sourceId,
          'progress_hist': hist.toList(),
        });
      }
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
