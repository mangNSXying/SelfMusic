import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/local/app_settings.dart';
import '../data/local/local_index.dart';
import '../data/local/sync_entity_key.dart';
import '../data/local/sync_event_types.dart';
import '../utils/perf_log.dart';
import 'api_client.dart';

/// 阶段5 多设备状态同步引擎·客户端（DEVELOPER.md「播放算法与同步协议」，字段级合并）。
///
/// 循环：push（outbox→`/sync/push`，2s 防抖批量）→ pull（`/sync/pull` 增量）→
/// 落库（权重/歌单/断点镜像）→ 推进 cursor。运行时播放只读本地 SQLite（事实源），
/// 本引擎只负责把远端收敛结果搬进来、把本地变更搬出去。
///
/// 触发：[start] 后 2s tick（有未确认事件立刻推；否则 30s 拉一次）+
/// 启动/回前台/手动 [syncNow]/播放操作 [poke]。冷启动首轮只拉不推（先掌握
/// 远端再上报积压；推由后续全量轮承担），其余轮次先推后拉。无 connectivity
/// 依赖：断网时请求抛错进退避，恢复后下一次 tick 自动追上（退避上限 30s）。
///
/// 本机优先：常规轮先推后拉（冷启动首轮只拉）；pull 快照命中“本地还有未推
/// 事件”的实体时跳过，不覆盖本地脏行（等 push ack 后下一轮收敛）。push
/// 回包的 corrections 是刚推完的仲裁结果，不受此限、照常自纠。
class SyncEngine {
  /// 定时器周期。非常量：测试可临时调小，免得像生产那样真等 2s。
  @visibleForTesting
  static Duration tickFast = const Duration(seconds: 2);
  static const _pullInterval = Duration(seconds: 30);
  static const _maxBackoff = Duration(seconds: 30);
  static const _maxPullPages = 10;

  final ApiClient api;
  final LocalIndex index;
  final AppSettings settings;

  Timer? _tick;
  Future<void>? _inflight;
  bool _dirty = false;
  DateTime? _lastPullAt;
  DateTime? _lastFailAt;
  int _failCount = 0;

  /// 早退类日志（未启用/未配对/退避中）节流：最多每 60s 一条，
  /// 避免 2s tick 反复打同一行（tick 会不断重试）。
  DateTime? _lastIdleLogAt;

  void _logIdle(String reason) {
    final now = DateTime.now();
    final last = _lastIdleLogAt;
    if (last != null && now.difference(last) < const Duration(seconds: 60)) {
      return;
    }
    _lastIdleLogAt = now;
    perfLog('sync.idle', reason);
  }

  /// 最近一次同步结果（UI 展示/调试用）。
  String lastError = '';
  int lastPushed = 0;
  int lastPulledSongs = 0;
  int lastPulledPlaylists = 0;

  /// 同步落库后源集合发生变化时的回调（重建内存源列表/刷新 UI）。
  void Function()? onSourcesApplied;
  bool _sourcesDirty = false;

  /// 歌单快照落库后的回调：PlaylistsProvider 缓存了歌单列表，
  /// 需显式 refresh 新同步到的歌单才会显示（对标 onSourcesApplied）。
  /// 仅当本轮真有歌单变更时触发一次，**并携带本轮变更的歌单 uuid 集合**——
  /// 消费方据此做增量刷新（只重查变更歌单的条目计数），避免 N+1 全量重查。
  void Function(Set<String> uuids)? onPlaylistsApplied;
  bool _playlistsDirty = false;
  final Set<String> _dirtyPlaylistUuids = {};

  /// 歌曲权重快照落库后的回调：收藏/权重状态变了但列表数据没版本变化，
  /// 不通知则喜欢页与列表行仍显示旧态（对标 onSourcesApplied）。
  void Function()? onSongStatesApplied;
  bool _songStatesDirty = false;

  /// 断点镜像落库后的回调：新拉到的远端断点（当前曲/进度/深层列表）需由
  /// 播放器在空闲时套用（启动补切 / 回前台 / 手动「立即同步」）。仅本轮真有
  /// 断点变更时触发一次（对标 onSongStatesApplied）。
  void Function()? onBreakpointsApplied;
  bool _breakpointsDirty = false;

  /// push 返回深层列表合并快照时的回调（快照, 本设备刚推的 deep_list）。
  /// 与 [onBreakpointsApplied] 不同：这里只更新历史，不 seek/不打断播放。
  Future<void> Function(Map<String, dynamic> snapshot, List<dynamic> sent)?
      onBreakpointMerged;

  /// v2 push 回执：按 playlist 返回权威 head+history 快照。
  Future<void> Function(Map<String, dynamic> snapshot, List<dynamic> sent)?
      onBreakpointSnapshot;

  /// 服务端协议声明（v2=true；旧服务端不回调/回调 false）。
  Future<void> Function(bool v2, String? serverEpoch)? onBreakpointProtocol;

