import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/local/app_settings.dart';
import '../data/local/local_index.dart';

/// 按 MBID 取到的实体 + 关系（**一次请求**，Lookup 与 artist-rels 合并的结果）。
///
/// 以前重解析要先 lookup 拿实体、再单独拉一次关系，等于同一个 MBID 打了两次；
/// `inc=artist-rels+aliases` 一次就给全，所以合成一个对象往下传。
class MbArtistEntity {
  final MbArtistHit hit;

  /// MB 原始关系（已校验过结构，失败会抛出而不是折成空）。
  final List<Map<String, dynamic>> relations;

  /// 匹配分：只有「先搜索再取实体」这条路有值，按已知 MBID 重取时是 0
  /// （拿不到搜索分就不写分，别把已记录的分数抹成 0）。
  final double score;

  const MbArtistEntity({
    required this.hit,
    required this.relations,
    this.score = 0,
  });
}

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
///   本地别名直查（[LocalIndex.artistRowByAnyName]）→ MB 搜索 → 脏数据过滤后取首个候选；
/// - 采纳策略不做本地字符归一化（canonicalKey 保持原始拼写）：名字对不上的活交给
///   MB 检索侧的归一化，所以 `Petit Rabbit's` 能命中 `Petit Rabbit’s`；
/// - 解析成功后沿 artist-rels 递归展开成员（Group→Character→Person），成员身份直接
///   按关系里的 mbid 建为 resolved，不再单独搜索；
/// - 全局令牌桶限流 **1 req/s**（MB 服务端硬限流），尊重 429/503 与 Retry-After，
///   失败按 error_count 指数退避（10s→30s→60s→5min）；
/// - names/groups 为 JSON 数组，alias 合流走 [LocalIndex.artistMergeMbid]。
class ArtistResolver extends ChangeNotifier {
  /// [dio] 只给测试注入假适配器用；正式跑固定用带 UA / 超时的默认实例。
  ArtistResolver(this._index, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: kDefaultBase,
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
              headers: {
                'User-Agent': _userAgent,
                'Accept': 'application/json'
              },
            ));

  final LocalIndex _index;
  AppSettings? _settings;

  static const String kDefaultBase = 'https://musicbrainz.org/ws/2';

  /// UA 携带可回访的 repo 标识；MB 明确要求有意义 UA，否则封锁 IP。
  static const String _userAgent =
      'SelfMusic/1.0.1 (self-hosted music player; contact via project homepage)';

  /// 脏数据过滤后的最低分：MB 对精确匹配给 100，近似 80+，再往下基本是噪声。
  static const double _minScore = 60;

  /// 占位名（MB 数据里常见的「无主」条目）：这些实体一旦被采纳，歌手页会多出
  /// 一堆叫「[no artist]」的假歌手。
  static const _placeholderNames = {
    '[no artist]',
    '[unknown]',
    '[none]',
    '[noartist]',
    '[no name]',
    'unknown',
    'unknown artist',
    'various artists',
    'various',
    'various artists.',
    'alias',
    'n/a',
    'na',
    'none',
    'null',
    'unspecified',
    'unknown artist.',
    '未知',
    '未知艺术家',
    '不详',
  };

  /// MB 的 type 白名单（落到 `artists.type`；表里的语义是 MB 原始类型）。
  /// 'artist' 是 MB 对类型未知的旧式实体，保留可用。
  static const _allowedTypes = {
    'person',
    'group',
    'character',
    'orchestra',
    'choir',
    'other',
    'artist',
  };

  /// 可作为「所属团体/角色」记进 groups JSON 的关系类型。
  static const _groupRelTypes = {
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

  /// 单轮展开最多递归几跳：Group(0) → Character(1) → Person(2) 足够。
  static const int kMaxMemberDepth = 2;

  /// 单轮展开最多新查的实体数（MB 1 req/s，这个上限就是时间上限，防止超大社团拖死循环）。
  static const int kMaxExpansion = 500;

  /// 任意两次 MB 请求之间的最小间隔（毫秒）。MB 硬限流 1 req/s，留 10ms 余量。
  static const int _kMinRequestGapMs = 1010;

  /// 本轮已展开过的 mbid（visited，防环 + 配 [kMaxExpansion] 计数）。
  final Set<String> _expandedMbids = <String>{};

  final Dio _dio;

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

  /// 全部 local/ambiguous 重置为 pending 重试解析。
  /// 手动路径不依赖「自动后台解析」开关：重置后立即直跑一轮。
  Future<void> retryAll() async {
    await _index.artistRetry();
    await runOnceNow();
  }

  /// 单个（歧义/未命中）重试。
  /// 手动路径不依赖「自动后台解析」开关：重置后立即直跑一轮。
  Future<void> retryOne(String canonicalKey) async {
    await _index.artistRetry(canonicalKey: canonicalKey);
    await runOnceNow();
  }

  /// 强制解析全部歌手（设置页「强制解析」按钮）：连 resolved 一起打回 pending 并清
  /// expanded_at，成员随之重新展开。已有 mbid 的按该实体重取（不会漂到别的真人）。
  /// 后台循环会按批顺序推进（MB 1 req/s，大库需要跑一阵）。
  Future<void> forceRetryAll() async {
    await _index.artistForceRetry(all: true);
    await runOnceNow();
  }

  /// 重新解析单个歌手（歌手页「重新解析」按钮）。
  /// [artistKey] 为空时退回 [canonicalKey]。
  Future<void> forceRetryOne({String? artistKey, String? canonicalKey}) async {
    await _index.artistForceRetry(
        all: false, artistKey: artistKey, canonicalKey: canonicalKey);
    await runOnceNow();
  }

  /// 歧义人工选择的候选（不复原搜索结果，只读）。
  Future<List<MbArtistHit>> candidatesFor(String canonicalKey) async {
    final row = _index.artistRowByCanonical(canonicalKey);
    if (row == null) return const [];
    try {
      return await _search(row.displayName, limit: 10);
    } catch (_) {
      return const [];
    }
  }

  /// 人工绑定候选到该 canonical（全新 mbid 走 upsert，已有则合流）。
  Future<void> bindManual(String canonicalKey, MbArtistHit hit) async {
    final row = _index.artistRowByCanonical(canonicalKey);
    if (row == null) return;
    await _bind(canonicalKey, row.artistKey,
        await _requireEntity(hit.mbid, score: hit.score));
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
        // 静默退避是「鸿蒙根证书缺失数日定位不出去」的直接教训：每个失败
        // 都要留下类型与原因（hilog 可见），再进退避。
        debugPrint(
            '[artist-resolve] ${item.displayName} 失败: ${e.type.name} ${e.message ?? ''} ${e.error ?? ''}');
        networkDown = e.error is DioException;
        await _markBackoff(item, _retryAfterMs(e));
      } catch (e) {
        debugPrint('[artist-resolve] ${item.displayName} 异常: $e');
        await _markBackoff(item, 0);
      }
      notifyListeners();
    }
  }

  Future<void> _resolveOne(ArtistWorkItem item) async {
    final searchName = item.displayName;

    // 歌手处理.txt 第 3 步：本地别名表直查（别名已在 artists.names JSON 里）。
    // 命中已解析身份就直接合流，省掉一次 artist 搜索（仍会 lookup 一次关系来展开成员）。
    final local = _index.artistRowByAnyName(searchName);
    if (local != null && local.isResolved && local.mbid != null) {
      final entity = await _requireEntity(local.mbid!,
          score: (local.matchScore ?? 0).toDouble());
      await _bind(item.canonicalKey, item.artistKey, entity);
      resolvedCount++;
      lastResolveAt = DateTime.now();
      return;
    }

    // 已经拿到过 MBID（重试/强制解析）：直接按该实体重取，不要再搜索——
    // 搜索榜首会随 MB 数据变化，重新解析不该悄悄换成另一个真人。
    final known = item.mbid;
    if (known != null && known.isNotEmpty) {
      // 一次请求同时拿实体和关系：以前这里先 lookup、再在 _bind 里拉一次关系，
      // 同一个 MBID 打了两次。
      final entity = await _fetchEntity(known);
      if (entity != null) {
        await _bind(item.canonicalKey, item.artistKey, entity);
        resolvedCount++;
        lastResolveAt = DateTime.now();
        return;
      }
    }

    final hits = await _search(searchName, limit: 10);
    final hit = pickFirstUsable(hits);
    if (hit != null) {
      final entity = await _requireEntity(hit.mbid, score: hit.score);
      await _bind(item.canonicalKey, item.artistKey, entity);
      resolvedCount++;
      lastResolveAt = DateTime.now();
    } else {
      // 脏数据过滤后无可用候选：占位 local，指数退避后再试（MB 数据可能后来补上）。
      await _markBackoff(item, 0);
      missCount++;
    }
  }

  /// 脏数据过滤后取第一个可用候选（用户确认：不再判断 strong，MB 已做检索归一化）。
  ///
  /// 过滤掉：空 mbid / 空名、占位名（`[no artist]`、`Unknown Artist`、
  /// `Various Artists` 等）、MB 不认的类型、以及低分噪声。
  static MbArtistHit? pickFirstUsable(List<MbArtistHit> hits) {
    for (final h in hits) {
      if (h.mbid.isEmpty) continue;
      final name = h.name.trim();
      if (name.isEmpty) continue;
      if (_isPlaceholder(name)) continue;
      final t = _normType(h.type);
      if (t != null && !_allowedTypes.contains(t)) continue;
      if (h.score < _minScore) continue;
      return h;
    }
    return null;
  }

  static bool _isPlaceholder(String name) {
    final k = name.toLowerCase();
    return _placeholderNames.any((p) => k == p);
  }

  /// 绑定命中结果：合流到已有 mbid 身份，没有就 upsert；随后展开成员关系。
  ///
  /// members 展开失败（429/网络）不影响本次 resolved——身份已定，成员边下次再补。
  Future<void> _bind(String canonicalKey, String fromArtistKey,
      MbArtistEntity entity) async {
    final h = entity.hit;
    // P2：按白名单关系类型（团体/成员/CD 角色）填 groups JSON（供歌手页信息与
    // 后续展示）；失败不影响本次 resolved 结果。关系由 [entity] 自带，
    // 这里不再发第二次 MB 请求。
    final groups = parseGroupRelations(entity.relations);
    // 本地别名合流来的 score 是 0（没搜过），别把已记录的分数抹成 0。
    final score = entity.score > 0 ? entity.score : null;
    // MB 的 type 是 `Group`/`Character`/`Person`，统一小写落库。
    final selfType = _normType(h.type) ?? 'person';
    final merged = await _index.artistMergeMbid(
      canonicalKey: canonicalKey,
      fromArtistKey: fromArtistKey,
      mbid: h.mbid,
      displayName: h.name,
      type: selfType,
      disambiguation: h.disambiguation,
      names: h.toNames(),
      groups: groups,
      matchScore: score,
    );
    String? key;
    if (!merged) {
      await _index.artistUpsert(
        artistKey: fromArtistKey,
        canonicalKey: canonicalKey,
        mbid: h.mbid,
        displayName: h.name,
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        names: h.toNames(),
        groups: groups,
        type: selfType,
        disambiguation: h.disambiguation,
        resolvedAt: DateTime.now().toIso8601String(),
        matchScore: score,
      );
      key = fromArtistKey;
    } else {
      key = _index.artistRowByCanonical(canonicalKey)?.artistKey;
    }
    if (key != null) {
      await _expandMembers(key, h.mbid,
          selfType: selfType, rels: entity.relations);
    }
  }

  /// 成员递归展开（歌手处理.txt 第 41-45 行）。
  ///
  /// 一次 artist-rels 就把关系里的成员身份建出来（自带 mbid → 直接 resolved），
  /// 不为每个成员单独搜索 MB；Group 的成员是 Character 时再查一层拿 voice actor，
  /// 落到 Person 停手。visited 防环，展开规模封顶 [kMaxExpansion]。
  Future<void> _expandMembers(String artistKey, String mbid,
      {required String selfType,
      List<Map<String, dynamic>>? rels,
      int depth = 0}) async {
    final members =
        parseMemberRelations(rels ?? (await _requireEntity(mbid)).relations, selfType);
    if (members.isEmpty) {
      // 查过关系确实没成员：清掉可能存在的旧边，记 expanded_at，歌手页据此回落显示本实体。
      await _index.artistSetMembers(artistKey: artistKey, members: const []);
      return;
    }
    final keys =
        await _index.artistSetMembers(artistKey: artistKey, members: members);
    await _markExpanded(artistKey);
    if (depth >= kMaxMemberDepth) return;
    for (var i = 0; i < members.length && i < keys.length; i++) {
      final key = keys[i];
      if (key.isEmpty) continue;
      final type = (members[i]['type'] as String?) ?? 'person';
      final childMbid = members[i]['mbid'] as String?;
      if (childMbid == null) continue;
      // Person 就是歌手页要显示的末端，到此为止；Group/Character 再往下走一层。
      if (type == 'person') continue;
      if (_expandedMbids.length >= kMaxExpansion) break;
      _expandedMbids.add(childMbid);
      final childKey = _index.artistRowByMbid(childMbid)?.artistKey;
      if (childKey == null) continue;
      await _expandMembers(childKey, childMbid,
          selfType: type, depth: depth + 1);
    }
  }

  /// 标记「已查过关系」。只写 expanded_at，不碰成员边。
  /// （曾经写成 artistSetMembers(members: [])，那是全量替换，会把刚建好的边删光。）
  Future<void> _markExpanded(String artistKey) =>
      _index.artistMarkExpanded(artistKey);

  Future<void> _markBackoff(ArtistWorkItem item, int extraMs) async {
    final err = item.errorCount + 1;
    final base = err >= 4 ? 300000 : 10000 * (1 << (err - 1).clamp(0, 3));
    await _index.artistMarkError(
      artistKey: item.artistKey,
      errorCount: err,
      nextAt: DateTime.now().millisecondsSinceEpoch +
          (extraMs > base ? extraMs : base),
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

  /// 按已知 MBID 取实体+关系（重试/强制解析走这条，不重新搜索，避免漂到别的真人）。
  ///
  /// 一次请求搞定：`inc=artist-rels+aliases` 同时给实体字段、别名和关系，
  /// 不用再单独拉一遍关系。
  /// 实体不存在/已合并（404/400）返回 null 退回搜索；**其余失败照常抛出**，
  /// 交由退避重试——不能折成「无关系」，否则组合会被永久记成「没成员」
  /// 而不再重试展开（调用方靠「空 = 确实无成员」来记 expanded_at）。
  /// MB 对真无关系的实体照样返回 200 + 空 relations，所以重试不会失控。
  Future<MbArtistEntity?> _fetchEntity(String mbid, {double score = 0}) async {
    if (mbid.isEmpty) return null;
    try {
      final resp = await _get('/artist/$mbid', {
        'inc': 'artist-rels+aliases',
        'fmt': 'json',
      });
      final data = resp.data;
      if (data is! Map<String, dynamic>) {
        throw StateError('artist 响应不是对象: ${data.runtimeType}');
      }
      final rels = data['relations'];
      if (rels != null && rels is! List) {
        throw StateError('artist.relations 不是数组: ${rels.runtimeType}');
      }
      return MbArtistEntity(
        hit: MbArtistHit(
          mbid: (data['id'] as String?) ?? mbid,
          name: (data['name'] as String?) ?? '',
          type: data['type'] as String?,
          sortName: data['sort-name'] as String?,
          disambiguation: data['disambiguation'] as String?,
          country: data['country'] as String?,
          beginYear: _lifeSpanYear(data['life-span'], 'begin'),
          endYear: _lifeSpanYear(data['life-span'], 'end'),
          aliases:
              (data['aliases'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        ),
        relations:
            rels == null ? const [] : rels.cast<Map<String, dynamic>>(),
        score: score,
      );
    } on DioException catch (e) {
      // 实体确实没了才退回搜索；其余（限流/断网）继续抛给退避。
      final code = e.response?.statusCode;
      if (code == 404 || code == 400) return null;
      rethrow;
    }
  }

  /// 同 [_fetchEntity]，但实体取不到就算失败（调用方已定好要用哪个实体，不退回搜索）。
  Future<MbArtistEntity> _requireEntity(String mbid, {double score = 0}) async {
    final e = await _fetchEntity(mbid, score: score);
    if (e == null) throw StateError('MB 实体取不到（404）: $mbid');
    return e;
  }

  Future<Response<dynamic>> _get(String path, Map<String, dynamic> q) async {
    await _throttle();
    try {
      return await _dio.get(path, queryParameters: q);
    } on DioException {
      rethrow;
    }
  }

  /// 折成 groups JSON（信息页展示用的「所属团体/角色」）。
  static List<Map<String, dynamic>> parseGroupRelations(
      List<Map<String, dynamic>> rels) {
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final rel in rels) {
      final type = rel['type'] as String?;
      if (type == null || !_groupRelTypes.contains(type)) continue;
      final other = _otherArtist(rel);
      if (other == null) continue;
      final name = other['name'] as String?;
      final id = other['id'] as String?;
      if (name == null) continue;
      final k = '$type\u0000$id';
      if (!seen.add(k)) continue;
      out.add({
        'name': name,
        'name_type': type.endsWith('band') ? 'member' : 'related',
        'type': type,
        if (id != null) 'mbid': id,
        if (other['type'] != null) 'target_type': other['type'],
        if (rel['direction'] != null) 'direction': rel['direction'],
        // 对端的消歧义串：角色是作品名（`ご注文はうさぎですか？`），组合是副标题。
        // 歌手详情页的「角色/组合」栏靠它区分同名的不同角色。
        if (other['disambiguation'] != null)
          'disambiguation': other['disambiguation'],
      });
    }
    return out;
  }

  /// MB 的关系里，对端实体放在 `artist` 键下（`target` 是给 work/recording 用的）。
  static Map<String, dynamic>? _otherArtist(Map<String, dynamic> rel) {
    final a = rel['artist'];
    if (a is Map<String, dynamic>) return a;
    final t = rel['target'];
    return t is Map<String, dynamic> ? t : null;
  }

  /// MB 的 type 是首字母大写（`Group`/`Person`/`Character`），库里统一小写
  /// （schema 默认 'person'，歌手页按 `type='person'` 判定）。两边都按小写比对。
  static String? _normType(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return raw.toLowerCase();
  }

  /// 成员边数据（歌手处理.txt 第 43 行：artist-rels 的 member 类关系直接建边）。
  ///
  /// **不能用 `direction` 字段判断上下级**。MB 的 `direction` 只说明「当前实体是
  /// 关系的哪一端」，而「哪端是成员」取决于关系类型的语义 + 对端实体的 type。
  /// 实测（2026-10）：`振り回され隊` 名下三条 `member of band` 全是
  /// `direction=backward`（当前实体是被加入的那一方，即组合本身），
  /// `シャロ` 的 `voice actor` 也是 `backward`（声优是关系发起方）。
  /// 所以这里按「关系类型 + 对端 type」判定谁是成员：
  ///
  /// - `member of band` 对端是 Person/Character → 对方是本组合的成员（建边）；
  ///   对端是 Group/Orchestra/Choir → 反向，本实体属于那个团体（不建边，落 groups）。
  /// - `voice actor` 仅当「本实体是 Character 且对端是 Person」时建边
  ///   （声优是角色的成员）；Person 声优过的角色属于反向信息。
  /// - `subgroup` 对端是 Group → 对方是子团体，建边。
  /// - `collaboration` / `performing orchestra` 双方同级，语义不构成上下级，一律不建边。
  ///
  /// 不建反向边，个人与团体就不会互为成员形成环。
  static List<Map<String, dynamic>> parseMemberRelations(
      List<Map<String, dynamic>> rels, String selfType) {
    const bandTypes = {'group', 'orchestra', 'choir'};
    final out = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final rel in rels) {
      final type = rel['type'] as String?;
      if (type == null) continue;
      final other = _otherArtist(rel);
      if (other == null) continue;
      final otherType = _normType(other['type']);
      final isMember = switch (type) {
        'member of band' => otherType != null && !bandTypes.contains(otherType),
        'subgroup' => bandTypes.contains(otherType),
        'voice actor' => selfType == 'character' && otherType == 'person',
        _ => false,
      };
      if (!isMember) continue;
      final name = (other['name'] as String?)?.trim() ?? '';
      final id = (other['id'] as String?)?.trim() ?? '';
      // 无 mbid 的关系建不了可追溯的成员身份（下次展开会重复建），直接跳过。
      if (name.isEmpty || id.isEmpty) continue;
      if (!seen.add(id)) continue;
      out.add({
        'mbid': id,
        'name': name,
        'type': otherType ?? 'person',
        'relation': type,
      });
      if (out.length >= kMaxExpansion) break;
    }
    return out;
  }

  /// 全局令牌桶：任意两次请求间隔 ≥ [_kMinRequestGapMs]。
  /// MB 的硬限流是 1 req/s，按「服务端整秒」计；本地恰好排到 1000ms 会在偶发情况下
  /// 撞进同一个服务端秒而被 503 打回（退避能自愈，但会白白浪费一整轮），
  /// 故留 10ms 余量。
  Future<void> _throttle() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now < _nextAllowedAtMs) {
      await Future.delayed(Duration(milliseconds: _nextAllowedAtMs - now));
    }
    _nextAllowedAtMs =
        DateTime.now().millisecondsSinceEpoch + _kMinRequestGapMs;
  }

  static String? _lifeSpanYear(Object? span, String field) {
    if (span is! Map<String, dynamic>) return null;
    final v = span[field];
    return v is String && v.isNotEmpty ? v : null;
  }
}
