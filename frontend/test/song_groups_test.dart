import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/song_groups.dart';
import 'package:selfmusic/utils/source_folders.dart';

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
  group('songGroupKeyOf', () {
    test('none 恒返回空', () {
      expect(songGroupKeyOf(_song('a/b.mp3'), SongGroupMode.none), isEmpty);
    });

    test('文件夹只取直接父级，多层不钻取', () {
      expect(songGroupKeyOf(_song('a/b/c.mp3'), SongGroupMode.folder), 'b');
      expect(songGroupKeyOf(_song('rock/deep/d.mp3'), SongGroupMode.folder),
          'deep');
    });

    test('源根歌曲归入根目录', () {
      expect(songGroupKeyOf(_song('root.mp3'), SongGroupMode.folder),
          kRootFolderGroupName);
    });

    test('WebDAV 全路径先剥 base 再取父级', () {
      expect(
          songGroupKeyOf(
              _song('/dav/music/rock/song.mp3', sourceKey: 'webdav:n'),
              SongGroupMode.folder,
              stripPrefix: '/dav/music'),
          'rock');
    });

    test('反斜杠与首尾斜杠容错', () {
      expect(
          songGroupKeyOf(_song(r'rock\a.mp3'), SongGroupMode.folder), 'rock');
      expect(
          songGroupKeyOf(_song('/rock/a.mp3'), SongGroupMode.folder), 'rock');
    });

    test('专辑为空归入未知专辑，首尾空白裁掉', () {
      expect(songGroupKeyOf(_song('a.mp3'), SongGroupMode.album),
          kUnknownAlbumGroupName);
      expect(songGroupKeyOf(_song('a.mp3', album: '  '), SongGroupMode.album),
          kUnknownAlbumGroupName);
      expect(
          songGroupKeyOf(_song('a.mp3', album: '  A  '), SongGroupMode.album),
          'A');
    });
  });

  group('buildSongGroups', () {
    test('none 与空单返回空', () {
      expect(buildSongGroups([_song('a.mp3')], SongGroupMode.none, (_) => ''),
          isEmpty);
      expect(
          buildSongGroups(const [], SongGroupMode.folder, (_) => ''), isEmpty);
    });

    test('组按名排序、组内保原序', () {
      final songs = [
        _song('rock/b.mp3', id: 1),
        _song('pop/a.mp3', id: 2),
        _song('rock/a.mp3', id: 3),
        _song('root.mp3', id: 4),
      ];
      final groups = buildSongGroups(songs, SongGroupMode.folder, (_) => '');
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
      final groups = buildSongGroups(songs, SongGroupMode.folder, strip);
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
      final groups = buildSongGroups(songs, SongGroupMode.album, (_) => '');
      expect(groups.map((g) => g.name), ['A', 'B', '未知专辑']);
    });
  });

  group('SongGroupCache', () {
    test('列表身份/分类/源版本不变时复用，变化时重算', () {
      final cache = SongGroupCache();
      final songs = [_song('rock/a.mp3')];
      final a = cache.resolve(
          songs: songs,
          mode: SongGroupMode.folder,
          sourcesRev: 1,
          stripPrefixOf: (_) => '');
      final b = cache.resolve(
          songs: songs,
          mode: SongGroupMode.folder,
          sourcesRev: 1,
          stripPrefixOf: (_) => '');
      expect(identical(a, b), isTrue);
      final c = cache.resolve(
          songs: songs,
          mode: SongGroupMode.album,
          sourcesRev: 1,
          stripPrefixOf: (_) => '');
      expect(identical(a, c), isFalse);
      expect(c.single.name, kUnknownAlbumGroupName);
      final d = cache.resolve(
          songs: songs,
          mode: SongGroupMode.album,
          sourcesRev: 2,
          stripPrefixOf: (_) => '');
      expect(identical(c, d), isFalse);
    });
  });

  group('buildFlatRows', () {
    test('组头 + 组内歌曲，折叠时只剩组头', () {
      final groups = buildSongGroups([
        _song('rock/b.mp3', id: 1),
        _song('pop/a.mp3', id: 2),
        _song('rock/a.mp3', id: 3),
      ], SongGroupMode.folder, (_) => '');
      final expanded = buildFlatRows(groups, {});
      expect(expanded.map((r) => r.group ?? '#${r.song}'), [
        'pop',
        '#1',
        'rock',
        '#0',
        '#2',
      ]);
      final collapsed = buildFlatRows(groups, {'rock'});
      expect(collapsed.map((r) => r.group ?? '#${r.song}'), [
        'pop',
        '#1',
        'rock',
      ]);
    });

    test('空分组返回空行', () {
      expect(buildFlatRows(const [], {}), isEmpty);
    });
  });

  group('buildSourceTreeRows', () {
    const refs = [
      'root.mp3',
      'rock/a.mp3',
      'rock/deep/c.mp3',
      'pop/b.mp3',
    ];
    String label(SongListRow r) => r.folder?.name ?? 's${r.song}';

    test('默认折叠：当前层文件夹 + 本层歌曲', () {
      final tree = SourceFolderTree.build(relRefs: refs);
      final built = buildSourceTreeRows(tree: tree, dir: '', expanded: {});
      expect(built.rows.map(label), ['pop', 'rock', 's0']);
      expect(built.rows.map((r) => r.depth), [0, 0, 0]);
      expect(built.visibleSongIndices, [0]);
    });

    test('展开目录：先序插入子目录与本层歌曲（带缩进）', () {
      final tree = SourceFolderTree.build(relRefs: refs);
      final built = buildSourceTreeRows(
        tree: tree,
        dir: '',
        expanded: {'rock'},
      );
      expect(built.rows.map(label), ['pop', 'rock', 'deep', 's0', 's1']);
      expect(built.rows.map((r) => r.depth), [0, 0, 1, 1, 0]);
      expect(built.visibleSongIndices, [1, 0]);
    });

    test('从子目录作为根构建', () {
      final tree = SourceFolderTree.build(relRefs: refs);
      final collapsed =
          buildSourceTreeRows(tree: tree, dir: 'rock', expanded: {});
      expect(collapsed.rows.map(label), ['deep', 's0']);
      expect(collapsed.visibleSongIndices, [1]);

      final expanded = buildSourceTreeRows(
        tree: tree,
        dir: 'rock',
        expanded: {'rock/deep'},
      );
      expect(expanded.rows.map(label), ['deep', 's0', 's1']);
      expect(expanded.rows.map((r) => r.depth), [0, 1, 0]);
      expect(expanded.visibleSongIndices, [2, 1]);
    });

    test('空文件夹展开后显示子文件夹', () {
      final tree = SourceFolderTree.build(
        relRefs: const [],
        extraFolders: const ['空/深层'],
      );
      final collapsed =
          buildSourceTreeRows(tree: tree, dir: '', expanded: {});
      expect(collapsed.rows.map(label), ['空']);
      final expanded = buildSourceTreeRows(
        tree: tree,
        dir: '',
        expanded: {'空'},
      );
      expect(expanded.rows.map(label), ['空', '深层']);
      expect(expanded.visibleSongIndices, isEmpty);
    });

    test('目录不存在返回空行', () {
      final tree = SourceFolderTree.build(relRefs: refs);
      final built =
          buildSourceTreeRows(tree: tree, dir: 'gone', expanded: {});
      expect(built.rows, isEmpty);
      expect(built.visibleSongIndices, isEmpty);
    });
  });

  group('SongGroupModeX', () {
    test('parse 回落 none', () {
      expect(SongGroupModeX.parse(null), SongGroupMode.none);
      expect(SongGroupModeX.parse('folder'), SongGroupMode.folder);
      expect(SongGroupModeX.parse('nope'), SongGroupMode.none);
    });

    test('显式文件夹标签', () {
      expect(SongGroupMode.folder.labelFor(folderLabel: '文件夹（逐级）'), '文件夹（逐级）');
      expect(SongGroupMode.album.labelFor(folderLabel: '文件夹（逐级）'), '专辑');
    });
  });
}