  /// 断点事件被服务端死信：值是该事件的 op_id（旧事件可能为空）。播放器只
  /// 清匹配的 pending head，避免误清刚产生的更新操作。
  void Function(Map<String, String> opByPlaylist)? onBreakpointRejected;

  /// 断点事件已被服务端处理（applied/duplicates）：值是该事件的 op_id。
  /// 播放器据此只清「对应的」pending head，不误清新开播的更新操作。
  Future<void> Function(Map<String, String> opByPlaylist)? onBreakpointAcked;

  Future<void> _noteBreakpointProtocol(Object? data) async {
    if (data is! Map) return;
    // 旧服务端完全没有该字段：不能回调 false 把刚识别出的 v2 又降级。
    if (!data.containsKey('breakpoint_protocol')) return;
    final v2 = (data['breakpoint_protocol'] as num?)?.toInt() == 2;
    final epoch = data['server_epoch'];
    final cb = onBreakpointProtocol;
    if (cb != null) await cb(v2, epoch is String ? epoch : null);
  }

  SyncEngine({required this.api, required this.index, required this.settings});

  /// 应用是否在前台。false 且未播放时 [start] 的定时器不触发同步，避免
  /// 应用退到后台后仍每 [tickFast]（2s）醒来一次做网络 IO——无前台服务撑着
  /// 时纯烧流量/电，且 Android 后台限制下大概率直接失败重试。
  /// 播放中后台例外：前台服务保活下网络可用，断点/权重继续收敛
  /// （见 [_playing] 门控，四端一致、不做平台判断）。
  bool _appForeground = true;

  /// 是否在发声（PlayerProvider 经 [setPlaying] 注入实际引擎态）。
  bool _playing = false;

  /// 播放态变化（含自动续播/守卫暂停全路径，由播放状态流驱动）。
  void setPlaying(bool playing) {
    if (_playing == playing) return;
    _playing = playing;
    _updatePolling();
  }

  /// 关键操作后的即时同步（播放/暂停/切歌）：单飞合并，已在飞行只记待办；
  /// 退避窗口内按既有口径跳过（不断网锤），下个 tick 自动追上。
  void poke() {
    unawaited(syncNow());
  }

