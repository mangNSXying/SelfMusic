import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/song_search.dart';

Song _song({String title = 't', String? artist, String? albumName, String? albumArtist = 'AA'}) =>
    Song(
      id: 1,
      sourceKey: 'server',
      title: title,
      artist: artist,
      albumName: albumName,
      albumArtist: albumArtist,
      source: 'local',
      sourceRef: 'r',
      fileSize: 0,
    );

void main() {
  test('歌单内歌曲搜索：专辑名与专辑歌手参与匹配（忽略大小写）', () {
    final s = _song(title: 'Nocturne', artist: 'Chopin',
        albumName: '夜曲与圆舞曲集', albumArtist: 'Orchestra');

    expect(songMatchesQuery(s, 'nocturne'), isTrue);   // 标题
    expect(songMatchesQuery(s, 'chopin'), isTrue);     // 歌手
    expect(songMatchesQuery(s, '夜曲与'), isTrue);     // 专辑名
    expect(songMatchesQuery(s, 'orchestra'), isTrue);  // 专辑歌手（忽略大小写）
    expect(songMatchesQuery(s, '不存在'), isFalse);
    expect(songMatchesQuery(s, ''), isTrue);
  });

  test('filterSongs：空白词返回原列表，专辑匹配命中', () {
    final list = [
      _song(title: 'a', albumName: '红色专辑'),
      _song(title: 'b', albumName: '蓝色专辑'),
      _song(title: 'c'),
    ];
    expect(filterSongs(list, '').length, 3);
    expect(filterSongs(list, '  ').length, 3);
    expect(filterSongs(list, '蓝色').map((s) => s.title), ['b']);
  });
}