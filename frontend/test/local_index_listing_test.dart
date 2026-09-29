import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/schema.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/models/song.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

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

void main() {
  test('源列表不再截断：size 缺省返回全部歌曲（回归 200 上限）', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxlim_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    final rows = <DirectSongRow>[
      for (var i = 0; i < 250; i++)
        DirectSongRow(
          sourceKey: 'local:test',
          ref: 'song_$i',
          title: '歌曲 $i',
          artist: '歌手 ${i % 5}',
          album: '专辑',
          duration: 100,
          format: 'mp3',
          size: 1024,
          mtime: i,
        ),
    ];
    await index.upsertSongs(rows);

    // 全部返回（不限 200）
    expect(index.searchSongs(sourceKey: 'local:test').length, 250);
    expect(index.countSongs('local:test'), 250);

    // 分页仍可用
    expect(index.searchSongs(sourceKey: 'local:test', size: 100).length, 100);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('旧 ENCODE 收藏行被新解码 ref 继承并合并（取消喜欢不残留）', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxfav_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);

    const decodedRef = '/dav/佐藤しずく - Growing!.flac';
    const encodedRef =
        '/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing%21.flac';
    // 模拟历史库：迁移在 LocalIndex.open() 时由写隔离一次性完成（读路径纯读），
    // 故旧行必须在 open 之前就存在于库里。
    Directory(p.join(dir.path, 'selfmusic')).createSync(recursive: true);
    final legacy = sqlite3.open(p.join(dir.path, 'selfmusic', 'selfmusic.db'));
    applySchema(legacy);
    legacy.execute(
        'INSERT INTO play_meta(source_key, song_ref, is_favorite) VALUES(?,?,1)',
        ['webdav:nas', encodedRef]);
    legacy.dispose();

    final index = LocalIndex();
    await index.open();
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: 'webdav:nas',
        ref: decodedRef,
        title: 'Growing!',
        artist: '佐藤しずく',
        album: '',
        duration: 200,
        format: 'flac',
        size: 1024,
        mtime: 1,
      ),
    ]);

    // 读侧：open() 的启动迁移已把旧行并到新 ref。
    expect(index.playMetaOf('webdav:nas', decodedRef).favorite, isTrue);
    // 喜欢列表：经回查补全出歌曲。
    final liked = index.likedSongs();
    expect(liked.length, 1);
    expect(liked.first.title, 'Growing!');

    // 写侧：取消喜欢后旧行被合并，不再残留。
    await index.setFavorite('webdav:nas', decodedRef, false);
    expect(index.likedSongs(), isEmpty);
    expect(index.playMetaOf('webdav:nas', decodedRef).favorite, isFalse);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('不喜欢锁定最低权重：可取消、跳过自动调权、喜欢可解冻', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxdis_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();
    final weight = SongWeightStore(index);
    final song = Song.direct(
      id: 1,
      sourceKey: 'webdav:nas',
      title: 'Growing!',
      source: 'webdav',
      sourceRef: '/dav/a.flac',
      fileSize: 1024,
    );

    // 标记不喜欢 → 权重最低并锁定。
    await weight.setDisliked(song, true);
    expect(weight.isDisliked(song), isTrue);
    expect(weight.factorOf(song), SongWeightStore.minFactor);
    // 锁定后跳过/播完只记 streak，不调权重。
    await weight.onSkipped(song);
    await weight.onSkipped(song);
    await weight.onSkipped(song);
    expect(weight.factorOf(song), SongWeightStore.minFactor);
    expect(weight.isDisliked(song), isTrue);

    // 再次点击取消 → 解锁回 1.0。
    await weight.setDisliked(song, false);
    expect(weight.isDisliked(song), isFalse);
    expect(weight.factorOf(song), SongWeightStore.defaultFactor);

    // 喜欢可解冻：先锁再喜欢 → 解锁且 factor 拉满。
    await weight.setDisliked(song, true);
    await weight.setLiked(song);
    expect(weight.isDisliked(song), isFalse);
    expect(weight.factorOf(song), SongWeightStore.maxFactor);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('用户改元数据后扫描不再覆盖标题/歌手/专辑', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxmeta_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    DirectSongRow row(String title, String? artist, String? album) =>
        DirectSongRow(
          sourceKey: 'webdav:nas',
          ref: '/dav/a.flac',
          title: title,
          artist: artist,
          album: album,
          duration: 200,
          format: 'flac',
          size: 1024,
          mtime: 1,
        );
    await index.upsertSongs([row('扫描标题', '扫描歌手', '扫描专辑')]);
    await index.updateSongUserMeta('webdav:nas', '/dav/a.flac',
        title: '我的标题', artist: '我的歌手');

    var got = index.songByRef('webdav:nas', '/dav/a.flac')!;
    expect(got.title, '我的标题');
    expect(got.artist, '我的歌手');
    expect(got.albumName, '扫描专辑');

    // 再次扫描：标题/歌手/专辑保留用户版，其余字段照常更新。
    await index.upsertSongs([row('新扫描标题', '新扫描歌手', '新扫描专辑')]);
    got = index.songByRef('webdav:nas', '/dav/a.flac')!;
    expect(got.title, '我的标题');
    expect(got.artist, '我的歌手');
    expect(got.albumName, '扫描专辑');

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('元数据已读标记：极简扫描未读、补读后已读、完整扫描直接已读', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxread_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    DirectSongRow row(String ref, int? duration) => DirectSongRow(
          sourceKey: 'webdav:nas',
          ref: ref,
          title: ref,
          duration: duration,
          format: 'mp3',
          size: 1024,
          mtime: 1,
        );
    // 极简扫描（无时长）→ 未读；完整扫描（有时长）→ 已读。
    await index.upsertSongs([row('/dav/min.mp3', null), row('/dav/full.mp3', 200)]);
    var unread = index.unreadSongs('webdav:nas', 100);
    expect(unread.map((s) => s.sourceRef), ['/dav/min.mp3']);

    // metaRead 随 `meta_read` 列落 Song：未读歌 artist 为空 → 标注「待读取」；
    // 已读歌 artist 为空 → 留白（null）。
    final unreadSong = index.songByRef('webdav:nas', '/dav/min.mp3')!;
    expect(unreadSong.metaRead, isFalse);
    expect(unreadSong.metaDisplay(unreadSong.artist), Song.unreadLabel);
    final readSong = index.songByRef('webdav:nas', '/dav/full.mp3')!;
    expect(readSong.metaRead, isTrue);
    expect(readSong.metaDisplay(readSong.artist), isNull);
    // 有值时不论读未读都显示原值。
    expect(unreadSong.metaDisplay('已有歌手'), '已有歌手');

    // 补读后不再未读。
    await index.enrichSong('webdav:nas', '/dav/min.mp3', duration: 180);
    unread = index.unreadSongs('webdav:nas', 100);
    expect(unread, isEmpty);
    expect(index.songByRef('webdav:nas', '/dav/min.mp3')!.metaRead, isTrue);

    // 排除正在播放的歌（后台补读跳过它，播放链路自己会重读）。
    await index.upsertSongs([row('/dav/skip.mp3', null), row('/dav/other.mp3', null)]);
    unread = index.unreadSongs('webdav:nas', 100, excludeRef: '/dav/skip.mp3');
    expect(unread.map((s) => s.sourceRef), ['/dav/other.mp3']);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('补读回写标题/歌手/专辑/专辑歌手；用户手改行不回写文本字段', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxenrich_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    DirectSongRow row(String ref) => DirectSongRow(
          sourceKey: 'webdav:nas',
          ref: ref,
          title: ref,
          format: 'mp3',
          size: 1024,
          mtime: 1,
        );
    await index.upsertSongs([row('/dav/a.mp3'), row('/dav/b.mp3')]);

    // 补读把标签写回（fast 扫描只有文件名也能补全）。
    await index.enrichSong('webdav:nas', '/dav/a.mp3',
        title: '补读标题',
        artist: '补读歌手',
        album: '补读专辑',
        albumArtist: '补读专辑歌手',
        duration: 180,
        coverPath: '/tmp/c.jpg');
    var got = index.songByRef('webdav:nas', '/dav/a.mp3')!;
    expect(got.title, '补读标题');
    expect(got.artist, '补读歌手');
    expect(got.albumName, '补读专辑');
    expect(got.albumArtist, '补读专辑歌手');
    expect(got.duration, 180);
    expect(got.coverPath, '/tmp/c.jpg');

    // 用户手改过的行：文本字段保持用户版，只补技术字段。
    await index.updateSongUserMeta('webdav:nas', '/dav/b.mp3', artist: '我改的歌手');
    await index.enrichSong('webdav:nas', '/dav/b.mp3',
        title: '标签标题',
        artist: '标签歌手',
        album: '标签专辑',
        albumArtist: '标签专辑歌手',
        duration: 200);
    got = index.songByRef('webdav:nas', '/dav/b.mp3')!;
    expect(got.artist, '我改的歌手');
    expect(got.title, '/dav/b.mp3');
    expect(got.albumName, isNull);
    expect(got.albumArtist, isNull);
    expect(got.duration, 200);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('补读游标 afterId：不可解析的歌只跳过一次，不整批卡死', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxcursor_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    await index.upsertSongs([
      for (var i = 1; i <= 3; i++)
        DirectSongRow(
          sourceKey: 'webdav:nas',
          ref: '/dav/$i.mp3',
          title: '曲 $i',
          format: 'm4a',
          size: 1024,
          mtime: 1,
        ),
    ]);

    final first = index.unreadSongs('webdav:nas', 2);
    expect(first.map((s) => s.sourceRef), ['/dav/1.mp3', '/dav/2.mp3']);
    // 前两条不可解析（不标已读），游标跳到第 3 条继续，不再重复前两条。
    final next = index.unreadSongs('webdav:nas', 2, afterId: first.last.id);
    expect(next.map((s) => s.sourceRef), ['/dav/3.mp3']);
    // 新的一轮（无游标）仍会重试全部未读。
    expect(index.unreadSongs('webdav:nas', 10).length, 3);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('喜欢列表优先现查索引：补读后即时反映最新元数据', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxliked_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    await index.upsertSongs([
      DirectSongRow(
        sourceKey: 'webdav:nas',
        ref: '/dav/a.mp3',
        title: '文件名',
        format: 'mp3',
        size: 1024,
        mtime: 1,
      ),
    ]);
    // 收藏时写入的旧快照（无封面/无专辑歌手）。
    await index.setFavorite('webdav:nas', '/dav/a.mp3', true,
        songJson: jsonEncode({
          'id': 1,
          'sourceKey': 'webdav:nas',
          'title': '旧快照标题',
          'source': 'webdav',
          'sourceRef': '/dav/a.mp3',
          'fileSize': 1024,
        }));

    var liked = index.likedSongs();
    expect(liked.single.title, '文件名'); // 现查索引优先，不是旧快照

    await index.enrichSong('webdav:nas', '/dav/a.mp3',
        title: '新标题',
        artist: '新歌手',
        album: '新专辑',
        albumArtist: '新专辑歌手',
        coverPath: '/tmp/new.jpg');
    liked = index.likedSongs();
    expect(liked.single.title, '新标题');
    expect(liked.single.artist, '新歌手');
    expect(liked.single.albumName, '新专辑');
    expect(liked.single.albumArtist, '新专辑歌手');
    expect(liked.single.coverPath, '/tmp/new.jpg');

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('歌词存储：三态读取、覆盖写入、缺歌词标记不覆盖内嵌', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxlrc_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    const key = 'webdav:nas';
    expect(index.lyricsOf(key, '/dav/a.mp3'), isNull);

    await index.setLyrics(key, '/dav/a.mp3', '[00:01.00]第一句');
    expect(index.lyricsOf(key, '/dav/a.mp3'), '[00:01.00]第一句');

    // 覆盖写入（补读到内嵌歌词 / 用户重取）。
    await index.setLyrics(key, '/dav/a.mp3', '[00:02.00]新歌词');
    expect(index.lyricsOf(key, '/dav/a.mp3'), '[00:02.00]新歌词');

    // 缺歌词标记：空串代表「查过但没有」。
    await index.markLyricsMissing(key, '/dav/b.mp3');
    expect(index.lyricsOf(key, '/dav/b.mp3'), '');

    // 已有内嵌歌词时标记不覆盖。
    await index.markLyricsMissing(key, '/dav/a.mp3');
    expect(index.lyricsOf(key, '/dav/a.mp3'), '[00:02.00]新歌词');

    // 标记后补读到内嵌歌词仍可写入。
    await index.setLyrics(key, '/dav/b.mp3', '[00:05.00]补读歌词');
    expect(index.lyricsOf(key, '/dav/b.mp3'), '[00:05.00]补读歌词');

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('歌单内歌曲搜索：标题/歌手、忽略大小写、特殊字符转义', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_plsearch_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    await index.createPlaylist('古典');
    await index.createPlaylist('流行');
    final idle = index.listPlaylists()
        .firstWhere((p) => p.name == '古典')
        .id;
    final pop = index.listPlaylists().firstWhere((p) => p.name == '流行').id;
    await index.addPlaylistItem(idle,
        sourceKey: 'local:x', songRef: 'a', title: 'Nocturne Op.9', artist: 'Chopin');
    await index.addPlaylistItem(pop,
        sourceKey: 'local:x', songRef: 'b', title: '夜曲', artist: '周杰伦');
    await index.addPlaylistItem(idle,
        sourceKey: 'local:x',
        songRef: 'c',
        title: '圆舞曲',
        artist: 'Chopin',
        album: '夜曲与圆舞曲集');

    expect(index.playlistIdsMatchingSong('nocturne'), {idle});
    expect(index.playlistIdsMatchingSong('chopin'), {idle});
    expect(index.playlistIdsMatchingSong('夜曲'), {pop, idle});
    // 专辑名列同样参与匹配。
    expect(index.playlistIdsMatchingSong('圆舞曲集'), {idle});
    expect(index.playlistIdsMatchingSong('不存在'), isEmpty);
    // 无通配符注入：% / _ 按字面匹配。
    expect(index.playlistIdsMatchingSong('%'), isEmpty);
    expect(index.playlistIdsMatchingSong('_'), isEmpty);

    index.close();
    dir.deleteSync(recursive: true);
  });

  test('重扫覆盖保护：浅扫描空值不清空已读字段，兜底标题不覆盖', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_upsert_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    const key = 'local:test';
    const ref = 'a.flac';
    // 已完整读取的行（duration 非空 → meta_read=1）。
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: key,
        ref: ref,
        title: '真标题',
        titleFromMeta: true,
        artist: '歌手',
        album: '专辑',
        albumArtist: '专辑歌手',
        trackNo: 3,
        year: 2020,
        genre: '古典',
        duration: 180,
        format: 'flac',
        size: 100,
        mtime: 1,
        coverPath: '/tmp/c.jpg',
      ),
    ]);
    expect(index.songByRef(key, ref)!.metaRead, isTrue);

    // 指变化 + minimal 扫描：非空头部值更新，空值不覆盖已读字段；重置未读待自愈。
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: key,
        ref: ref,
        title: '头部标题',
        titleFromMeta: true,
        artist: '头部歌手',
        format: 'flac',
        size: 100,
        mtime: 2,
      ),
    ]);
    final mid = index.songByRef(key, ref)!;
    expect(mid.title, '头部标题');
    expect(mid.artist, '头部歌手');
    expect(mid.albumName, '专辑');
    expect(mid.duration, 180);
    expect(mid.trackNo, 3);
    expect(mid.year, 2020);
    expect(mid.genre, '古典');
    expect(mid.coverPath, '/tmp/c.jpg');
    expect(mid.metaRead, isFalse);

    // fast 兜底标题（titleFromMeta=false）不覆盖已读标题。
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: key,
        ref: ref,
        title: 'a',
        titleFromMeta: false,
        format: 'flac',
        size: 100,
        mtime: 3,
      ),
    ]);
    expect(index.songByRef(key, ref)!.title, '头部标题');

    // full 扫描（duration 非空）覆盖并标已读。
    await index.upsertSongs([
      DirectSongRow(
        sourceKey: key,
        ref: ref,
        title: '重读标题',
        titleFromMeta: true,
        artist: '新歌手',
        duration: 200,
        format: 'flac',
        size: 100,
        mtime: 4,
      ),
    ]);
    final full = index.songByRef(key, ref)!;
    expect(full.title, '重读标题');
    expect(full.artist, '新歌手');
    expect(full.duration, 200);
    expect(full.metaRead, isTrue);

    index.close();
    dir.deleteSync(recursive: true);
  });

  group('忽略音频在已入库歌曲上过滤（改进.txt 功能6）', () {
    test('时长/大小阈值对已扫描歌曲生效；时长未知一律放过', () async {
      open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
      final dir = await Directory.systemTemp.createTemp('selfmusic_ignore_');
      PathProviderPlatform.instance = _FakePathProvider(dir.path);
      final index = LocalIndex();
      await index.open();
      await index.upsertSongs([
        DirectSongRow(
            sourceKey: 'local:ignore',
            ref: 'short.mp3',
            title: '短歌',
            duration: 40,
            format: 'mp3',
            size: 1024,
            mtime: 1),
        DirectSongRow(
            sourceKey: 'local:ignore',
            ref: 'long.mp3',
            title: '长歌',
            duration: 400,
            format: 'mp3',
            size: 2 * 1024 * 1024,
            mtime: 2),
        // 快扫/补读前：时长未知（null），按「未知放过」规则不该被过滤。
        DirectSongRow(
            sourceKey: 'local:ignore',
            ref: 'unknown.mp3',
            title: '未知时长',
            format: 'mp3',
            size: 300 * 1024,
            mtime: 3),
      ]);
      await index.flushWrites();

      // 默认不过滤
      expect(index.countSongs('local:ignore'), 3);

      // 时长 <300 被过滤；未知时长放过
      expect(index.countSongs('local:ignore', minDurationSec: 300), 2);
      final byDur = index
          .searchSongs(sourceKey: 'local:ignore', minDurationSec: 300)
          .map((s) => s.sourceRef)
          .toList();
      expect(byDur, containsAll(['long.mp3', 'unknown.mp3']));
      expect(byDur, isNot(contains('short.mp3')));

      // 大小 <1MB 被过滤（仅 long 2MB 通过）
      expect(index.countSongs('local:ignore', minSizeBytes: 1024 * 1024), 1);
      expect(
          index
              .searchSongs(sourceKey: 'local:ignore',
                  minSizeBytes: 1024 * 1024)
              .single
              .sourceRef,
          'long.mp3');

      // 喜欢列表同样按规则过滤
      await index.setFavorite('local:ignore', 'short.mp3', true);
      await index.setFavorite('local:ignore', 'long.mp3', true);
      await index.flushWrites();
      final fav = index
          .favorites('local:ignore', minDurationSec: 300)
          .map((s) => s.sourceRef)
          .toList();
      expect(fav, contains('long.mp3'));
      expect(fav, isNot(contains('short.mp3')));

      index.close();
      dir.deleteSync(recursive: true);
    });
  });
}
