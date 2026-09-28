import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/local/app_settings.dart';
import '../data/local/artist_names.dart';
import '../data/local/local_index.dart';

/// MusicBrainz 搜索结果命中（选型 / 歧义人工选择共用）。
class MbArtistHit {
  final String mbid;
  final String name;
  final String? sortName;
  final String? type;
  final String? disambiguation;
  final String? country;
  final String? beginYear;
  final String? endYear;
  final double score;
  final List<Map<String, dynamic>> aliases;

  const MbArtistHit({
    required this.mbid,
    required this.name,
    this.sortName,
    this.type,
    this.disambiguation,
    this.country,
    this.beginYear,
    this.endYear,
    this.score = 0,
    this.aliases = const [],
  });

  /// 名字表（primary + 别名 + 可选角色名），供解析结果落库。
  List<Map<String, dynamic>> toNames({String? role}) => [
        {'name': name, 'name_type': 'primary', 'is_primary': 1},
        if (sortName != null && sortName != name)
          {'name': sortName, 'name_type': 'sort_name'},
        for (final al in aliases)
          if (al['name'] != null)
            {
              'name': al['name'],
              'name_type': 'alias',
              if (al['locale'] != null) 'lang': al['locale'],
              if (al['primary'] == true) 'is_primary': 1
            },
        if (role != null && role.isNotEmpty)
          {'name': role, 'name_type': 'role'},
      ];
}

/// 一次解析的判定结果。
enum MbResolveVerdict { none, single, ambiguous }

class MbResolveResult {
  final MbResolveVerdict verdict;
  final MbArtistHit? hit;
  final List<MbArtistHit> candidates;
  const MbResolveResult.single(MbArtistHit this.hit)
      : verdict = MbResolveVerdict.single,
        candidates = const [];
  const MbResolveResult.none()
      : verdict = MbResolveVerdict.none,
        hit = null,
        candidates = const [];
  const MbResolveResult.ambiguous(this.candidates)
      : verdict = MbResolveVerdict.ambiguous,
        hit = null;
}

/// 歌手处理.txt：歌手身份解析服务。
///
/// - 后台循环拉取 [LocalIndex.artistWorkSet] 待解析项，逐个走
///   括号人直解 → MB 搜索 → 判定（单强命中=resolved / 多强=ambiguous / 无=local）；
/// - 全局令牌桶限流 **1 req/s**（MB 服务端硬限流），尊重 429/503 与 Retry-After，
///   失败按 error_count 指数退避（10s→30s→60s→5min）；
/// - names/groups 为 JSON 数组，alias 合流走 [LocalIndex.artistMergeMbid]。
class ArtistResolver extends ChangeNotifier {
  ArtistResolver(this._index);

  final LocalIndex _index;
  AppSettings? _settings;

  static const String kDefaultBase = 'https://musicbrainz.org/ws/2';

  /// UA 携带可回访的 repo 标识；MB 明确要求有意义 UA，否则封锁 IP。
  static const String _userAgent =
      'SelfMusic/1.0.1 (self-hosted music player; contact via project homepage)';

  final Dio _dio = Dio(BaseOptions(
    baseUrl: kDefaultBase,
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    headers: {'User-Agent': _userAgent, 'Accept': 'application/json'},
  ));

  bool _busy = false;
  Timer? _wake;

  /// 令牌桶：全局（搜索+lookup 共享）1 请求/秒的下次允许时间（epoch ms）。
  int _nextAllowedAtMs = 0;

  /// 最近一次解析时间（信息页展示）。
  DateTime? lastResolveAt;
  int resolvedCount = 0;
  int missCount = 0;
  int ambiguousCount = 0;
  bool networkDown = false;

  void attachSettings(AppSettings s) {
    _settings = s;
    _dio.options.baseUrl = kDefaultBase;
  }

  bool get _autoAllowed => _settings?.artistResolveAuto ?? true;

  /// 启动后台循环：先补一轮，之后按工作集/退避时间自动唤醒。
  void start() {
    wake();
  }

  @override
  void dispose() {
    _wake?.cancel();
    super.dispose();
  }

  /// 外部（扫描结束 / 重试按钮 / 设置开关）提醒：有新工作或可再试。
  void wake() {
    if (_wake?.isActive ?? false) return;
    _wake = Timer(const Duration(milliseconds: 50), _cycle);
  }

  /// 立即批量跑一轮（主动触发 / 启动）。
  Future<void> runOnceNow() async {
    await _runBatch();
    _scheduleNext(idle: true);
  }

  /// 全部 local/ambiguous 重置为 pending 重新解析。
  Future<void> retryAll() async {
    await _index.artistRetry();
    wake();
  }

  /// 单个（歧义/未命中）重试。
  Future<void> retryOne(String canonicalKey) async {
    await _index.artistRetry(canonicalKey: canonicalKey);
    wake();
  }