  /// 按“前台或播放中”重算定时器启停（pause/resume/setPlaying 共用）。
  void _updatePolling() {
    if (_appForeground || _playing) {
      _tick ??= Timer.periodic(tickFast, (_) => unawaited(_onTick()));
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  /// 退到后台：未播放则停表（已在飞行中的一轮不打断，[_inflight] 自会收尾，
  /// 只是不再发起新的）；播放中后台保持同步。
  void pause() {
    if (!_appForeground) return;
    _appForeground = false;
    _updatePolling();
  }

  /// 回前台：重新起表；快路径先取最新断点；若积压了 outbox 或已过拉取间隔，立刻补一轮。
  void resume() {
    if (_appForeground) return;
    _appForeground = true;
    _updatePolling();
    unawaited(pullLatestBreakpoint());
    unawaited(_onTick());
  }

  void start() {
    stop();
    if (!_appForeground && !_playing) return; // 后台且未播放：等 resume()/setPlaying(true)
    _tick = Timer.periodic(tickFast, (_) => unawaited(_onTick()));
    // 快路径先行：最新断点 1 RTT 到手，不受全量 pull 分页 backlog 拖累
    // （旧服务端 404 → 静默回退，全量 pull 仍是兜底）。
    unawaited(pullLatestBreakpoint());
    // 冷启动首轮只拉不推：先掌握远端最新（其它设备可能已前进），再上报积压。
    // 首轮在飞行时 tick 被单飞挡下，收尾后首个 tick（2s）见积压才发全量轮
    // （先推后拉）——「先拉后推」自然成立，不需要额外闸门。
    unawaited(syncNow(pullOnly: true));
  }

  /// 断点快路径（启动/回前台触发）：`GET /playstates/latest` 直取服务端最新
  /// 断点并落镜像+通知，1 个 RTT，不随 pull cursor backlog 分页。
  /// 失败只记日志、不进退避——它是全量 pull 的加速器而非替代。
  /// 每个静默返回分支都记 skip 日志（排查「断点为什么没同步过来」）。
  Future<void> pullLatestBreakpoint() async {
    if (!settings.syncEnabled) return;
    if (api.baseUrl.isEmpty) return;
    final sw = Stopwatch()..start();
    try {
      final clientId = await api.getClientId();
      if (clientId == null || clientId.isEmpty) {
        perfLog('fastPath.skip', '未配对');
        return;
      }
      final snap = await api.fetchLatestBreakpoint();
      if (snap == null) {
        perfLog('fastPath.skip',
            '${sw.elapsedMilliseconds}ms 服务端无断点/端点不可用');
        return;
      }
      final uuid = snap['client_uuid'];
      if (uuid is! String || uuid.isEmpty) {
        perfLog('fastPath.skip', '快照缺 client_uuid');
        return;
      }
      await _noteBreakpointProtocol(snap);
      final v2 = (snap['breakpoint_protocol'] as num?)?.toInt() == 2;
      // F2 自写回声过滤：本设备推上去的断点再被拉回来时，本机运行时状态必然
      // 不旧于它；落镜像/通知套用只会把旧快照盖回本机（毒化回路的一环）。
      // v2 例外：快照可能含对端历史分支，且 head/history rev 可安全去重。
      final device = snap['device_client_id'];
      if (!v2 && device is String && device == clientId) {
        perfLog('fastPath.skip',
            '${sw.elapsedMilliseconds}ms 自写回声（本设备 device=$device）uuid=$uuid pos=${snap['position_ms']}');
        return;
      }
      await index.applyPlaystateMirror(snap);
      // 歌单未同步/已删时镜像未落（applyPlaystateMirror 会丢弃），无从套用就不通知。
      if (index.breakpointMirrorOf(uuid) == null) {
        perfLog('fastPath.skip',
            '镜像未落（歌单未同步/已删）uuid=$uuid device=${snap['device_client_id']}');
        return;
      }
      _breakpointsDirty = true;
      perfLog('fastPath mirrorApplied',
          '${sw.elapsedMilliseconds}ms uuid=$uuid device=${snap['device_client_id']} pos=${snap['position_ms']} updated=${snap['updated_at']}');
      _flushBreakpoints();
    } catch (e) {
      debugPrint('SyncEngine 断点快路径失败（回退全量 pull）：$e');
    }
  }

  /// 定时器当前是否在跑（供测试断言后台确实停了轮询）。
  @visibleForTesting
  bool get isPolling => _tick != null;

  void stop() {
    _tick?.cancel();
    _tick = null;
  }

  /// 外部请求同步（手动按钮/回前台）。[force] 跳过退避。
  Future<void> syncNow({bool pullOnly = false, bool force = false}) {
    final inflight = _inflight;
    if (inflight != null) {
      _dirty = true;
      return inflight;
    }
    final f = _run(pullOnly: pullOnly, force: force);
    _inflight = f;
    return f.whenComplete(() {
      _inflight = null;
      if (_dirty) {
        _dirty = false;
        unawaited(syncNow());
      }
    });
  }

  /// 启动序（Root boot 用）：等「已发起/在飞行」的首轮 pull 收尾，**不**再强制
  /// 发新一轮——旧 firstPull 在首轮飞行中会置 `_dirty`，完成后又整轮（push+pull）
  /// 重复跑一遍（冷启动徒增 DB/网络负载与回调）。带超时；未配对/网络失败/超时
  /// 按本机断点恢复。
  Future<void> awaitFirstPull(
      {Duration timeout = const Duration(seconds: 2)}) async {
    try {
      final inflight = _inflight;
      if (inflight != null) {
        await inflight.timeout(timeout);
        return;
      }
      // start() 被跳过（后台启动）或首轮已失败且从未成功拉过：补一轮 pullOnly。
      if (_lastPullAt != null) return;
      await syncNow(pullOnly: true, force: true).timeout(timeout);
    } catch (_) {
      // 未配对/网络失败/超时：按本机断点恢复。
    }
  }

  Future<void> _onTick() async {
    if (!_appForeground && !_playing) return;
    if (_inflight != null) return;
    final now = DateTime.now();
    final failAt = _lastFailAt;
    if (failAt != null) {
      var backoff = Duration(seconds: 1 << _failCount.clamp(0, 5));
      if (backoff > _maxBackoff) backoff = _maxBackoff;
      if (now.difference(failAt) < backoff) return;
    }
    final pulledAt = _lastPullAt;
    final needPull =
        pulledAt == null || now.difference(pulledAt) >= _pullInterval;
    // COUNT 走写隔离（含 acked 索引），主 isolate 不再每 2s 同步扫 outbox 表。
    final pending = await index.pendingOutboxCount();
    if (!_appForeground && !_playing) return; // 等待期间可能已退后台（未播放才停）
    if (pending > 0 || needPull) {
      unawaited(syncNow());
    }
  }

  Future<void> _run({required bool pullOnly, required bool force}) async {
    if (!settings.syncEnabled) {
      _logIdle('同步开关关闭');
      return;
    }
    if (api.baseUrl.isEmpty) {
      _logIdle('未配置服务器地址');
      return;
    }
    if (!force) {
      final failAt = _lastFailAt;
      if (failAt != null) {
        var backoff = Duration(seconds: 1 << _failCount.clamp(0, 5));
        if (backoff > _maxBackoff) backoff = _maxBackoff;
        if (DateTime.now().difference(failAt) < backoff) {
          _logIdle('退避中（还剩 ${backoff.inSeconds}s）');
          return;
        }
      }
    }
    final sw = Stopwatch()..start();
    final clientId = await api.getClientId();
    perfLog('sync.run clientId', '${sw.elapsedMilliseconds}ms');
    if (clientId == null || clientId.isEmpty) {
      _logIdle('未配对（无 clientId）');
      return;
    }
    try {
      lastPushed = 0;
      final swPush = Stopwatch()..start();
      if (!pullOnly) await _push(clientId);
      perfLog('sync.run push', '${swPush.elapsedMilliseconds}ms pushed=$lastPushed');
      final swPull = Stopwatch()..start();
      await _pull(clientId);
      perfLog('sync.run pull',
          '${swPull.elapsedMilliseconds}ms songs=$lastPulledSongs playlists=$lastPulledPlaylists');
      final swFlush = Stopwatch()..start();
      _flushPlaylists();
      _flushSongStates();
      _flushBreakpoints();
      perfLog('sync.run flushTotal', '${swFlush.elapsedMilliseconds}ms');
      settings.lastSyncAt = DateTime.now().toIso8601String();
      _lastPullAt = DateTime.now();
      _failCount = 0;
      _lastFailAt = null;
      lastError = '';
      perfLog('sync.run total', '${sw.elapsedMilliseconds}ms pullOnly=$pullOnly');
    } catch (e) {
      _lastFailAt = DateTime.now();
      _failCount++;
      lastError = e.toString();
      perfLog('sync.run FAILED', '${sw.elapsedMilliseconds}ms $e');
      debugPrint('SyncEngine 同步失败（退避重试）：$e');
    }
  }

  Future<void> _push(String clientId) async {
    // 读写与 payload 解码都在写隔离（OutboxRow.payload 已是 Map）。
    final pending = await index.pendingOutbox();
    if (pending.isEmpty) return;

    // 同一歌单的断点事件只推最新一条：离线期间每次切歌/暂停都入队，
    // 逐条推会把同一后缀重复追加到服务端分支。旧事件在最新事件 ack 后删除；
    // 若最新事件被拒，旧事件仍保留，下一轮兜底。
    final bpGroups = <String, List<OutboxRow>>{};
    for (final e in pending) {
      if (e.type != SyncEventTypes.breakpointSet) continue;
      final uuid = e.payload['playlist_uuid'];
      if (uuid is! String || uuid.isEmpty) continue;
      bpGroups.putIfAbsent(uuid, () => []).add(e);
    }
    final superseded = <String, List<String>>{};
    final coalesced = <String>{};
    for (final group in bpGroups.values) {
      if (group.length <= 1) continue;
      final keep = group.last.eventUuid;
      superseded[keep] = [
        for (final e in group.take(group.length - 1)) e.eventUuid
      ];
      coalesced.addAll(superseded[keep]!);
    }
    final sendRows = [
      for (final e in pending)
        if (!coalesced.contains(e.eventUuid)) e,
    ];
    final sendByUuid = {for (final e in sendRows) e.eventUuid: e};
    // v2 回执按 playlist 键控；记录每个歌单本批最后一条断点事件的 deep_list，
    // 供播放器历史三向合并使用。
    final sentBpByPlaylist = <String, OutboxRow>{};
    for (final e in sendRows) {
      if (e.type != SyncEventTypes.breakpointSet) continue;
      final uuid = e.payload['playlist_uuid'];
      if (uuid is String && uuid.isNotEmpty) sentBpByPlaylist[uuid] = e;
    }
    // 排查「旧数据覆盖服务端新数据」：先记录本批要推什么、时间戳是多少。
    final byType = <String, int>{};
    for (final e in sendRows) {
      byType[e.type] = (byType[e.type] ?? 0) + 1;
    }
    perfLog('push.batch',
        'n=${pending.length} send=${sendRows.length} coalesced=${coalesced.length} $byType');
    for (final e in sendRows) {
      if (e.type != SyncEventTypes.breakpointSet) continue;
      final p = e.payload;
      perfLog('push.breakpoint',
          'uuid=${e.eventUuid} playlist=${p['playlist_uuid']} ref=${p['source_ref']} pos=${p['position_ms']}ms base=${p['base_deep_list'] is List ? (p['base_deep_list'] as List).length : -1} added=${p['deep_added'] is List ? (p['deep_added'] as List).length : -1} occurred=${e.occurredAt}');
    }
    final data = await api.syncPush(clientId, [
      for (final e in sendRows)
        {
          'event_uuid': e.eventUuid,
          'device_client_id': clientId,
          'type': e.type,
          'occurred_at': e.occurredAt,
          'payload': e.payload,
        }
    ]);
    if (data == null) throw Exception('push 无响应');
    _noteServerTime(data['server_time']);
    await _noteBreakpointProtocol(data);
    final breakpointProtocol =
        (data['breakpoint_protocol'] as num?)?.toInt() == 2;
    final applied = _strList(data['applied']);
    final duplicates = _strList(data['duplicates']);
    final acked = {...applied, ...duplicates};
    final remove = <String>{...acked};
    for (final entry in superseded.entries) {
      if (acked.contains(entry.key)) remove.addAll(entry.value);
    }
    await index.deleteOutbox(remove);
    lastPushed = acked.length;
    perfLog('push.ack',
        'applied=${applied.length} duplicates=${duplicates.length} removed=${remove.length} cursor=${data['cursor']}');
    final rejected = data['rejected'];
    if (rejected is List) {
      final uuids = [
        for (final r in rejected)
          if (r is Map && r['event_uuid'] is String) r['event_uuid'] as String
      ];
      await index.deadLetterOutbox(uuids);
      if (uuids.isNotEmpty) {
        debugPrint('SyncEngine 死信事件：$uuids');
        perfLog('push.rejected', [
          for (final r in rejected)
            if (r is Map) '${r['event_uuid']}=${r['reason']}'
        ].join(' | '));
        final rejectedOps = <String, String>{};
        for (final uuid in uuids) {
          final row = sendByUuid[uuid];
          if (row?.type != SyncEventTypes.breakpointSet) continue;
          final playlist = row!.payload['playlist_uuid'];
          if (playlist is String && playlist.isNotEmpty) {
            final op = row.payload['op_id'];
            rejectedOps[playlist] = op is String ? op : '';
          }
        }
        if (rejectedOps.isNotEmpty) {
          onBreakpointRejected?.call(rejectedOps);
        }
      }
    }
    final corrections = data['corrections'];
    if (corrections is Map && corrections.isNotEmpty) {
      perfLog('push.corrections', 'n=${corrections.length}');
      for (final v in corrections.values) {
        if (v is Map<String, dynamic>) await _applySnapshot(v, clientId);
      }
    }

    // v2 回执：按 playlist 返回权威 head+history。无条件落镜像（含本设备
    // 自己的 op，快照可能已并入对端历史），再交给播放器按版本应用。
    final v2Breakpoints = data['breakpoints'];
    final v2Handled = <String>{};
    if (breakpointProtocol && v2Breakpoints is Map && v2Breakpoints.isNotEmpty) {
      perfLog('push.breakpointsV2', 'n=${v2Breakpoints.length}');
      for (final entry in v2Breakpoints.entries) {
        final uuid = entry.key;
        final raw = entry.value;
        if (uuid is! String || raw is! Map) continue;
        final snap = raw.cast<String, dynamic>();
        v2Handled.add(uuid);
        try {
          await index.applyPlaystateMirror(snap, force: true);
        } catch (e) {
          debugPrint('SyncEngine v2 断点镜像落库失败：$e');
        }
        final sentRow = sentBpByPlaylist[uuid];
        final sent = sentRow?.payload['deep_list'];
        final cb = onBreakpointSnapshot;
        if (cb != null) {
          try {
            await cb(snap, sent is List ? sent : const []);
          } catch (e) {
            debugPrint('SyncEngine v2 断点快照应用失败：$e');
          }
        }
        perfLog('push.breakpointsV2.apply',
            'playlist=$uuid head=${snap['head_rev']} history=${snap['history_rev']} headOp=${snap['head_op_id']}');
      }
      // v2 的快照含权威历史分支，不再走下面的旧 base 盲推进；base 由播放器
      // 在合并历史/采用快照后按服务端分支显式对齐。
    }
    // 已处理的断点事件要回报 op_id：只清匹配的 pending，避免快照里出现
    // 别家 head 时误清新开播（更晚）的本地操作。必须在快照回调之后调用。
    if (breakpointProtocol && acked.isNotEmpty) {
      final ackedOps = <String, String>{};
      for (final uuid in acked) {
        final row = sendByUuid[uuid];
        if (row?.type != SyncEventTypes.breakpointSet) continue;
        final playlist = row!.payload['playlist_uuid'];
        final opId = row.payload['op_id'];
        if (playlist is String && playlist.isNotEmpty && opId is String) {
          ackedOps[playlist] = opId;
        }
      }
      if (ackedOps.isNotEmpty) {
        final cb = onBreakpointAcked;
        if (cb != null) {
          try {
            await cb(ackedOps);
          } catch (e) {
            debugPrint('SyncEngine v2 断点 ack 回报失败：$e');
          }
        }
      }
    }

    // 深层列表合并回执：与 corrections 分开、无条件强制落镜像，并回调播放器
    // 合并历史。即使 device_client_id 是本设备也不能走自写回声过滤——快照里含
    // 对端分支；base 由播放器采用后推进，避免把未采用的远端分支写进 base。
    final merged = data['merged'];
    final mergedUuids = <String>{};
    if (merged is Map && merged.isNotEmpty) {
      perfLog('push.merged', 'n=${merged.length}');
      for (final entry in merged.entries) {
        final eventUuid = entry.key;
        final raw = entry.value;
        if (eventUuid is! String || raw is! Map) continue;
        final snap = raw.cast<String, dynamic>();
        try {
          await index.applyPlaystateMirror(snap, force: true);
        } catch (e) {
          // 快照落库失败也要继续回调合并历史，避免一条坏回执拖垮整轮 ack。
          debugPrint('SyncEngine merged 镜像落库失败：$e');
        }
        mergedUuids.add(eventUuid);
        // 不置 _breakpointsDirty：merged 只补历史，不能触发
        // applyNewerMirrorIfAny 切歌/seek（尤其非当前歌单的回执）。
        final sent = sendByUuid[eventUuid]?.payload['deep_list'];
        final cb = onBreakpointMerged;
        if (cb != null) {
          try {
            await cb(snap, sent is List ? sent : const []);
          } catch (e) {
            // 回执已落镜像；运行时历史合并失败不应让整轮 push 失败
            //（事件已删除，重试也不会再收到同一条 merged）。base 保持旧值，
            // 下一轮按全量/前缀重新收敛。
            debugPrint('SyncEngine merged 历史应用失败：$e');
          }
        }
        perfLog('push.merged.apply',
            'uuid=$eventUuid playlist=${snap['client_uuid']} deep=${(snap['deep_list'] as List?)?.length ?? 0}');
      }
    }
    // 已推断点：base 对齐本设备刚推的全量分支（不跟服务端 merged，避免
    // 本机尚未采用的远端分支让旧列表被误判为非追加）。merged 用回调里
    // 实际采用后的本地列表更新 base。
    for (final row in sendRows) {
      if (row.type != SyncEventTypes.breakpointSet ||
          !acked.contains(row.eventUuid) ||
          mergedUuids.contains(row.eventUuid)) {
        continue;
      }
      final uuid = row.payload['playlist_uuid'];
      final deep = row.payload['deep_list'];
      if (uuid is String &&
          uuid.isNotEmpty &&
          deep is List &&
          !v2Handled.contains(uuid)) {
        try {
          await index.setBreakpointBaseDeepList(uuid, jsonEncode(deep));
        } catch (e) {
          debugPrint('SyncEngine 断点 base 更新失败：$e');
        }
      }
    }
    _flushSources();
    _flushBreakpoints();
  }

  void _flushSources() {
    if (!_sourcesDirty) return;
    _sourcesDirty = false;
    final sw = Stopwatch()..start();
    onSourcesApplied?.call();
    perfLog('flush.sources', '${sw.elapsedMilliseconds}ms');
  }

  /// 断点变更统一出口（pull 批量与 push corrections 共用）。
  void _flushBreakpoints() {
    if (!_breakpointsDirty) return;
    _breakpointsDirty = false;
    final sw = Stopwatch()..start();
    onBreakpointsApplied?.call();
    perfLog('flush.breakpoints', '${sw.elapsedMilliseconds}ms');
  }

  /// 歌单变更统一出口：pull 与 push 回包 corrections 共用，
  /// 本轮结束时最多触发一次回调（携带本轮变更的 uuid 集合）。
  void _flushPlaylists() {
    if (!_playlistsDirty) return;
    _playlistsDirty = false;
    final uuids = Set<String>.of(_dirtyPlaylistUuids);
    _dirtyPlaylistUuids.clear();
    final sw = Stopwatch()..start();
    onPlaylistsApplied?.call(uuids);
    perfLog('flush.playlists', '${sw.elapsedMilliseconds}ms n=${uuids.length}');
  }

  /// 歌曲权重变更统一出口（pull 批量与 push corrections 共用）。
  void _flushSongStates() {
    if (!_songStatesDirty) return;
    _songStatesDirty = false;
    final sw = Stopwatch()..start();
    onSongStatesApplied?.call();
    perfLog('flush.songStates', '${sw.elapsedMilliseconds}ms');
  }

  Future<void> _pull(String clientId) async {
    final swAll = Stopwatch()..start();
    var cursor = settings.syncCursor;
    var pages = 0;
    lastPulledSongs = 0;
    lastPulledPlaylists = 0;
    // 跨页实体去重：服务端只在**单页内**按实体去重（页内 LinkedHashSet），
    // 同一实体的事件横跨多页时会重复回包同一快照。这里按实体身份去重，
    // 重复的只计数不重复落库（省写事务与 UI 线程的映射/等待）。
    final seenSongs = <String>{};
    final seenPlaylists = <String>{};
    final seenSources = <String>{};
    final seenStates = <String>{};
    // 本机优先 guard：本轮 push 已先执行，其 ack 的实体不在此集内；
    // 仍有未推事件的实体跳过 pull 快照（等下一轮收敛）。
    final guard = await _pendingGuardKeys();
    var guardedSongs = 0;
    var guardedPlaylists = 0;
    var guardedSources = 0;
    var guardedStates = 0;
    var selfStates = 0;
    while (true) {
      final swFetch = Stopwatch()..start();
      final data = await api.syncPull(cursor);
      final fetchMs = swFetch.elapsedMilliseconds;
      if (data == null) throw Exception('pull 无响应');
      _noteServerTime(data['server_time']);
      await _noteBreakpointProtocol(data);
      final pullV2 = (data['breakpoint_protocol'] as num?)?.toInt() == 2;
      final rawSongs = data['songs'] is List ? (data['songs'] as List).length : 0;
      final rawSources =
          data['sources'] is List ? (data['sources'] as List).length : 0;
      final rawPlaylists =
          data['playlists'] is List ? (data['playlists'] as List).length : 0;
      final rawStates =
          data['playstates'] is List ? (data['playstates'] as List).length : 0;
      perfLog('pull.page fetch',
          'page=$pages cursor=$cursor ${fetchMs}ms songs=$rawSongs sources=$rawSources playlists=$rawPlaylists states=$rawStates');
      // 歌曲权重：整页收集为一批，单事务落库（一次 fsync 取代逐行 autocommit）；
      // 字段映射与落库在写隔离内（applySongSnapshotsRaw）。
      final swSongs = Stopwatch()..start();
      final songs = data['songs'];
      if (songs is List) {
        final batch = <Map<String, dynamic>>[];
        for (final s in songs) {
          if (s is! Map) continue;
          final m = s.cast<String, dynamic>();
          final ref = m['source_ref'];
          if (ref is! String || ref.isEmpty) continue;
          if (!seenSongs.add('${m['source_id'] ?? ''}|$ref')) continue;
          // 本机优先：本地有未推权重事件的歌，旧快照不覆盖本地脏行。
          final songKey = syncEntityKey('song.state', m);
          if (songKey != null && guard.songs.contains(songKey)) {
            guardedSongs++;
            continue;
          }
          batch.add(m);
        }
        if (batch.isNotEmpty) {
          await index.applySongSnapshotsRaw(batch);
          lastPulledSongs += batch.length;
          _songStatesDirty = true;
        }
        perfLog('pull.page songs',
            '${swSongs.elapsedMilliseconds}ms applied=${batch.length}');
      }
      final swSources = Stopwatch()..start();
      final sources = data['sources'];
      if (sources is List) {
        var applied = 0;
        for (final s in sources) {
          if (s is! Map) continue;
          final m = s.cast<String, dynamic>();
          final uuid = m['client_uuid'] as String?;
          if (uuid == null || uuid.isEmpty || !seenSources.add(uuid)) continue;
          if (guard.sources.contains(uuid)) {
            guardedSources++;
            continue;
          }
          await _applySource(m);
          applied++;
        }
        perfLog('pull.page sources',
            '${swSources.elapsedMilliseconds}ms applied=$applied');
      }
      final swPlaylists = Stopwatch()..start();
      final playlists = data['playlists'];
      if (playlists is List) {
        final batch = <Map<String, dynamic>>[];
        for (final p in playlists) {
          if (p is! Map) continue;
          final m = p.cast<String, dynamic>();
          final uuid = m['client_uuid'] as String?;
          if (uuid == null || uuid.isEmpty || !seenPlaylists.add(uuid)) continue;
          if (guard.playlists.contains(uuid)) {
            guardedPlaylists++;
            continue;
          }
          batch.add(m);
          _dirtyPlaylistUuids.add(uuid);
        }
        if (batch.isNotEmpty) {
          await index.applyPlaylistSnapshots(batch);
          lastPulledPlaylists += batch.length;
          _playlistsDirty = true;
        }
        perfLog('pull.page playlists',
            '${swPlaylists.elapsedMilliseconds}ms applied=${batch.length}');
      }
      final swStates = Stopwatch()..start();
      final states = data['playstates'];
      if (states is List) {
        var applied = 0;
        for (final st in states) {
          if (st is! Map) continue;
          final m = st.cast<String, dynamic>();
          final uuid = m['client_uuid'] as String?;
          if (uuid == null || uuid.isEmpty || !seenStates.add(uuid)) continue;
          if (guard.states.contains(uuid)) {
            guardedStates++;
            continue;
          }
          // F2 自写回声过滤：快照来源是本设备则不入镜像（本机运行时/断点
          // 必然不旧于它；入镜像只会招来“自己套用自己的旧快照”）。
          // v2 例外：同一 head 的快照可能已合并对端历史，且 rev 可安全去重。
          final device = m['device_client_id'];
          if (!pullV2 && device is String && device == clientId) {
            selfStates++;
            continue;
          }
          await index.applyPlaystateMirror(m);
          _breakpointsDirty = true;
          applied++;
        }
        perfLog('pull.page states',
            '${swStates.elapsedMilliseconds}ms applied=$applied');
      }
      cursor = (data['cursor'] as num?)?.toInt() ?? cursor;
      settings.syncCursor = cursor;
      pages++;
      if (data['has_more'] != true || pages >= _maxPullPages) break;
    }
    _flushSources();
    perfLog('pull.total',
        '${swAll.elapsedMilliseconds}ms pages=$pages cursor=$cursor guardedSongs=$guardedSongs playlists=$guardedPlaylists sources=$guardedSources states=$guardedStates selfStates=$selfStates');
  }

  /// 服务端时钟校准：push/pull 回包的 `server_time` 与本地钟的差值即偏移，
  /// 交给 outbox 入队口修正后续事件时间戳（旧服务端无该字段则忽略，
  /// 退化为本地钟）。解析失败同样忽略，不阻塞同步。
  /// 每次校准打一条日志：排查客户端钟偏移导致 LWW 误判（旧数据覆盖新数据）用。
  void _noteServerTime(Object? v) {
    if (v is! String || v.isEmpty) return;
    final serverNow = DateTime.tryParse(v);
    if (serverNow == null) return;
    final skew = serverNow.difference(DateTime.now());
    index.setClockSkew(skew);
    perfLog('sync.clockSkew', '${skew.inMilliseconds}ms server_time=$v');
  }

  /// 待推实体 guard（本机优先）：从 outbox 按服务端同规则算实体键。
  /// 读失败不阻塞同步——退化为既有无条件应用，下轮收敛。
  Future<
      ({
        Set<String> songs,
        Set<String> sources,
        Set<String> playlists,
        Set<String> states
      })> _pendingGuardKeys() async {
    final songs = <String>{};
    final sources = <String>{};
    final playlists = <String>{};
    final states = <String>{};
    try {
      final pending = await index.pendingOutbox();
      for (final e in pending) {
        final k = syncEntityKey(e.type, e.payload);
        if (k == null) continue;
        if (k.startsWith('song|')) {
          songs.add(k);
        } else if (k.startsWith('playlist|')) {
          playlists.add(k.substring('playlist|'.length));
        } else if (k.startsWith('breakpoint|')) {
          states.add(k.substring('breakpoint|'.length));
        } else if (k.startsWith('source|')) {
          sources.add(k.substring('source|'.length));
        }
      }
    } catch (_) {
      // guard 是保护性跳过，读不到就按全量应用处理。
    }
    return (songs: songs, sources: sources, playlists: playlists, states: states);
  }

  /// push correction 回执的快照落库（形状判分）：
  /// 含 kind+address=播放源，含 items=歌单，含 position_ms=断点，含 like_streak=歌曲权重。
  /// 落库一律走服务端原始形态直通写隔离（与 pull 同一路径）。
  /// 每条 correction 都是「服务端判我方事件输」的证据，记录关键字段供时间线对齐。
  /// [clientId] 本设备号（F2 自写回声过滤用；未知则不过滤）。
  Future<void> _applySnapshot(Map<String, dynamic> s, [String? clientId]) async {
    if (s.containsKey('kind') && s.containsKey('address')) {
      perfLog('push.correction',
          'source uuid=${s['client_uuid']} kind=${s['kind']} address=${s['address']} deleted=${s['deleted']}');
      await _applySource(s);
    } else if (s.containsKey('items')) {
      final uuid = s['client_uuid'] as String?;
      if (uuid == null || uuid.isEmpty) return;
      perfLog('push.correction',
          'playlist uuid=$uuid name=${s['name']} sync_ver=${s['sync_ver']} items=${(s['items'] as List?)?.length}');
      await index.applyPlaylistSnapshots([s]);
      _playlistsDirty = true;
      _dirtyPlaylistUuids.add(uuid);
    } else if (s.containsKey('position_ms')) {
      perfLog('push.correction',
          'breakpoint playlist=${s['client_uuid']} device=${s['device_client_id']} pos=${s['position_ms']} updated=${s['updated_at']} lastEvent=${s['last_event_at']}');
      // F2 自写回声过滤：correction 回的是当前赢家行；赢家是本设备时本机状态
      // 必然不旧于它，无需入镜像（否则可能触发套用自己的旧快照）。
      final device = s['device_client_id'];
      if (clientId != null && device is String && device == clientId) {
        perfLog('push.correction.skipSelf',
            'breakpoint playlist=${s['client_uuid']} device=$device');
        return;
      }
      await index.applyPlaystateMirror(s);
      _breakpointsDirty = true;
    } else if (s.containsKey('like_streak')) {
      final ref = s['source_ref'];
      if (ref is! String || ref.isEmpty) return;
      perfLog('push.correction',
          'song ref=$ref weight=${s['weight']} fav=${s['is_favorite']} frozen=${s['frozen']}');
      await index.applySongSnapshotRaw(s);
      _songStatesDirty = true;
    }
  }

  Future<void> _applySource(Map<String, dynamic> s) async {
    final uuid = s['client_uuid'] as String?;
    final kind = s['kind'] as String?;
    final address = s['address'] as String?;
    if (uuid == null || uuid.isEmpty || kind == null || address == null) return;
    final config = s['config'];
    final changed = await index.applySourceSnapshot(
      uuid: uuid,
      kind: kind,
      name: s['name'] as String?,
      address: address,
      config: config is Map ? config.cast<String, dynamic>() : null,
      enabled: s['enabled'] != false,
      deleted: s['deleted'] == true,
    );
    if (changed) _sourcesDirty = true;
  }

  static List<String> _strList(Object? v) => [
        for (final e in (v is List ? v : const []))
          if (e is String) e
      ];
}
