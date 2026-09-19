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
  test('专辑按专辑歌手分组：同专辑不同曲目歌手合并为一组', () {
    final albums = Album.fromSongs([
      _song('A', '张三', '群星', '合辑'),
      _song('B', '李四', '群星', '合辑'),
      _song('C', '王五', null, '独唱'),
    ]);

    expect(albums.length, 2);
    final heji = albums.firstWhere((a) => a.album == '合辑');
    expect(heji.artist, '群星');
    expect(heji.trackCount, 2);
    final dan = albums.firstWhere((a) => a.album == '独唱');
    expect(dan.artist, '王五');
  });

  test('专辑歌手缺失时回退曲目歌手分组', () {
    final albums = Album.fromSongs([
      _song('A', '张三', null, '专辑'),
      _song('B', '李四', '', '专辑'),
    ]);
    expect(albums.length, 2);
  });
}
