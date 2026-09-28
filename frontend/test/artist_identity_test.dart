import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/artist_names.dart';
import 'package:selfmusic/data/local/local_index.dart';
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
  // ---------- 歌手处理.txt：名称归一化 / 括号人直解（纯 Dart） ----------

  test('NFKC 归一化：全角括号/冒号/CV 折半角（（ＣＶ：→(CV:）', () {
    expect(normalizeArtistName('  纱路（ＣＶ：内田真礼）  '),
        '纱路(CV:内田真礼)');
    expect(normalizeArtistName('ＡＢＢＡ'), 'ABBA');
  });

  test('聚合键：不做归一化，原样返回（不同写法各自成身份）', () {
    expect(artistCanonicalKey('ABBA'), 'ABBA');
    expect(artistCanonicalKey('abba'), 'abba');
    expect(artistCanonicalKey('Petit Rabbit\u2019s'), 'Petit Rabbit\u2019s');
    expect(artistCanonicalKey('  ABBA  '), '  ABBA  ');
  });

  test('括号人直解：CV 全角/半角都解出人物名，feat./作品名括号不误判', () {
    final full = splitArtistPart('纱路（ＣＶ：内田真礼）');
    expect(full.hasCv, isTrue);
    expect(full.base, '纱路');
    expect(full.cvName, '内田真礼');

    final ascii = splitArtistPart('紗路(CV:内田真礼)');
    expect(ascii.hasCv, isTrue);
    expect(ascii.base, '紗路');
    expect(ascii.cvName, '内田真礼');

    // 双括号取最后一个 CV；非 CV 括号（NFKC 已折半角）原样保留。
    final multi = splitArtistPart('纱路（Vol.2）(CV:内田真礼)');
    expect(multi.hasCv, isTrue);
    expect(multi.base, '纱路(Vol.2)');
    expect(multi.cvName, '内田真礼');

    expect(splitArtistPart('夏祭 feat. 初音ミク').cvName, isNull);
    expect(splitArtistPart('群青(anime size)').cvName, isNull);
    expect(splitArtistPart('Bocchi the Rock!').cvName, isNull);
  });

  test('无显式 CV 时整串为基名；纯人物（无基名）归一整串', () {
    expect(splitArtistPart('内田真礼').base, '内田真礼');
    final cvOnly = splitArtistPart('(CV:内田真礼)');
    expect(cvOnly.hasCv, isTrue);
    expect(cvOnly.base, '(CV:内田真礼)');
    expect(cvOnly.cvName, '内田真礼');
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
      expect(index.identitySongs(groups.first.identityKey!), hasLength(2));
      expect(index.identityFallbackGroups(), isEmpty);
    } finally {
      index.close();
      dir.deleteSync(recursive: true);
    }
  });

  test('reconcile：CV 写法 canonical 独立于纯人物名，合并走 mbid', () async {
    final (index, dir) = await _openIndex();
    try {
      await index.upsertSongs([
        _song('c', '纱路（CV:内田真礼）'),
        _song('d', '内田真礼'),
      ]);
      await index.reconcileArtists();

      final cvRow = index.artistRowByCanonical(
          artistCanonicalKey('纱路|内田真礼'));
      final personRow = index.artistRowByCanonical('内田真礼');
      expect(cvRow, isNotNull);
      expect(personRow, isNotNull);
      expect(cvRow!.artistKey, isNot(personRow!.artistKey));

      // 纯人物名率先解析。CV 行随后解析到同一 mbid → 合流。
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
        canonicalKey: '纱路|内田真礼',
        fromArtistKey: cvRow.artistKey,
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

      // CV 占位已被删除，桥改指向真人行；两首歌都挂在真人身份下。
      final stats = index.artistStats();
      expect(stats['total'], 1);
      expect(stats['resolved'], 1);
      expect(stats['mapped'], 2);
      final target = index.artistRowByCanonical('内田真礼');
      expect(target, isNotNull);
      // CV canonical 仍能经桥解析到真人行（防后 reconcile 重建占位）。
      expect(index.artistRowByCanonical('纱路|内田真礼')!.artistKey,
          target!.artistKey);
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
}