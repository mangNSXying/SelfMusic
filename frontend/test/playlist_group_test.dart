import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/playlist_group.dart';

Song _song(String ref,
    {String sourceKey = 'local:test', String? album, int id = 0}) {
  return Song.direct(
    id: id,
    sourceKey: sourceKey,
    title: 't$id',
    albumName: album,
    source: sourceKey,
    sourceRef: ref,
    fileSize: 1,
  );
}

void main() {
  group('playlistGroupKeyOf', () {
    test('none 恒返回空', () {
      expect(
          playlistGroupKeyOf(_song('a/b.mp3'), PlaylistGroup.none), isEmpty);
    });

    test('文件夹只取直接父级，多层不钻取', () {
      expect(playlistGroupKeyOf(_song('a/b/c.mp3'), PlaylistGroup.folder),
          'b');
      expect(playlistGroupKeyOf(_song('rock/deep/d.mp3'), PlaylistGroup.folder),
          'deep');
    });

    test('源根歌曲归入根目录', () {
      expect(playlistGroupKeyOf(_song('root.mp3'), PlaylistGroup.folder),
          kPlaylistRootFolderName);
    });

    test('WebDAV 全路径先剥 base 再取父级', () {
      expect(
          playlistGroupKeyOf(
              _song('/dav/music/rock/song.mp3', sourceKey: 'webdav:n'),
              PlaylistGroup.folder,
              stripPrefix: '/dav/music'),
          'rock');
    });

    test('反斜杠与首尾斜杠容错', () {
      expect(
          playlistGroupKeyOf(_song(r'rock\a.mp3'), PlaylistGroup.folder),
          'rock');
      expect(playlistGroupKeyOf(_song('/rock/a.mp3'), PlaylistGroup.folder),
          'rock');
    });

    test('专辑为空归入未知专辑，首尾空白裁掉', () {
      expect(playlistGroupKeyOf(_song('a.mp3'), PlaylistGroup.album),
          kPlaylistUnknownAlbumName);
      expect(
          playlistGroupKeyOf(
              _song('a.mp3', album: '  '), PlaylistGroup.album),
          kPlaylistUnknownAlbumName);
      expect(playlistGroupKeyOf(_song('a.mp3', album: '  A  '),
          PlaylistGroup.album), 'A');
    });
  });

  group('groupPlaylistSongs', () {
    test('none 与空单返回空', () {
      expect(groupPlaylistSongs([_song('a.mp3')], PlaylistGroup.none, (_) => ''),
          isEmpty);
      expect(groupPlaylistSongs(const [], PlaylistGroup.folder, (_) => ''),
          isEmpty);
    });

    test('组按名排序、组内保原序', () {
      final songs = [
        _song('rock/b.mp3', id: 1),
        _song('pop/a.mp3', id: 2),
        _song('rock/a.mp3', id: 3),
        _song('root.mp3', id: 4),
      ];
      final groups =
          groupPlaylistSongs(songs, PlaylistGroup.folder, (_) => '');
      expect(groups.map((g) => g.name), ['pop', 'rock', '根目录']);
      expect(groups[1].songIndices, [0, 2]);
      expect(groups[2].songIndices, [3]);
    });

    test('跨源同名文件夹合并为一组', () {
      final songs = [
        _song('rock/a.mp3', sourceKey: 'local:x', id: 1),
        _song('/dav/music/rock/b.mp3', sourceKey: 'webdav:y', id: 2),
      ];
      String strip(Song s) =>
          s.sourceKey.startsWith('webdav:') ? '/dav/music' : '';
      final groups = groupPlaylistSongs(songs, PlaylistGroup.folder, strip);
      expect(groups, hasLength(1));
      expect(groups.single.name, 'rock');
      expect(groups.single.songIndices, [0, 1]);
    });

    test('专辑分组', () {
      final songs = [
        _song('a.mp3', album: 'B', id: 1),
        _song('b.mp3', id: 2),
        _song('c.mp3', album: 'A', id: 3),
      ];
      final groups =
          groupPlaylistSongs(songs, PlaylistGroup.album, (_) => '');
      expect(groups.map((g) => g.name), ['A', 'B', '未知专辑']);
    });
  });

  group('PlaylistGroupX', () {
    test('parse 回落 none', () {
      expect(PlaylistGroupX.parse(null), PlaylistGroup.none);
      expect(PlaylistGroupX.parse('folder'), PlaylistGroup.folder);
      expect(PlaylistGroupX.parse('nope'), PlaylistGroup.none);
    });
  });
}
