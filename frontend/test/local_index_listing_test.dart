import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/data/local/song_weight_store.dart';
import 'package:selfmusic/models/song.dart';
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
    index.upsertSongs(rows);

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
    final index = LocalIndex();
    await index.open();

    const decodedRef = '/dav/佐藤しずく - Growing!.flac';
    const encodedRef =
        '/dav/%E4%BD%90%E8%97%A4%E3%81%97%E3%81%9A%E3%81%8F%20-%20Growing%21.flac';
    index.upsertSongs([
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
    // 模拟历史版本写入的 ENCODE 收藏行（无歌曲快照）。
    index.upsertPlayMeta('webdav:nas', encodedRef, favorite: true);

    // 读侧：新 ref 能看到旧收藏态。
    expect(index.playMetaOf('webdav:nas', decodedRef).favorite, isTrue);
    // 喜欢列表：经回查补全出歌曲。
    final liked = index.likedSongs();
    expect(liked.length, 1);
    expect(liked.first.title, 'Growing!');

    // 写侧：取消喜欢后旧行被合并，不再残留。
    index.setFavorite('webdav:nas', decodedRef, false);
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
    weight.setDisliked(song, true);
    expect(weight.isDisliked(song), isTrue);
    expect(weight.factorOf(song), SongWeightStore.minFactor);
    // 锁定后跳过/播完只记 streak，不调权重。
    weight.onSkipped(song);
    weight.onSkipped(song);
    weight.onSkipped(song);
    expect(weight.factorOf(song), SongWeightStore.minFactor);
    expect(weight.isDisliked(song), isTrue);

    // 再次点击取消 → 解锁回 1.0。
    weight.setDisliked(song, false);
    expect(weight.isDisliked(song), isFalse);
    expect(weight.factorOf(song), SongWeightStore.defaultFactor);

    // 喜欢可解冻：先锁再喜欢 → 解锁且 factor 拉满。
    weight.setDisliked(song, true);
    weight.setLiked(song);
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
    index.upsertSongs([row('扫描标题', '扫描歌手', '扫描专辑')]);
    index.updateSongUserMeta('webdav:nas', '/dav/a.flac',
        title: '我的标题', artist: '我的歌手');

    var got = index.songByRef('webdav:nas', '/dav/a.flac')!;
    expect(got.title, '我的标题');
    expect(got.artist, '我的歌手');
    expect(got.albumName, '扫描专辑');

    // 再次扫描：标题/歌手/专辑保留用户版，其余字段照常更新。
    index.upsertSongs([row('新扫描标题', '新扫描歌手', '新扫描专辑')]);
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
    index.upsertSongs([row('/dav/min.mp3', null), row('/dav/full.mp3', 200)]);
    var unread = index.unreadSongs('webdav:nas', 100);
    expect(unread.map((s) => s.sourceRef), ['/dav/min.mp3']);

    // 补读后不再未读。
    index.enrichSong('webdav:nas', '/dav/min.mp3', duration: 180);
    unread = index.unreadSongs('webdav:nas', 100);
    expect(unread, isEmpty);

    // 排除正在播放的歌（后台补读跳过它，播放链路自己会重读）。
    index.upsertSongs([row('/dav/skip.mp3', null), row('/dav/other.mp3', null)]);
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
    index.upsertSongs([row('/dav/a.mp3'), row('/dav/b.mp3')]);

    // 补读把标签写回（fast 扫描只有文件名也能补全）。
    index.enrichSong('webdav:nas', '/dav/a.mp3',
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
    index.updateSongUserMeta('webdav:nas', '/dav/b.mp3', artist: '我改的歌手');
    index.enrichSong('webdav:nas', '/dav/b.mp3',
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

    index.upsertSongs([
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

    index.upsertSongs([
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
    index.setFavorite('webdav:nas', '/dav/a.mp3', true,
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

    index.enrichSong('webdav:nas', '/dav/a.mp3',
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

  test('服务端歌曲元数据本地覆盖：写入/读取/部分更新', () async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    final dir = await Directory.systemTemp.createTemp('selfmusic_idxovr_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    final index = LocalIndex();
    await index.open();

    expect(index.metaOverrideOf('server', '42'), isNull);
    index.setMetaOverride('server', '42', title: '覆盖标题');
    var o = index.metaOverrideOf('server', '42')!;
    expect(o.title, '覆盖标题');
    expect(o.artist, isNull);

    // 部分更新合并，不覆盖已有。
    index.setMetaOverride('server', '42', artist: '覆盖歌手');
    o = index.metaOverrideOf('server', '42')!;
    expect(o.title, '覆盖标题');
    expect(o.artist, '覆盖歌手');
    expect(o.isEmpty, isFalse);

    // 专辑歌手同样支持部分覆盖。
    index.setMetaOverride('server', '42', albumArtist: '覆盖专辑歌手');
    o = index.metaOverrideOf('server', '42')!;
    expect(o.albumArtist, '覆盖专辑歌手');
    expect(o.title, '覆盖标题');

    // 空串 = 显式清空（覆盖层保留 ''，渲染层据此显示未知）；null = 不动该字段。
    index.setMetaOverride('server', '42', artist: '');
    o = index.metaOverrideOf('server', '42')!;
    expect(o.artist, '');
    expect(o.title, '覆盖标题');
    index.setMetaOverride('server', '42', title: null);
    o = index.metaOverrideOf('server', '42')!;
    expect(o.title, '覆盖标题');

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

    index.setLyrics(key, '/dav/a.mp3', '[00:01.00]第一句');
    expect(index.lyricsOf(key, '/dav/a.mp3'), '[00:01.00]第一句');

    // 覆盖写入（补读到内嵌歌词 / 用户重取）。
    index.setLyrics(key, '/dav/a.mp3', '[00:02.00]新歌词');
    expect(index.lyricsOf(key, '/dav/a.mp3'), '[00:02.00]新歌词');

    // 缺歌词标记：空串代表「查过但没有」。
    index.markLyricsMissing(key, '/dav/b.mp3');
    expect(index.lyricsOf(key, '/dav/b.mp3'), '');

    // 已有内嵌歌词时标记不覆盖。
    index.markLyricsMissing(key, '/dav/a.mp3');
    expect(index.lyricsOf(key, '/dav/a.mp3'), '[00:02.00]新歌词');

    // 标记后补读到内嵌歌词仍可写入。
    index.setLyrics(key, '/dav/b.mp3', '[00:05.00]补读歌词');
    expect(index.lyricsOf(key, '/dav/b.mp3'), '[00:05.00]补读歌词');

    index.close();
    dir.deleteSync(recursive: true);
  });
}
