import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/artist_names.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/models/artist.dart';
import 'package:selfmusic/services/artist_resolver.dart';
import 'package:sqlite3/open.dart';

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

Future<(LocalIndex, Directory)> _openIndex() async {
  open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
  final dir = await Directory.systemTemp.createTemp('selfmusic_artist_');
  PathProviderPlatform.instance = _FakePathProvider(dir.path);
  final index = LocalIndex();
  await index.open();
  return (index, dir);
}

/// 关库并删临时目录。
///
/// 写隔离进程退出后句柄释放有延迟，Windows 上立刻删目录会撞 errno=32
/// （另一个程序正在使用此文件）。这里带退避重试，让断言结果不被清理报错盖掉。
Future<void> _dispose(LocalIndex index, Directory dir) async {
  index.close();
  for (var i = 0; i < 20; i++) {
    try {
      if (!dir.existsSync()) return;
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
    }
  }
}

DirectSongRow _song(String ref, String artist, {String? album}) => DirectSongRow(
      sourceKey: 'local:test',
      ref: ref,
      title: '标题 $ref',
      artist: artist,
      album: album ?? '专辑',
      duration: 100,
      format: 'mp3',
      size: 1024,
      mtime: 1,
    );

/// 记录请求并回固定 JSON 的假 MB 适配器。
class _RecordingAdapter implements HttpClientAdapter {
  final Map<String, dynamic> body;

  /// 按路径的额外行为（返回状态码=报错，不给 body）。
  final int? Function(Uri uri)? failOn;

  /// 搜索响应（`/artist/`）之外的实体响应（`/artist/<mbid>`）。
  final Map<String, dynamic>? entity;

  final List<Uri> calls = [];

