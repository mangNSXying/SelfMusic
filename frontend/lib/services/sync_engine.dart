import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/local/app_settings.dart';
import '../data/local/local_index.dart';
import 'api_client.dart';

/// 阶段5 多设备状态同步引擎·客户端（DESIGN.md §7.2，字段级合并）。
///
/// 循环：push（outbox→`/sync/push`，2s 防抖批量）→ pull（`/sync/pull` 增量）→
/// 落库（权重/歌单/断点镜像）→ 推进 cursor。运行时播放只读本地 SQLite（事实源），
/// 本引擎只负责把远端收敛结果搬进来、把本地变更搬出去。
///
/// 触发：[start] 后 2s tick（有未确认事件立刻推；否则 30s 拉一次）+
/// 启动/回前台/手动 [syncNow]。无 connectivity 依赖：断网时请求抛错进退避，
/// 恢复后下一次 tick 自动追上（退避上限 30s）。
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

  SyncEngine({required this.api, required this.index, required this.settings});

  /// 应用是否在前台。false 时 [start] 的定时器不触发同步，避免应用退到后台
  /// 后仍每 [tickFast]（2s）醒来一次做网络 IO——后台没有前台服务撑着，
  /// 纯烧流量/电，且 Android 后台限制下大概率直接失败重试。
  /// 前台服务只为「播放」而开，不该顺带把同步也拖进后台。
  bool _appForeground = true;

  /// 退到后台：停表。已在飞行中的一轮不打断（_inflight 自会收尾），
  /// 只是不再发起新的。
  void pause() {
    if (!_appForeground) return;
    _appForeground = false;
    _tick?.cancel();
    _tick = null;
  }

  /// 回前台：重新起表；若积压了 outbox 或已过拉取间隔，立刻补一轮。
  void resume() {
    if (_appForeground) return;
    _appForeground = true;
    _tick ??= Timer.periodic(tickFast, (_) => unawaited(_onTick()));
    unawaited(_onTick());
  }

  void start() {
    stop();
    if (!_appForeground) return; // 后台启动：等 resume()
    _tick = Timer.periodic(tickFast, (_) => unawaited(_onTick()));
    unawaited(syncNow());
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

  /// 启动序：等待首轮拉取完成（带超时），以便跨设备断点恢复拿到最新镜像。
  Future<void> firstPull({Duration timeout = const Duration(seconds: 2)}) async {
    try {
      await syncNow(pullOnly: false, force: true).timeout(timeout);
    } catch (_) {
      // 未配对/网络失败/超时：按本机断点恢复。
    }
  }

  Future<void> _onTick() async {
    if (!_appForeground) return;
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
    if (!_appForeground) return; // 等待期间可能已退后台
    if (pending > 0 || needPull) {
      unawaited(syncNow());
    }
  }

  Future<void> _run({required bool pullOnly, required bool force}) async {
    if (!settings.syncEnabled) return;
    if (api.baseUrl.isEmpty) return;
    if (!force) {
      final failAt = _lastFailAt;
      if (failAt != null) {
        var backoff = Duration(seconds: 1 << _failCount.clamp(0, 5));
        if (backoff > _maxBackoff) backoff = _maxBackoff;
        if (DateTime.now().difference(failAt) < backoff) return;
      }
    }
    final clientId = await api.getClientId();
    if (clientId == null || clientId.isEmpty) return; // 未配对
    try {
      lastPushed = 0;
      if (!pullOnly) await _push(clientId);
      await _pull(clientId);
      _flushPlaylists();
      _flushSongStates();
      _flushBreakpoints();
      settings.lastSyncAt = DateTime.now().toIso8601String();
      _lastPullAt = DateTime.now();
      _failCount = 0;
      _lastFailAt = null;
      lastError = '';
    } catch (e) {
      _lastFailAt = DateTime.now();
      _failCount++;
      lastError = e.toString();
      debugPrint('SyncEngine 同步失败（退避重试）：$e');
    }
  }

  Future<void> _push(String clientId) async {
    // 读写与 payload 解码都在写隔离（OutboxRow.payload 已是 Map）。
    final pending = await index.pendingOutbox();
    if (pending.isEmpty) return;
    final data = await api.syncPush(clientId, [
      for (final e in pending)
        {
          'event_uuid': e.eventUuid,
          'device_client_id': clientId,
          'type': e.type,
          'occurred_at': e.occurredAt,
          'payload': e.payload,
        }
    ]);
    if (data == null) throw Exception('push 无响应');
    final applied = _strList(data['applied']);
    final duplicates = _strList(data['duplicates']);
    await index.deleteOutbox([...applied, ...duplicates]);
    lastPushed = applied.length + duplicates.length;
    final rejected = data['rejected'];
    if (rejected is List) {
      final uuids = [
        for (final r in rejected)
          if (r is Map && r['event_uuid'] is String) r['event_uuid'] as String
      ];
      await index.deadLetterOutbox(uuids);
      if (uuids.isNotEmpty) debugPrint('SyncEngine 死信事件：$uuids');
    }
    final corrections = data['corrections'];
    if (corrections is Map) {
      for (final v in corrections.values) {
        if (v is Map<String, dynamic>) await _applySnapshot(v);
      }
    }
    _flushSources();
    _flushBreakpoints();
  }

  void _flushSources() {
    if (!_sourcesDirty) return;
    _sourcesDirty = false;
    onSourcesApplied?.call();
  }

  /// 断点变更统一出口（pull 批量与 push corrections 共用）。
  void _flushBreakpoints() {
    if (!_breakpointsDirty) return;
    _breakpointsDirty = false;
    onBreakpointsApplied?.call();
  }

  /// 歌单变更统一出口：pull 与 push 回包 corrections 共用，
  /// 本轮结束时最多触发一次回调（携带本轮变更的 uuid 集合）。
  void _flushPlaylists() {
    if (!_playlistsDirty) return;
    _playlistsDirty = false;
    final uuids = Set<String>.of(_dirtyPlaylistUuids);
    _dirtyPlaylistUuids.clear();
    onPlaylistsApplied?.call(uuids);
  }

  /// 歌曲权重变更统一出口（pull 批量与 push corrections 共用）。
  void _flushSongStates() {
    if (!_songStatesDirty) return;
    _songStatesDirty = false;
    onSongStatesApplied?.call();
  }

  Future<void> _pull(String clientId) async {
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
    while (true) {
      final data = await api.syncPull(cursor);
      if (data == null) throw Exception('pull 无响应');
      // 歌曲权重：整页收集为一批，单事务落库（一次 fsync 取代逐行 autocommit）；
      // 字段映射与落库在写隔离内（applySongSnapshotsRaw）。
      final songs = data['songs'];
      if (songs is List) {
        final batch = <Map<String, dynamic>>[];
        for (final s in songs) {
          if (s is! Map) continue;
          final m = s.cast<String, dynamic>();
          final ref = m['source_ref'];
          if (ref is! String || ref.isEmpty) continue;
          if (!seenSongs.add('${m['source_id'] ?? ''}|$ref')) continue;
          batch.add(m);
        }
        if (batch.isNotEmpty) {
          await index.applySongSnapshotsRaw(batch);
          lastPulledSongs += batch.length;
          _songStatesDirty = true;
        }
      }
      final sources = data['sources'];
      if (sources is List) {
        for (final s in sources) {
          if (s is! Map) continue;
          final m = s.cast<String, dynamic>();
          final uuid = m['client_uuid'] as String?;
          if (uuid == null || uuid.isEmpty || !seenSources.add(uuid)) continue;
          await _applySource(m);
        }
      }
      final playlists = data['playlists'];
      if (playlists is List) {
        final batch = <Map<String, dynamic>>[];
        for (final p in playlists) {
          if (p is! Map) continue;
          final m = p.cast<String, dynamic>();
          final uuid = m['client_uuid'] as String?;
          if (uuid == null || uuid.isEmpty || !seenPlaylists.add(uuid)) continue;
          batch.add(m);
          _dirtyPlaylistUuids.add(uuid);
        }
        if (batch.isNotEmpty) {
          await index.applyPlaylistSnapshots(batch);
          lastPulledPlaylists += batch.length;
          _playlistsDirty = true;
        }
      }
      final states = data['playstates'];
      if (states is List) {
        for (final st in states) {
          if (st is! Map) continue;
          final m = st.cast<String, dynamic>();
          final uuid = m['client_uuid'] as String?;
          if (uuid == null || uuid.isEmpty || !seenStates.add(uuid)) continue;
          await index.applyPlaystateMirror(m);
          _breakpointsDirty = true;
        }
      }
      cursor = (data['cursor'] as num?)?.toInt() ?? cursor;
      settings.syncCursor = cursor;
      pages++;
      if (data['has_more'] != true || pages >= _maxPullPages) break;
    }
    _flushSources();
  }

  /// push correction 回执的快照落库（形状判分）：
  /// 含 kind+address=播放源，含 items=歌单，含 position_ms=断点，含 like_streak=歌曲权重。
  /// 落库一律走服务端原始形态直通写隔离（与 pull 同一路径）。
  Future<void> _applySnapshot(Map<String, dynamic> s) async {
    if (s.containsKey('kind') && s.containsKey('address')) {
      await _applySource(s);
    } else if (s.containsKey('items')) {
      final uuid = s['client_uuid'] as String?;
      if (uuid == null || uuid.isEmpty) return;
      await index.applyPlaylistSnapshots([s]);
      _playlistsDirty = true;
      _dirtyPlaylistUuids.add(uuid);
    } else if (s.containsKey('position_ms')) {
      await index.applyPlaystateMirror(s);
      _breakpointsDirty = true;
    } else if (s.containsKey('like_streak')) {
      final ref = s['source_ref'];
      if (ref is! String || ref.isEmpty) return;
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