  /// 歧义人工选择的候选（不复原搜索结果，只读）。
  Future<List<MbArtistHit>> candidatesFor(String canonicalKey) async {
    final row = _index.artistRowByCanonical(canonicalKey);
    if (row == null) return const [];
    final part = splitArtistPart(row.displayName);
    final name = part.hasCv ? part.cvName! : row.displayName;
    try {
      return await _search(name, limit: 10);
    } catch (_) {
      return const [];
    }
  }

  /// 人工绑定候选到该 canonical（全新 mbid 走 upsert，已有则合流）。
  Future<void> bindManual(String canonicalKey, MbArtistHit hit) async {
    final row = _index.artistRowByCanonical(canonicalKey);
    if (row == null) return;
    final merged = await _index.artistMergeMbid(
      canonicalKey: canonicalKey,
      fromArtistKey: row.artistKey,
      mbid: hit.mbid,
      displayName: hit.name,
      type: hit.type ?? 'person',
      disambiguation: hit.disambiguation,
      names: hit.toNames(),
      groups: const [],
    );
    if (!merged) {
      await _index.artistUpsert(
        artistKey: row.artistKey,
        canonicalKey: canonicalKey,
        mbid: hit.mbid,
        displayName: hit.name,
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        names: hit.toNames(),
        groups: const [],
        type: hit.type ?? 'person',
        disambiguation: hit.disambiguation,
        resolvedAt: DateTime.now().toIso8601String(),
      );
    }
    resolvedCount++;
    notifyListeners();
    wake();
  }

  // ---------- 后台循环 ----------

  Future<void> _cycle() async {
    _wake = null;
    if (_busy) {
      wake();
      return;
    }
    _busy = true;
    try {
      if (_autoAllowed) await _runBatch();
      _scheduleNext(idle: true);
    } catch (e, st) {
      debugPrint('artist resolve cycle error: $e\n$st');
      _scheduleNext();
    } finally {
      _busy = false;
    }
  }

  void _scheduleNext({bool idle = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    var waitMs = const Duration(seconds: 2).inMilliseconds;
    if (idle) {
      // 有 pending/到期的工作→立刻；否则等最早退避时间或 60s 安全周期。
      final due = _index.artistWorkSet(limit: 1, nowEpochMs: now);
      if (due.isEmpty) {
        final rs = _index.minArtistNextAt();
        waitMs = rs == null
            ? const Duration(seconds: 60).inMilliseconds
            : (rs > now ? rs - now : const Duration(seconds: 1).inMilliseconds);
      }
    }
    _wake?.cancel();
    _wake = Timer(Duration(milliseconds: waitMs.clamp(100, 3600000)), _cycle);
  }

  Future<void> _runBatch() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final items = _index.artistWorkSet(limit: 4, nowEpochMs: now);
    if (items.isEmpty) return;
    for (final item in items) {
      try {
        await _resolveOne(item);
        networkDown = false;
      } on DioException catch (e) {
        networkDown = e.error is DioException;
        await _markBackoff(item, _retryAfterMs(e));
      } catch (_) {
        await _markBackoff(item, 0);
      }
      notifyListeners();
    }
  }

  Future<void> _resolveOne(ArtistWorkItem item) async {
    final part = splitArtistPart(item.displayName);
    final searchName = part.hasCv ? part.cvName! : item.displayName;
    final hits = await _search(searchName, limit: 10);
    final key = artistCanonicalKey(searchName);
    final strong = hits
        .where((h) =>
            artistCanonicalKey(h.name) == key ||
            h.aliases.any(
                (al) => (al['name'] as String?) != null && artistCanonicalKey(al['name'] as String) == key))
        .toList();
    final nowIso = DateTime.now().toIso8601String();
    if (strong.length == 1) {
      final h = strong.first;
      // P2：对已解析身份做一次 lookup，按白名单关系类型（团体/成员/CD 角色）填
      // groups JSON（供歌手页信息与后续展示）；失败不影响本次 resolved 结果。
      final groups = await _lookupGroups(h);
      final merged = await _index.artistMergeMbid(
        canonicalKey: item.canonicalKey,
        fromArtistKey: item.artistKey,
        mbid: h.mbid,
        displayName: h.name,
        type: h.type ?? 'person',
        disambiguation: h.disambiguation,
        names: h.toNames(role: part.hasCv ? part.base : null),
        groups: groups,
      );
      if (!merged) {
        await _index.artistUpsert(
          artistKey: item.artistKey,
          canonicalKey: item.canonicalKey,
          mbid: h.mbid,
          displayName: h.name,
          status: 'resolved',
          errorCount: 0,
          nextAt: 0,
          names: h.toNames(role: part.hasCv ? part.base : null),
          groups: groups,
          type: h.type ?? 'person',
          disambiguation: h.disambiguation,
          resolvedAt: nowIso,
        );
      }
      resolvedCount++;
      lastResolveAt = DateTime.now();
    } else if (strong.length > 1) {
      // 同名多真人：不自动合并，留给人工选择（下一次重试 24h 后）。
      await _index.artistUpsert(
        artistKey: item.artistKey,
        canonicalKey: item.canonicalKey,
        displayName: item.displayName,
        status: 'ambiguous',
        errorCount: item.errorCount,
        nextAt: DateTime.now()
            .add(const Duration(hours: 24))
            .millisecondsSinceEpoch,
        names: const [],
        groups: const [],
      );
      ambiguousCount++;
      lastResolveAt = DateTime.now();
    } else {
      // 无可靠命中：占位 local，指数退避后再试（MB 数据可能后来补上）。
      await _markBackoff(item, 0);
      missCount++;
    }
  }