  _RecordingAdapter(this.body, {this.failOn, this.entity});

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options.uri);
    final code = failOn?.call(options.uri);
    if (code != null) return ResponseBody.fromString('{}', code);
    // 搜索打的是 `/artist/`（结尾斜杠），按 MBID 取实体才是 `/artist/<mbid>`。
    final isSearch = options.uri.path.endsWith('/artist/');
    final data = isSearch ? body : entity ?? body;
    return ResponseBody.fromString(jsonEncode(data), 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioOf(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://mb.test/ws/2'));
  dio.httpClientAdapter = adapter;
  return dio;
}

void main() {
  // ---------- 歌手处理.txt：名称预处理（剥括号 / 合作串拆分 / 原串键） ----------

  test('聚合键：不做归一化，原样返回（不同写法各自成身份）', () {
    expect(artistCanonicalKey('ABBA'), 'ABBA');
    expect(artistCanonicalKey('abba'), 'abba');
    expect(artistCanonicalKey('Petit Rabbit\u2019s'), 'Petit Rabbit\u2019s');
    expect(artistCanonicalKey('  ABBA  '), '  ABBA  ');
  });

  test('剥括号：CV/声优/版本/feat 注解一律剔除，括号内分隔符不再干扰', () {
    expect(stripParens('ココア(CV.佐倉綾音)'), 'ココア');
    expect(stripParens('ココア(佐倉綾音)'), 'ココア');
    expect(stripParens('ココア（佐倉綾音）'), 'ココア');
    expect(stripParens('ココア (佐倉綾音)'), 'ココア');
    expect(stripParens('群青(anime size)'), '群青');
    expect(stripParens('A (feat. B)'), 'A');
    expect(stripParens('ココア&モカ (佐倉綾音&茅野愛衣)'), 'ココア&モカ');
    expect(stripParens('(CV:内田真礼)'), '');
    expect(stripParens('ABBA'), 'ABBA');
  });

  test('合作串拆分：& / 全角＆ / feat. /，/、/・，只剩一段则原样', () {
    expect(artistCollabParts('周杰伦 & 费玉清'), ['周杰伦', '费玉清']);
    expect(artistCollabParts('ABBA＆Boney M'), ['ABBA', 'Boney M']);
    expect(artistCollabParts('A&B'), ['A', 'B']);
    expect(artistCollabParts('A & B & C'), ['A', 'B', 'C']);
    expect(artistCollabParts('A feat. B'), ['A', 'B']);
    expect(artistCollabParts('A feat B'), ['A', 'B']);
    expect(artistCollabParts('A feat.B'), ['A', 'B']);
    expect(artistCollabParts('ココア (佐倉綾音), チノ (水瀬いのり)'),
        ['ココア (佐倉綾音)', 'チノ (水瀬いのり)']);
    expect(artistCollabParts('ココア、チノ、 リゼ'), ['ココア', 'チノ', 'リゼ']);
    expect(artistCollabParts('ココア・千夜'), ['ココア', '千夜']);
    expect(artistCollabParts('A，B'), ['A', 'B']);
    // 空段丢弃；无实质拆分返回原串（非合作歌行为不变）。
    expect(artistCollabParts(' & A'), ['A']);
    expect(artistCollabParts('ABBA'), ['ABBA']);
    expect(artistCollabParts('defeat'), ['defeat']);
    expect(artistCollabParts('Bread & Butter Shop'), ['Bread', 'Butter Shop']);
  });

  test('身份键：剥括号后逐段原样定键（CV 不再特殊解析）', () {
    expect(artistCanonicalOf('ココア(CV.佐倉綾音)'), 'ココア');
    expect(artistCanonicalOf('ココア(佐倉綾音)'), 'ココア');
    expect(artistCanonicalOf('ココア (佐倉綾音)'), 'ココア');
    expect(artistCanonicalOf('ＡＢＢＡ(ＷＥＳＴ)'), 'ＡＢＢＡ');
    expect(artistCanonicalOf('ABBA'), 'ABBA');
    expect(artistCanonicalOf('ＡＢＢＡ'), 'ＡＢＢＡ');
  });

  test('合作串身份键：各段独立 canonical，段内去重', () {
    expect(
        artistCollabCanonicals('周杰伦 & 费玉清'), [('周杰伦', '周杰伦'), ('费玉清', '费玉清')]);
    // 括号内容（含 CV 名单）剥除后各段原样定键。
    expect(artistCollabCanonicals('宇多田光 & 纱路(CV:内田真礼)'),
        [('宇多田光', '宇多田光'), ('纱路', '纱路')]);
    // 括号内 & 名单不参与拆分：成员外 & 才切。
    expect(artistCollabCanonicals('ココア&モカ (佐倉綾音&茅野愛衣)'),
        [('ココア', 'ココア'), ('モカ', 'モカ')]);
    // 全角 ＆ + 全角括号 + CV. 名单：同样干净分成两身份。
    expect(artistCollabCanonicals('ココア＆モカ（CV.佐倉綾音＆茅野愛衣）'),
        [('ココア', 'ココア'), ('モカ', 'モカ')]);
    // 无前缀括号与 `・` 分隔。
    expect(artistCollabCanonicals('ココア(佐倉綾音)・千夜(佐藤聡美)'),
        [('ココア', 'ココア'), ('千夜', '千夜')]);
    // 逗号多名表。
    expect(artistCollabCanonicals('ココア (佐倉綾音), チノ (水瀬いのり)'),
        [('ココア', 'ココア'), ('チノ', 'チノ')]);
    // 段内去重：A & A 只留一个。
    expect(artistCollabCanonicals('A & A'), [('A', 'A')]);
    // 非合作串：单个身份、显示名=原串。
    expect(artistCollabCanonicals('ABBA'), [('ABBA', 'ABBA')]);
  });

  // ---------- 歌手页点击分流：Artist.resolveState ----------

  test('resolveState：未解析一律不进歌曲，resolved/无状态可正常查看', () {
    Artist mk(String status, {String? canonical = 'c'}) => Artist(
        name: 'x',
        songCount: 1,
        albumCount: 1,
        canonicalKey: canonical,
        status: status);
    expect(mk('').resolveState, ArtistResolveState.normal);
    expect(mk('resolved').resolveState, ArtistResolveState.normal);
    // local/pending（重试图标）→ 重试态。
    expect(mk('local').resolveState, ArtistResolveState.retry);
    expect(mk('pending').resolveState, ArtistResolveState.retry);
    // ambiguous（需确认）→ 候选表。
    expect(mk('ambiguous').resolveState, ArtistResolveState.confirm);
    // 防御：pending/local 无 canonicalKey（非 identity 模式数据缺失）→ normal，
    // 避免弹了重试框也无处下发。
    expect(
        mk('pending', canonical: null).resolveState, ArtistResolveState.normal);
    expect(
        mk('local', canonical: null).resolveState, ArtistResolveState.normal);
  });

  test('Artist JSON 往返保留 canonicalKey/identityKey/状态', () {
    const a = Artist(
        name: 'ABBA',
        songCount: 2,
        albumCount: 1,
        identityKey: 'u1',
        canonicalKey: 'ABBA',
        status: 'ambiguous',
        mbid: 'm1');
    final b = Artist.fromJson(a.toJson());
    expect(b.name, 'ABBA');
    expect(b.identityKey, 'u1');
    expect(b.canonicalKey, 'ABBA');
    expect(b.status, 'ambiguous');
    expect(b.mbid, 'm1');
  });

  // ---------- 歌手处理.txt：身份映射 / 合并 / 重试 / 回收 ----------

  test('reconcile：同一写法合并为一身份，歌曲映射齐全', () async {
    final (index, dir) = await _openIndex();
    try {
      // 不做归一化：完全相同的写法才归到同一 canonical；两首歌映射齐全。
      await index.upsertSongs([
        _song('a', 'ABBA'),
        _song('b', 'ABBA'),
      ]);
      await index.reconcileArtists();

      // 两首歌同一 canonical → 单个身份行 + 桥。
      final stats = index.artistStats();
      expect(stats['total'], 1);
      expect(stats['pending'], 1);
      expect(stats['mapped'], 2);

      final row = index.artistRowByCanonical('ABBA');
      expect(row, isNotNull);
      expect(row!.displayName, 'ABBA');
      final groups = index.identityArtistGroups();
      expect(groups, hasLength(1));
      expect(groups.first.name, 'ABBA');
      expect(groups.first.songCount, 2);
      // identityArtistGroups 必须带出 canonical_key（解析服务按它寻址）。
      expect(groups.first.canonicalKey, 'ABBA');
      // pending 身份 → 重试态：点击只弹重新解析，不进歌曲列表。
      expect(groups.first.resolveState, ArtistResolveState.retry);
      expect(index.identitySongs(groups.first.identityKey!), hasLength(2));
      expect(index.identityFallbackGroups(), isEmpty);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('reconcile：剥括号后同角色写法并成一身份', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([
        _song('c', '纱路（CV:内田真礼）'),
        _song('d', '纱路'),
      ]);
      await index.reconcileArtists();

      // CV 注记被剥除 → 两首歌并成一个 canonical 身份。
      final row = index.artistRowByCanonical('纱路');
      expect(row, isNotNull);
      expect(index.artistStats()['total'], 1);
      expect(index.artistStats()['mapped'], 2);
      expect(index.identityArtistGroups().first.songCount, 2);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('reconcile：同名实体两种 canonical 经 mbid 合流', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([
        _song('c', '纱路'),
        _song('d', '内田真礼'),
      ]);
      await index.reconcileArtists();

      final charRow = index.artistRowByCanonical('纱路');
      final personRow = index.artistRowByCanonical('内田真礼');
      expect(charRow, isNotNull);
      expect(personRow, isNotNull);
      expect(charRow!.artistKey, isNot(personRow!.artistKey));

      // 真人先解析，角色随后解析到同一 mbid → 合流（跨 canonical 归并）。
      await index.artistUpsert(
        artistKey: personRow.artistKey,
        canonicalKey: '内田真礼',
        displayName: '内田真礼',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        names: const [
          {'name': '内田真礼', 'name_type': 'primary', 'is_primary': 1},
        ],
        groups: const [],
        mbid: 'mb-x',
        resolvedAt: DateTime.now().toIso8601String(),
      );
      final merged = await index.artistMergeMbid(
        canonicalKey: '纱路',
        fromArtistKey: charRow.artistKey,
        mbid: 'mb-x',
        displayName: '内田真礼',
        type: 'person',
        disambiguation: null,
        names: const [
          {'name': '内田真礼', 'name_type': 'primary', 'is_primary': 1},
          {'name': '纱路', 'name_type': 'role'},
        ],
        groups: const [],
      );
      expect(merged, isTrue);

      // 角色占位已被删除，桥改指向真人行；两首歌都挂在真人身份下。
      final stats = index.artistStats();
      expect(stats['total'], 1);
      expect(stats['resolved'], 1);
      expect(stats['mapped'], 2);
      final target = index.artistRowByCanonical('内田真礼');
      expect(target, isNotNull);
      // 角色 canonical 仍能经桥解析到真人行（防后 reconcile 重建占位）。
      expect(index.artistRowByCanonical('纱路')!.artistKey, target!.artistKey);
      final groups = index.identityArtistGroups();
      expect(groups, hasLength(1));
      expect(groups.first.songCount, 2);
      expect(groups.first.mbid, 'mb-x');
    } finally {
      await _dispose(index, dir);
    }
  });

  test('reconcile：二次跑到重复 canonical 不重建占位、映射稳定', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'RADWIMPS')]);
      await index.reconcileArtists();
      await index.reconcileArtists();
      final stats = index.artistStats();
      expect(stats['total'], 1);
      expect(stats['mapped'], 1);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('retry：local/ambiguous 重置 pending，未命中遗忘退避', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', '某独立音乐人')]);
      await index.reconcileArtists();
      final row = index.artistRowByCanonical('某独立音乐人')!;
      await index.artistUpsert(
        artistKey: row.artistKey,
        canonicalKey: row.canonicalKey,
        displayName: row.displayName,
        status: 'local',
        errorCount: 4,
        nextAt: DateTime.now().millisecondsSinceEpoch + 600000,
        names: const [],
        groups: const [],
      );
      expect(
          index.artistWorkSet(limit: 10).where((w) => w.nextAt == 0), isEmpty);

      await index.artistRetry();
      final back = index.artistRowByCanonical('某独立音乐人')!;
      expect(back.status, 'pending');
      expect(back.errorCount, 0);
      expect(back.nextAt, 0);
      expect(index.artistWorkSet(limit: 10), hasLength(1));
    } finally {
      await _dispose(index, dir);
    }
  });

  test('用户清空歌手后：映射删除，孤儿 pending 占位被回收', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', '独唱艺人')]);
      await index.reconcileArtists();
      expect(index.identityArtistGroups(), hasLength(1));

      await index.updateSongUserMeta('local:test', 'a', artist: '');
      await index.reconcileArtists();

      expect(index.artistRowByCanonical('独唱艺人'), isNull);
      expect(index.artistStats()['mapped'], 0);
      expect(index.identityArtistGroups(), isEmpty);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('搜索过滤与排序：identityArtistGroups 支持 query/排序', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([
        _song('a', 'AAA'),
        _song('b', 'BABYMETAL'),
      ]);
      await index.reconcileArtists();
      final all = index.identityArtistGroups();
      expect(all, hasLength(2));
      final filtered = index.identityArtistGroups(query: 'aaa');
      expect(filtered, hasLength(1));
      expect(filtered.first.name, 'AAA');
      // names JSON 已按「primary + 别名」写出可读结构。
      final row = index.artistRowByCanonical('AAA')!;
      expect(row.names.single['name'], 'AAA');
    } finally {
      await _dispose(index, dir);
    }
  });

  test('合作串：A & B 拆成两个独立身份，各自映射齐全', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', '周杰伦 & 费玉清')]);
      await index.reconcileArtists();

      final stats = index.artistStats();
      expect(stats['total'], 2);
      expect(stats['mapped'], 2);
      expect(stats['pending'], 2);

      final a = index.artistRowByCanonical('周杰伦')!;
      final b = index.artistRowByCanonical('费玉清')!;
      expect(a.artistKey, isNot(b.artistKey));
      expect(a.displayName, '周杰伦');
      expect(b.displayName, '费玉清');

      final groups = index.identityArtistGroups();
      expect(groups, hasLength(2));
      expect(groups.map((g) => g.name).toSet(), {'周杰伦', '费玉清'});
      expect(groups.every((g) => g.songCount == 1), isTrue);
      // 同一首歌同时挂在两身份下。
      expect(index.identitySongs(a.artistKey), hasLength(1));
      expect(index.identitySongs(b.artistKey), hasLength(1));

      // 幂等：二次 reconcile 不重建、映射稳定。
      await index.reconcileArtists();
      expect(index.artistStats()['total'], 2);
      expect(index.identityArtistGroups(), hasLength(2));
    } finally {
      await _dispose(index, dir);
    }
  });

  test('合作串与独立出现合并：周杰伦 & 费玉清 + 独唱周杰伦 → songCount=2', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([
        _song('a', '周杰伦 & 费玉清'),
        _song('b', '周杰伦'),
      ]);
      await index.reconcileArtists();

      final groups = index.identityArtistGroups();
      expect(groups, hasLength(2));
      final zhou = groups.firstWhere((g) => g.name == '周杰伦');
      final fei = groups.firstWhere((g) => g.name == '费玉清');
      expect(zhou.songCount, 2);
      expect(fei.songCount, 1);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('合作串 feat/全角＆/括号注记：都能独立成身份', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([
        _song('a', 'A feat. B'),
        _song('b', '宇多田光＆纱路(CV:内田真礼)'),
      ]);
      await index.reconcileArtists();

      final rows = index.identityArtistGroups();
      expect(rows.map((g) => g.name).toSet(), {'A', 'B', '宇多田光', '纱路'});
      expect(index.artistRowByCanonical('A'), isNotNull);
      expect(index.artistRowByCanonical('B'), isNotNull);
      expect(index.artistRowByCanonical('宇多田光'), isNotNull);
      expect(index.artistRowByCanonical('纱路'), isNotNull);
      expect(index.artistStats()['total'], 4);
      expect(index.artistStats()['mapped'], 4);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('合作串清空歌手后：两身份与映射一并回收', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'A & B')]);
      await index.reconcileArtists();
      expect(index.identityArtistGroups(), hasLength(2));

      await index.updateSongUserMeta('local:test', 'a', artist: '');
      await index.reconcileArtists();

      expect(index.artistRowByCanonical('A'), isNull);
      expect(index.artistRowByCanonical('B'), isNull);
      expect(index.artistStats()['mapped'], 0);
      expect(index.identityArtistGroups(), isEmpty);
    } finally {
      await _dispose(index, dir);
    }
  });

  // ---------- 成员展开与歌手页只显示 Person ----------

  /// 解析服务落库用的关系数据形状（_membersFromRels 的输出）。
  Map<String, dynamic> memberOf(String mbid, String name, String type) =>
      {'mbid': mbid, 'name': name, 'type': type, 'relation': 'member of band'};

  test('成员展开：Group→Character→Person，歌手页只出现 Person', () async {
    final (index, dir) = await _openIndex();
    try {
      // 振り回され隊 名下的歌（音乐标签里写的是组合名）。
      await index.upsertSongs([
        _song('a', '振り回され隊'),
        _song('b', '振り回され隊'),
      ]);
      await index.reconcileArtists();
      final group = index.artistRowByCanonical('振り回され隊')!;
      await index.artistUpsert(
        artistKey: group.artistKey,
        canonicalKey: group.canonicalKey,
        mbid: 'g1',
        displayName: '振り回され隊',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
        matchScore: 100,
      );

      // 一次 artist-rels 建边：成员是 Character（不是 Person）。
      await index.artistSetMembers(artistKey: group.artistKey, members: [
        memberOf('c1', 'チノ', 'character'),
        memberOf('c2', 'リゼ', 'character'),
        memberOf('c3', 'シャロ', 'character'),
      ]);

      // Character 不能直接显示 —— 还得再往下取声优 Person。
      expect(index.identityArtistGroups().map((a) => a.name),
          isNot(contains('チノ')));

      // 第二跳：每个 Character 的 voice actor。
      for (final m in [
        ['c1', 'チノ'],
        ['c2', 'リゼ'],
        ['c3', 'シャロ'],
      ]) {
        final ch = index.artistRowByMbid(m[0])!;
        await index.artistSetMembers(artistKey: ch.artistKey, members: [
          memberOf('p-${m[0]}', m[1] == 'シャロ' ? '内田真礼' : '声優${m[1]}', 'person')
        ]);
      }

      final groups = index.identityArtistGroups();
      final names = groups.map((a) => a.name).toList();
      // 组合和 Character 都不显示，只留 Person。
      expect(names, isNot(contains('振り回され隊')));
      expect(names, isNot(contains('チノ')));
      expect(names, contains('内田真礼'));
      // 社团那两首歌归到 Person 名下（成员继承祖先的歌）。
      final person = groups.firstWhere((a) => a.name == '内田真礼');
      expect(person.songCount, 2);
      expect(index.identitySongs(person.identityKey!), hasLength(2));
      // 歌曲原始组合名不变（播放页/歌曲列表仍显示原名）。
      expect(index.identitySongs(person.identityKey!).first.artist, '振り回され隊');
    } finally {
      await _dispose(index, dir);
    }
  });

  test('成员展开：整条链无 Person 时回落显示组合本身', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'Anonymous Club')]);
      await index.reconcileArtists();
      final group = index.artistRowByCanonical('Anonymous Club')!;
      await index.artistUpsert(
        artistKey: group.artistKey,
        canonicalKey: group.canonicalKey,
        mbid: 'g2',
        displayName: 'Anonymous Club',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );
      // 成员全是 Character，没有声优：无处可落到 Person。
      await index.artistSetMembers(artistKey: group.artistKey, members: [
        memberOf('c9', '謎の役', 'character'),
      ]);

      final groups = index.identityArtistGroups();
      expect(groups.map((a) => a.name), ['Anonymous Club']);
      expect(groups.first.songCount, 1);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('成员展开：无成员关系的 resolved 组合也直接显示自己', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'Solo Artist')]);
      await index.reconcileArtists();
      final row = index.artistRowByCanonical('Solo Artist')!;
      await index.artistUpsert(
        artistKey: row.artistKey,
        canonicalKey: row.canonicalKey,
        mbid: 'p9',
        displayName: 'Solo Artist',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'person',
      );
      // expanded_at 有值但 member_count=0（MB 查过、确实没成员）。
      await index.artistSetMembers(artistKey: row.artistKey, members: []);

      final groups = index.identityArtistGroups();
      expect(groups.single.name, 'Solo Artist');
      expect(index.artistStats()['members'], 0);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('成员展开：重新展开全量替换旧边，悬挂边被 GC', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'Club X')]);
      await index.reconcileArtists();
      final group = index.artistRowByCanonical('Club X')!;
      await index.artistSetMembers(artistKey: group.artistKey, members: [
        memberOf('m1', '旧成员', 'person'),
        memberOf('m2', '保留成员', 'person'),
      ]);
      expect(index.artistStats()['members'], 2);

      // MB 关系变了：旧成员退出。全量替换后只剩一条边。
      await index.artistSetMembers(artistKey: group.artistKey, members: [
        memberOf('m2', '保留成员', 'person'),
      ]);
      expect(index.artistStats()['members'], 1);
      expect(index.artistRowByCanonical('旧成员'), isNull);

      // 成员身份回收后边也不能留下悬挂引用。
      await index.updateSongUserMeta('local:test', 'a', artist: '');
      await index.reconcileArtists();
      expect(index.artistStats()['members'], 0);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('成员身份：同名占位被就地认领，不分裂成两个身份', () async {
    final (index, dir) = await _openIndex();
    try {
      // 「振り回され隊」和「チノ」各自独立出现在歌里
      // → 两个 pending 占位。
      await index.upsertSongs([
        _song('a', '振り回され隊'),
        _song('b', 'チノ'),
      ]);
      await index.reconcileArtists();
      final pendingChino = index.artistRowByCanonical('チノ')!;
      final pendingGroup = index.artistRowByCanonical('振り回され隊')!;
      expect(pendingChino.status, 'pending');
      final total = index.artistStats()['total'];

      // 组合先解析出来，展开成员时成员自带 mbid →
      // 「チノ」占位应被原地升级成 resolved，而不是另起一行
      // （否则同一个人会被算到两个身份名下）。
      await index.artistUpsert(
        artistKey: pendingGroup.artistKey,
        canonicalKey: pendingGroup.canonicalKey,
        mbid: 'g3',
        displayName: '振り回され隊',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );
      await index.artistSetMembers(
          artistKey: pendingGroup.artistKey,
          members: [memberOf('c1', 'チノ', 'character')]);

      expect(index.artistStats()['total'], total);
      final chino = index.artistRowByCanonical('チノ')!;
      expect(chino.artistKey, pendingChino.artistKey);
      expect(chino.isResolved, isTrue);
      expect(chino.mbid, 'c1');
      expect(chino.type, 'character');
    } finally {
      await _dispose(index, dir);
    }
  });

  // 回归：解析服务展开完成员后会补记「已展开过」。这个标记必须是独立写，
  // 不能借用 artistSetMembers(members: [])——那是全量替换，会把刚建的边删光，
  // 结果 expanded_at 写上了、成员却一条不剩，歌手页回落显示组合本身。
  test('成员展开：标记已展开后成员边仍在（不得被清空）', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', '振り回され隊')]);
      await index.reconcileArtists();
      final group = index.artistRowByCanonical('振り回され隊')!;
      await index.artistUpsert(
        artistKey: group.artistKey,
        canonicalKey: group.canonicalKey,
        mbid: 'g4',
        displayName: '振り回され隊',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );
      await index.artistSetMembers(artistKey: group.artistKey, members: [
        memberOf('p1', '水瀬いのり', 'person'),
        memberOf('p2', '佐倉綾音', 'person'),
      ]);

      await index.artistMarkExpanded(group.artistKey);

      expect(index.artistStats()['members'], greaterThan(0));
      expect(index.artistStats()['expanded'], 1);
      expect(index.artistStats()['fallback'], 0);
      final shown = index.identityArtistGroups().map((a) => a.name).toSet();
      expect(shown, {'水瀬いのり', '佐倉綾音'});
      // 成员自己没有 role='main' 映射，歌曲要能反向继承到成员名下。
      expect(
          index.identitySongs(index.artistRowByCanonical('水瀬いのり')!.artistKey),
          hasLength(1));
    } finally {
      await _dispose(index, dir);
    }
  });

  // 回归：某一轮解析失败只能「记待重试」。旧实现走 artistUpsert 全字段覆盖，
  // 传空的 names/groups 和空 mbid 会把已经合流好的身份整个抹掉——
  // 一次网络抖动就丢了别名表，成员元数据也归零。
  test('记失败待重试：不清掉已合流的 mbid/names/type', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', '振り回され隊')]);
      await index.reconcileArtists();
      final group = index.artistRowByCanonical('振り回され隊')!;
      await index.artistUpsert(
        artistKey: group.artistKey,
        canonicalKey: group.canonicalKey,
        mbid: 'g5',
        displayName: '振り回され隊',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
        matchScore: 100,
        names: [
          {'name': '振り回され隊', 'name_type': 'primary', 'is_primary': 1}
        ],
        groups: [
          {'name': 'チノ', 'mbid': 'c1', 'type': 'member of band'}
        ],
      );

      await index.artistMarkError(
          artistKey: group.artistKey, errorCount: 1, nextAt: 123456);

      final row = index.artistRowByKey(group.artistKey)!;
      expect(row.status, 'local');
      expect(row.errorCount, 1);
      expect(row.nextAt, 123456);
      expect(row.mbid, 'g5');
      expect(row.type, 'group');
      expect(row.matchScore, 100);
      expect(row.names, isNotEmpty);
      expect(row.groups, isNotEmpty);
      // 状态退回 local → 重新进入工作集，会被自动重试捞起来。
      expect(
          index.artistWorkSet().map((w) => w.canonicalKey), contains('振り回され隊'));
    } finally {
      await _dispose(index, dir);
    }
  });

  test('强制解析：resolved 被打回 pending 且清 expanded_at，成员边先留着', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', '振り回され隊')]);
      await index.reconcileArtists();
      final group = index.artistRowByCanonical('振り回され隊')!;
      await index.artistUpsert(
        artistKey: group.artistKey,
        canonicalKey: group.canonicalKey,
        mbid: 'g6',
        displayName: '振り回され隊',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );
      await index.artistSetMembers(artistKey: group.artistKey, members: [
        memberOf('p1', '水瀬いのり', 'person'),
      ]);
      expect(index.artistStats()['members'], 1);

      await index.artistForceRetry(all: true);

      final row = index.artistRowByKey(group.artistKey)!;
      expect(row.status, 'pending');
      expect(row.errorCount, 0);
      // mbid 必须还在：解析服务靠它按原实体重取，不重新搜索。
      expect(row.mbid, 'g6');
      // expanded_at 清了 → 会重新展开；边先留着，展开成功后由全量替换覆盖。
      expect(index.artistStats()['expanded'], 0);
      expect(index.artistStats()['members'], 1);
      expect(
          index.artistWorkSet().map((w) => w.canonicalKey), contains('振り回され隊'));
    } finally {
      await _dispose(index, dir);
    }
  });

  test('强制解析：只影响指定身份', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'A'), _song('b', 'B')]);
      await index.reconcileArtists();
      for (final (key, canon) in [('A', 'A'), ('B', 'B')]) {
        final row = index.artistRowByCanonical(canon)!;
        await index.artistUpsert(
          artistKey: row.artistKey,
          canonicalKey: row.canonicalKey,
          mbid: key,
          displayName: canon,
          status: 'resolved',
          errorCount: 0,
          nextAt: 0,
          type: 'person',
        );
      }
      final a = index.artistRowByCanonical('A')!;

      await index.artistForceRetry(artistKey: a.artistKey);

      expect(index.artistRowByCanonical('A')!.status, 'pending');
      expect(index.artistRowByCanonical('B')!.status, 'resolved');
    } finally {
      await _dispose(index, dir);
    }
  });

  // 回归：重新解析一个「已经有 mbid」的身份时，合流的目标就是它自己。
  // 旧实现无条件 DELETE FROM artists WHERE artist_key=fromAk —— 等于把刚刷新的
  // 身份连同它的歌曲映射一起删掉，歌手直接从库里消失。
  test('合流到自身：身份和歌曲映射都不该被删', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', '振り回され隊')]);
      await index.reconcileArtists();
      final group = index.artistRowByCanonical('振り回され隊')!;
      await index.artistUpsert(
        artistKey: group.artistKey,
        canonicalKey: group.canonicalKey,
        mbid: 'g7',
        displayName: '振り回され隊',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
        matchScore: 100,
      );

      // 模拟重新解析：同一个 mbid 合流回同一行，且这次没拿到分数。
      final merged = await index.artistMergeMbid(
        canonicalKey: group.canonicalKey,
        fromArtistKey: group.artistKey,
        mbid: 'g7',
        displayName: '振り回され隊',
        type: 'group',
        matchScore: null,
      );

      expect(merged, isTrue);
      final row = index.artistRowByKey(group.artistKey);
      expect(row, isNotNull, reason: '身份不能被合流成自删');
      expect(row!.mbid, 'g7');
      expect(row.status, 'resolved');
      // 这次没分数，原分数不能被抹掉。
      expect(row.matchScore, 100);
      // 歌还挂在这个身份下。
      expect(
          index.identityArtistGroups().map((a) => a.name), contains('振り回され隊'));
    } finally {
      await _dispose(index, dir);
    }
  });
  // ---------- 歌手页曲目数：跨组合不许漏算 ----------

  test('歌手页曲目数：同一成员挂在多个组合下要合并计数', () async {
    final (index, dir) = await _openIndex();
    try {
      // 两个组合各一首不同专辑的歌，同一个成员（同一 mbid）在两边都有位置。
      await index.upsertSongs([
        _song('a', '组合A', album: '专辑A'),
        _song('b', '组合B', album: '专辑B'),
      ]);
      await index.reconcileArtists();
      final ga = index.artistRowByCanonical('组合A')!;
      final gb = index.artistRowByCanonical('组合B')!;
      await index.artistUpsert(
        artistKey: ga.artistKey,
        canonicalKey: ga.canonicalKey,
        mbid: 'mb-ga',
        displayName: '组合A',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );
      await index.artistUpsert(
        artistKey: gb.artistKey,
        canonicalKey: gb.canonicalKey,
        mbid: 'mb-gb',
        displayName: '组合B',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );
      await index.artistSetMembers(artistKey: ga.artistKey, members: [
        {
          'mbid': 'p-shared',
          'name': '共用成员',
          'type': 'person',
          'relation': 'member of band',
        },
      ]);
      await index.artistSetMembers(artistKey: gb.artistKey, members: [
        {
          'mbid': 'p-shared',
          'name': '共用成员',
          'type': 'person',
          'relation': 'member of band',
        },
      ]);

      final rows = index.identityArtistGroups();
      final shared = rows.firstWhere((a) => a.name == '共用成员');
      // 之前按显示身份去重，只剩第一个 owner 的歌：这里会少算成 1 首。
      expect(shared.songCount, 2);
      expect(shared.albumCount, 2);
      // 详情里的展示曲目数要走同一条口径。
      expect(index.identityDisplayCounts()[shared.identityKey!], 2);
      expect(index.identitySongs(shared.identityKey!).length, 2);
    } finally {
      await _dispose(index, dir);
    }
  });

  // ---------- 歌手详情页（组合 / 角色 / 成员） ----------

  /// 造一棵 Group→Character→Person 的本地成员树：组合 [bandCanonical] 名下每个角色
  /// 一个声优（[roles] 是 [角色名, 声优] 列表），[extraPerson] 是直接挂在组合下的
  /// 真人。组合行复用 canonical 占位行（reconcile 建的），别新造 key —— 没有歌映射
  /// 的孤立身份会被 GC 回收，成员边一起没了。
  Future<void> seedBand(
    LocalIndex index, {
    required String bandCanonical,
    required List<List<String>> roles,
    String? extraPerson,
  }) async {
    final key = index.artistRowByCanonical(bandCanonical)?.artistKey ??
        'k-$bandCanonical';
    await index.artistUpsert(
      artistKey: key,
      canonicalKey: bandCanonical,
      mbid: 'mb-$bandCanonical',
      displayName: bandCanonical,
      status: 'resolved',
      errorCount: 0,
      nextAt: 0,
      type: 'group',
    );
    await index.artistSetMembers(artistKey: key, members: [
      for (final r in roles)
        {
          'mbid': 'mb-role-${r[0]}',
          'name': r[0],
          'type': 'character',
          'relation': 'member of band',
        },
      if (extraPerson != null)
        {
          'mbid': 'mb-other-$extraPerson',
          'name': extraPerson,
          'type': 'person',
          'relation': 'member of band',
        },
    ]);
    for (final r in roles) {
      final chara = index.artistRowByMbid('mb-role-${r[0]}')!;
      await index.artistSetMembers(artistKey: chara.artistKey, members: [
        {
          'mbid': 'mb-va-${r[1]}',
          'name': r[1],
          'type': 'person',
          'relation': 'voice actor',
        },
      ]);
      // 声优本人身上的 MB 原始关系（配过哪些角色）——「角色」栏就靠它。
      final va = index.artistRowByMbid('mb-va-${r[1]}')!;
      await index.artistUpsert(
        artistKey: va.artistKey,
        canonicalKey: va.canonicalKey,
        mbid: va.mbid,
        displayName: va.displayName,
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'person',
        groups: [
          {
            'name': r[0],
            'mbid': 'mb-role-${r[0]}',
            'type': 'voice actor',
            'target_type': 'Character',
          },
        ],
      );
    }
  }

  test('歌手详情：人物身份给出组合/角色/成员三栏', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'Band X', album: '专辑X')]);
      await index.reconcileArtists();
      await seedBand(index, bandCanonical: 'Band X', roles: [
        ['Riko', '内田真礼'],
        ['Saki', '佐藤聡美'],
      ], extraPerson: '斉藤朱夏');

      final va = index.artistRowByMbid('mb-va-内田真礼')!;
      final detail = index.artistDetail(va.artistKey);
      expect(detail, isNotNull);

      // 组合：本地成员树里的祖先组合（经过角色这一跳）。
      expect(detail!.bands.map((b) => b.name), ['Band X']);
      // 歌挂在组合名下，所以这个成员名下展示的曲目数是组合那 1 首。
      expect(detail.bands.single.songCount, 1);

      // 角色：MB 原始关系里「这个声优配过谁」。
      expect(detail.roles.map((r) => r.name), contains('Riko'));
      expect(detail.roles.first.artistKey, isNotNull);

      // 成员：同组合的其他人（另一个声优 + 直接挂组合的真人），排除自己。
      expect(detail.members.map((m) => m.name),
          containsAll(['佐藤聡美', '斉藤朱夏']));
      expect(detail.members.map((m) => m.name), isNot(contains('内田真礼')));
      expect(detail.members, hasLength(2));
    } finally {
      await _dispose(index, dir);
    }
  });

  test('歌手详情：组合/角色/未解析身份都不返回详情', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'Band Y')]);
      await index.reconcileArtists();
      await seedBand(index, bandCanonical: 'Band Y', roles: [
        ['Mio', '水瀬いのり'],
      ]);
      expect(index.artistDetail('k-Band Y'), isNull);
      final chara = index.artistRowByMbid('mb-role-Mio')!;
      expect(index.artistDetail(chara.artistKey), isNull);
      // 没解析成功的身份也没有详情。
      expect(index.artistDetail('k-不存在'), isNull);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('歌手详情：组合栏并入 MB 原始关系里本地没展开的关联', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([
        _song('a', 'Solo'),
        _song('b', 'Band Z', album: '专辑Z'),
      ]);
      await index.reconcileArtists();
      await seedBand(index, bandCanonical: 'Band Z', roles: [
        ['Rin', '徳井青空'],
      ]);

      // Solo 的 MB 原始关系：2 个组合（只有 Band Z 本地有身份行）、1 个角色，
      // 外加一条 married（不属于任何一栏，不该混进来）。
      final row = index.artistRowByCanonical('Solo')!;
      await index.artistUpsert(
        artistKey: row.artistKey,
        canonicalKey: row.canonicalKey,
        mbid: 'mb-solo',
        displayName: 'Solo',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'person',
        groups: [
          {
            'name': 'Band Z',
            'mbid': 'mb-Band Z',
            'type': 'member of band',
            'target_type': 'Group',
          },
          {
            'name': 'Untouched Band',
            'mbid': 'mb-untouched',
            'type': 'member of band',
            'target_type': 'Group',
          },
          {
            'name': 'Solo Role',
            'mbid': 'mb-solorole',
            'type': 'voice actor',
            'target_type': 'Character',
            'disambiguation': '有效期限和组织',
          },
          {
            'name': 'Spouse',
            'mbid': 'mb-spouse',
            'type': 'married',
            'target_type': 'Person',
          },
        ],
      );

      final detail = index.artistDetail(row.artistKey)!;
      expect(detail.bands.map((b) => b.name),
          containsAll(['Band Z', 'Untouched Band']));
      expect(detail.bands.map((b) => b.name), isNot(contains('Spouse')));
      // 本地建过身份的排前面，且能带上曲目数。
      expect(detail.bands.first.name, 'Band Z');
      expect(detail.bands.first.songCount, 1);
      final untouched =
          detail.bands.firstWhere((b) => b.name == 'Untouched Band');
      expect(untouched.artistKey, isNull, reason: '没展开过，不能跳进去');
      expect(untouched.songCount, isNull);
      // 角色栏带上 MB 的 disambiguation（区分同名不同作品的角色）。
      expect(detail.roles.single.name, 'Solo Role');
      expect(detail.roles.single.disambiguation, '有效期限和组织');
      // Band Z 的声优也算 Solo 的同组合成员。
      expect(detail.members.map((m) => m.name), ['徳井青空']);
    } finally {
      await _dispose(index, dir);
    }
  });

  test('歌手详情：组合栏递归到根（子组合的上级也在）', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([
        _song('a', 'Big Band'),
        _song('b', 'Sub Band', album: '专辑Sub'),
      ]);
      await index.reconcileArtists();
      await seedBand(index, bandCanonical: 'Sub Band', roles: [
        ['Nana', '田中真奈美'],
      ]);
      // Big Band → Sub Band 是 subgroup 边（子团体算组合的成员）。
      final big = index.artistRowByCanonical('Big Band')!;
      await index.artistUpsert(
        artistKey: big.artistKey,
        canonicalKey: big.canonicalKey,
        mbid: 'mb-Big Band',
        displayName: 'Big Band',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );
      await index.artistSetMembers(artistKey: big.artistKey, members: [
        {
          'mbid': 'mb-Sub Band',
          'name': 'Sub Band',
          'type': 'group',
          'relation': 'subgroup',
        },
      ]);

      final va = index.artistRowByMbid('mb-va-田中真奈美')!;
      final detail = index.artistDetail(va.artistKey)!;
      expect(detail.bands.map((b) => b.name),
          containsAll(['Sub Band', 'Big Band']));
      expect(detail.bands.firstWhere((b) => b.name == 'Big Band').relations,
          contains('上级组合'));
    } finally {
      await _dispose(index, dir);
    }
  });

  // ---------- 重新解析的 MB 请求数 ----------

  test('重解析已知 MBID：一次请求就拿全实体+关系', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'Band Q')]);
      await index.reconcileArtists();
      final band = index.artistRowByCanonical('Band Q')!;
      await index.artistUpsert(
        artistKey: band.artistKey,
        canonicalKey: band.canonicalKey,
        mbid: 'mb-BandQ',
        displayName: 'Band Q',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
        matchScore: 100,
      );

      // 同一个 MBID 以前要打两次：先 lookup 拿实体，再单独拉 artist-rels。
      final adapter = _RecordingAdapter({
        'id': 'mb-BandQ',
        'name': 'Band Q',
        'type': 'Group',
        'relations': [
          {
            'type': 'member of band',
            'direction': 'backward',
            'artist': {'name': '成员A', 'type': 'Person', 'id': 'mb-A'},
          },
        ],
      });
      final resolver = ArtistResolver(index, dio: _dioOf(adapter));
      try {
        await resolver.forceRetryOne(artistKey: band.artistKey);
      } finally {
        resolver.dispose();
      }

      expect(adapter.calls.map((u) => u.path), ['/ws/2/artist/mb-BandQ']);
      // 关系也一并处理掉了（没为它再发第二次请求）：成员身份建好、边写上。
      expect(index.artistRowByMbid('mb-A')?.displayName, '成员A');
      // 边写上了：歌手页因此能显示这个 Person（它自己没有歌，靠组合继承）。
      expect(index.identityArtistGroups().map((a) => a.name), contains('成员A'));
      expect(index.artistRowByKey(band.artistKey)!.matchScore, 100,
          reason: '重解析不能把已记录的分数抹掉');
    } finally {
      await _dispose(index, dir);
    }
  });

  test('重解析：MB 实体 404 时退回搜索并重绑', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([_song('a', 'Band R')]);
      await index.reconcileArtists();
      final band = index.artistRowByCanonical('Band R')!;
      await index.artistUpsert(
        artistKey: band.artistKey,
        canonicalKey: band.canonicalKey,
        mbid: 'mb-gone',
        displayName: 'Band R',
        status: 'resolved',
        errorCount: 0,
        nextAt: 0,
        type: 'group',
      );

      final adapter = _RecordingAdapter(
        {
          'artists': [
            {'id': 'mb-new', 'name': 'Band R', 'type': 'Group', 'score': 100},
          ],
        },
        // 旧 MBID 已合并/删除：404 → 退回搜索。
        failOn: (u) => u.path.endsWith('/artist/mb-gone') ? 404 : null,
        entity: {
          'id': 'mb-new',
          'name': 'Band R',
          'type': 'Group',
          'relations': <Object>[],
        },
      );
      final resolver = ArtistResolver(index, dio: _dioOf(adapter));
      try {
        await resolver.forceRetryOne(artistKey: band.artistKey);
      } finally {
        resolver.dispose();
      }

      // 先打旧 MBID（404），再搜索，最后取新实体 —— 顺序固定。
      expect(adapter.calls.map((u) => u.path), [
        '/ws/2/artist/mb-gone',
        '/ws/2/artist/',
        '/ws/2/artist/mb-new',
      ]);
      final row = index.artistRowByKey(band.artistKey)!;
      expect(row.mbid, 'mb-new', reason: '实体没了就重绑到搜到的那个');
      expect(row.status, 'resolved');
      expect(row.matchScore, 100, reason: '搜索分要落到 match_score');
    } finally {
      await _dispose(index, dir);
    }
  });
}
