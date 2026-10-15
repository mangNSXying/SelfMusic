import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/album.dart';
import 'package:selfmusic/models/song.dart';

Song _song(String title, String? artist, String? albumArtist, String? album) =>
    Song(
      id: title.hashCode,
      sourceKey: 'local:test',
      title: title,
      artist: artist,
      albumArtist: albumArtist,
      albumName: album,
      source: 'local',
      sourceRef: 'test/$title',
      fileSize: 0,
    );

void main() {
  test('同名合辑不同曲目歌手合并为一组，主歌手为出现最多者', () {
    final albums = Album.fromSongs([
      _song('A', '张三', '群星', '合辑'),
      _song('B', '李四', '群星', '合辑'),
      _song('C', '王五', null, '独唱'),
    ]);

    expect(albums.length, 2);
    final heji = albums.firstWhere((a) => a.album == '合辑');
    expect(heji.artist, '群星');
    expect(heji.artists, ['群星']);
    expect(heji.trackCount, 2);
    final dan = albums.firstWhere((a) => a.album == '独唱');
    expect(dan.artist, '王五');
  });

  test('有名专辑按名强制合并：不同歌手同名也并为一张', () {
    final albums = Album.fromSongs([
      _song('A', '张三', null, '专辑'),
      _song('B', '李四', '', '专辑'),
    ]);
    expect(albums.length, 1);
    expect(albums.single.trackCount, 2);
    // 票数持平按首次出现，主歌手为张三。
    expect(albums.single.artist, '张三');
    expect(albums.single.artists, ['张三', '李四']);
  });

  test('周杰伦复现：同专辑独唱与合作串合并，主歌手淡化其余', () {
    final albums = Album.fromSongs([
      _song('发如雪', '周杰伦', null, '十一月的萧邦'),
      _song('珊瑚海', '周杰伦、梁心颐', null, '十一月的萧邦'),
    ]);
    expect(albums.length, 1);
    final a = albums.single;
    expect(a.album, '十一月的萧邦');
    expect(a.trackCount, 2);
    expect(a.artist, '周杰伦');
    expect(a.artists, ['周杰伦', '梁心颐']);
  });

  test('未知专辑不合并：无专辑标签仍按歌手分组', () {
    final albums = Album.fromSongs([
      _song('A', '张三', null, null),
      _song('B', '李四', null, ''),
      _song('C', '张三', null, '   '),
    ]);
    expect(albums.length, 2);
    final zhang = albums.firstWhere((a) => a.artist == '张三');
    expect(zhang.album, 'Unknown Album');
    expect(zhang.trackCount, 2);
  });

  test('专辑名前后空格不拆分', () {
    final albums = Album.fromSongs([
      _song('A', '张三', null, '专辑'),
      _song('B', '李四', null, '  专辑  '),
    ]);
    expect(albums.length, 1);
    expect(albums.single.album, '专辑');
  });

  test('合作串分隔符复用歌手管线：& 与 feat 拆分计数', () {
    final albums = Album.fromSongs([
      _song('A', 'A', null, '专'),
      _song('B', 'A & B', null, '专'),
      _song('C', 'B feat. C', null, '专'),
    ]);
    expect(albums.length, 1);
    final a = albums.single;
    // A:2 票（A、A&B），B:2 票（A&B、B feat.C），C:1 票；并列按先见。
    expect(a.artists, ['A', 'B', 'C']);
    expect(a.artist, 'A');
  });

  test('containsSong 与 fromSongs 分组一致：每首歌恰属一组', () {
    final songs = [
      _song('A', '张三', '群星', '合辑'),
      _song('B', '李四', '群星', '合辑'),
      _song('发如雪', '周杰伦', null, '十一月的萧邦'),
      _song('珊瑚海', '周杰伦、梁心颐', null, '十一月的萧邦'),
      _song('C', '王五', null, '独唱'),
      _song('D', '王五', null, null),
      _song('E', '赵六', null, null),
    ];
    final albums = Album.fromSongs(songs);
    expect(albums.fold(0, (n, a) => n + a.trackCount), songs.length);
    for (final a in albums) {
      expect(songs.where(a.containsSong).length, a.trackCount,
          reason: '歌手详情页按 containsSong 取专辑歌曲，必须与分组数一致');
    }
    for (final s in songs) {
      expect(albums.where((a) => a.containsSong(s)).length, 1,
          reason: '每首歌恰属一组');
    }
  });
}