  Future<void> _markBackoff(ArtistWorkItem item, int extraMs) async {
    final err = item.errorCount + 1;
    final base = err >= 4 ? 300000 : 10000 * (1 << (err - 1).clamp(0, 3));
    await _index.artistUpsert(
      artistKey: item.artistKey,
      canonicalKey: item.canonicalKey,
      displayName: item.displayName,
      status: 'local',
      errorCount: err,
      nextAt:
          DateTime.now().millisecondsSinceEpoch + (extraMs > base ? extraMs : base),
      names: const [],
      groups: const [],
    );
  }

  int _retryAfterMs(DioException e) {
    final sec = e.response?.headers.value('retry-after');
    final v = int.tryParse(sec ?? '');
    if (v != null) return v * 1000;
    final status = e.response?.statusCode;
    if (status == 503 || status == 429) return 60000;
    return 60000;
  }

  // ---------- MusicBrainz 请求 ----------

  /// 搜索：dismax 让服务端转义特殊字符；`alias:` 覆盖 MB 别名命中；
  /// 每个 hit 自带 aliases/type/disambiguation/country/life-span，选型零额外请求。
  Future<List<MbArtistHit>> _search(String name, {int limit = 10}) async {
    final escaped = name.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    final query = 'artist:"$escaped" OR alias:"$escaped"';
    final resp = await _get('/artist/', {
      'query': query,
      'limit': '$limit',
      'fmt': 'json',
      'dismax': 'true',
    });
    final data = resp.data;
    if (data is! Map<String, dynamic>) return const [];
    final list = data['artists'];
    if (list is! List) return const [];
    return [
      for (final a in list.cast<Map<String, dynamic>>())
        MbArtistHit(
          mbid: (a['id'] as String?) ?? '',
          name: (a['name'] as String?) ?? '',
          score: (a['score'] as num?)?.toDouble() ?? 0,
          sortName: a['sort-name'] as String?,
          type: a['type'] as String?,
          disambiguation: a['disambiguation'] as String?,
          country: a['country'] as String?,
          beginYear: _lifeSpanYear(a['life-span'], 'begin'),
          endYear: _lifeSpanYear(a['life-span'], 'end'),
          aliases: (a['aliases'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        ),
    ];
  }

  Future<Response<dynamic>> _get(String path, Map<String, dynamic> q) async {
    await _throttle();
    try {
      return await _dio.get(path, queryParameters: q);
    } on DioException {
      rethrow;
    }
  }

  /// P2：lookup 一次已解析身份的关系（member_of/former/voice actor/
  /// collaboration/subgroup 白名单），折成 groups JSON。硬限流 1 次/秒由全局
  /// 令牌桶保证；超限/失败静默返回空（本次 resolved 已成立）。
  Future<List<Map<String, dynamic>>> _lookupGroups(MbArtistHit h) async {
    const whitelist = {
      'member of band',
      'former member of band',
      'voice actor',
      'collaboration',
      'subgroup',
      'member of',
      'vote held in',
      'performing orchestra',
      'conductor of',
    };
    try {
      final resp = await _get('/artist/${h.mbid}', {
        'inc': 'artist-rels+aliases',
        'fmt': 'json',
      });
      final data = resp.data;
      if (data is! Map<String, dynamic>) return const [];
      final rels = data['relations'];
      if (rels is! List) return const [];
      final out = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final rel in rels.cast<Map<String, dynamic>>()) {
        final type = rel['type'] as String?;
        if (type == null || !whitelist.contains(type)) continue;
        final target = rel['target'];
        if (target is! Map<String, dynamic>) continue;
        final name = target['name'] as String?;
        final id = target['id'] as String?;
        final t = target['type'] as String?;
        if (name == null) continue;
        final k = '\u0000$type\u0000$id';
        if (!seen.add(k)) continue;
        out.add({
          'name': name,
          'name_type': 'member' == type || type.endsWith('band') ? 'member' : 'related',
          'type': type,
          if (id != null) 'mbid': id,
          if (t != null) 'target_type': t,
          if (rel['direction'] != null) 'direction': rel['direction'],
        });
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// 全局令牌桶：任意两次请求间隔 ≥1 秒（MB 硬限流）。
  Future<void> _throttle() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _nextAllowedAtMs) {
      await Future.delayed(Duration(milliseconds: _nextAllowedAtMs - now));
    }
    _nextAllowedAtMs = DateTime.now().millisecondsSinceEpoch + 1000;
  }

  static String? _lifeSpanYear(Object? span, String field) {
    if (span is! Map<String, dynamic>) return null;
    final v = span[field];
    return v is String && v.isNotEmpty ? v : null;
  }
}