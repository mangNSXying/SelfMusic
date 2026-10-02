import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/artist_resolver.dart';

/// 端到端：真实 FLAC 标签 + 真实 MusicBrainz，走解析服务实际会走的那条链
/// （脏数据过滤 → 取首个候选 → 按关系建成员边 → 歌手页只显示 Person）。
///
/// 这个文件默认跳过（需联网 + 仓库里的 temp 音乐），用
/// `flutter test --dart-define=MB_LIVE=1 test/artist_end_to_end_test.dart` 打开。
class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

const _flac =
    r"E:\.Project\selfmusic\temp\01.Daydream café - Petit Rabbit's.flac";

void main() {
  const live = bool.fromEnvironment('MB_LIVE');
  final flac = File(_flac);
  const String? reason = live ? null : '未开启 MB_LIVE';
  test('Petit Rabbit\'s：真实标签 → MB 弯撇号命中 → 组合名不入歌手页', () async {
    // 1) 真实标签。
    final bytes = await flac.readAsBytes();
    final meta = await readAudioMeta(
      readRange: (start, end) async =>
          bytes.sublist(start, end.clamp(0, bytes.length).toInt()),
      format: 'flac',
      fileSize: bytes.length,
    );
    expect(meta, isNotNull);
    // 文件里是 ASCII 撇号，MB 那边是 U+2019 —— 这正是之前解析不上的原因。
    expect(meta!.artist, "Petit Rabbit's");
    expect(meta.artist!.contains('\u2019'), isFalse);

    // 2) 真实 MB 搜索。
    final dio = Dio(BaseOptions(baseUrl: ArtistResolver.kDefaultBase, headers: {
      'User-Agent': 'SelfMusic/1.0.1 (e2e probe)',
      'Accept': 'application/json'
    }));
    final resp = await dio.get('/artist/', queryParameters: {
      'query': 'artist:"Petit Rabbit\'s" OR alias:"Petit Rabbit\'s"',
      'limit': '10',
      'fmt': 'json',
      'dismax': 'true',
    });
    final hits = <MbArtistHit>[
      for (final a in ((resp.data as Map)['artists'] as List)
          .cast<Map<String, dynamic>>())
        MbArtistHit(
          mbid: a['id'] as String,
          name: a['name'] as String,
          type: a['type'] as String?,
          score: (a['score'] as num).toDouble(),
        ),
    ];
    // 首个候选就是弯撇号写法，且不是脏数据条目。
    expect(hits.first.name, 'Petit Rabbit\u2019s');
    expect(hits.any((h) => h.name == '[no artist]'), isTrue,
        reason: 'MB 确实会返回占位条目，靠脏数据过滤挡掉');

    // 3) 落库 + 展开，看歌手页最终显示谁。
    final dir = await Directory.systemTemp.createTemp('selfmusic_e2e_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    addTearDown(() async {
      index.close();
      for (var i = 0; i < 20; i++) {
        try {
          if (!dir.existsSync()) break;
          dir.deleteSync(recursive: true);
          break;
        } on FileSystemException {
          await Future<void>.delayed(Duration(milliseconds: 50 * (i + 1)));
        }
      }
    });

    await index.upsertSongs([
      DirectSongRow(
        sourceKey: 'local:temp',
        ref: meta.title ?? 'a',
        title: meta.title ?? 'unknown',
        artist: meta.artist ?? "Petit Rabbit's",
        album: meta.album,
        duration: meta.duration ?? 100,
        format: 'flac',
        size: bytes.length,
        mtime: 1,
      )
    ]);
    await index.reconcileArtists();

    final row = index.artistRowByCanonical("Petit Rabbit's")!;
    await index.artistUpsert(
      artistKey: row.artistKey,
      canonicalKey: row.canonicalKey,
      mbid: hits.first.mbid,
      displayName: hits.first.name,
      status: 'resolved',
      errorCount: 0,
      nextAt: 0,
      type: 'group',
      matchScore: hits.first.score,
    );

    // 用真实的 artist-rels 结构展开成员（这里直接取 MB 原样响应）。
    final rel = await dio.get('/artist/${hits.first.mbid}',
        queryParameters: {'inc': 'artist-rels+aliases', 'fmt': 'json'});
    final rels =
        ((rel.data as Map)['relations'] as List).cast<Map<String, dynamic>>();
    final members = ArtistResolver.parseMemberRelations(rels, 'group');
    await index.artistSetMembers(artistKey: row.artistKey, members: members);

    final shown = index.identityArtistGroups();
    print(
        'MB 顶层命中: ${hits.take(3).map((h) => '${h.name}(${h.type},${h.score})').join(', ')}');
    print(
        '解析出的成员: ${members.map((m) => '${m['name']}(${m['type']})').join(', ')}');
    print('歌手页显示: ${shown.map((a) => '${a.name}[${a.songCount}]').join(', ')}');

    // row 是 upsert 前的快照，重新读一次拿落库后的值。
    final after = index.artistRowByCanonical("Petit Rabbit's")!;
    expect(after.isResolved, isTrue);
    expect(after.mbid, hits.first.mbid);
    expect(after.matchScore, hits.first.score);
    // 组合名本身不进歌手页（显示的是 Person）；歌曲仍记在组合名下。
    expect(shown.map((a) => a.name), isNot(contains('Petit Rabbit')));
    expect(shown, isNotEmpty);
    for (final a in shown) {
      expect(a.songCount, 1, reason: '成员继承社团名下那首歌');
      expect(index.identitySongs(a.identityKey!).map((s) => s.artist).toSet(),
          {'Petit Rabbit\'s'},
          reason: '歌曲原始组合名不变（播放页/列表仍显示原名）');
    }
  }, skip: reason ?? (flac.existsSync() ? false : '找不到 $_flac'));
}
