import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/artist_names.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/models/artist.dart';
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

DirectSongRow _song(String ref, String artist) => DirectSongRow(
      sourceKey: 'local:test',
      ref: ref,
      title: '标题 $ref',
      artist: artist,
      album: '专辑',
      duration: 100,
      format: 'mp3',
      size: 1024,
      mtime: 1,
    );

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
    expect(artistCollabCanonicals('周杰伦 & 费玉清'),
        [('周杰伦', '周杰伦'), ('费玉清', '费玉清')]);
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
    expect(mk('pending', canonical: null).resolveState, ArtistResolveState.normal);
    expect(mk('local', canonical: null).resolveState, ArtistResolveState.normal);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      expect(index.artistWorkSet(limit: 10).where((w) => w.nextAt == 0),
          isEmpty);

      await index.artistRetry();
      final back = index.artistRowByCanonical('某独立音乐人')!;
      expect(back.status, 'pending');
      expect(back.errorCount, 0);
      expect(back.nextAt, 0);
      expect(index.artistWorkSet(limit: 10), hasLength(1));
    } finally {
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
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
      index.close();
      dir.deleteSync(recursive: true);
    }
  });
}