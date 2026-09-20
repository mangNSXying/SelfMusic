import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/song_title_format.dart';

Song _song({
  required String title,
  String? artist,
  String source = 'local',
  String sourceRef = '/music/a.mp3',
  String? sourceKey,
}) =>
    Song(
      id: 1,
      sourceKey: sourceKey ?? '$source:t',
      title: title,
      artist: artist,
      source: source,
      sourceRef: sourceRef,
      fileSize: 0,
    );

void main() {
  test('四种标题格式', () {
    final s = _song(title: '歌名', artist: '歌手');
    expect(formatSongTitle(s, SongTitleFormat.fileName), 'a');
    expect(formatSongTitle(s, SongTitleFormat.titleOnly), '歌名');
    expect(formatSongTitle(s, SongTitleFormat.artistTitle), '歌手 - 歌名');
    expect(formatSongTitle(s, SongTitleFormat.titleArtist), '歌名 - 歌手');
  });

  test('无歌手时回退歌名；空标题回退文件名', () {
    final noArtist = _song(title: '歌名');
    expect(formatSongTitle(noArtist, SongTitleFormat.artistTitle), '歌名');
    expect(formatSongTitle(noArtist, SongTitleFormat.titleArtist), '歌名');

    final empty = _song(title: '', artist: '歌手');
    expect(formatSongTitle(empty, SongTitleFormat.titleOnly), 'a');
    expect(formatSongTitle(empty, SongTitleFormat.artistTitle), '歌手 - a');
  });

  test('服务端歌曲（ref 非路径）文件名回退歌名', () {
    final server = _song(
        title: '服务端歌名', source: 'server', sourceKey: 'server', sourceRef: '42');
    expect(formatSongTitle(server, SongTitleFormat.fileName), '服务端歌名');
  });

  test('默认值为歌手 - 歌名', () {
    expect(SongTitleFormat.parse(null), SongTitleFormat.artistTitle);
    expect(SongTitleFormat.parse('unknown'), SongTitleFormat.artistTitle);
  });
}
