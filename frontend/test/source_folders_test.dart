import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/source_folders.dart';

void main() {
  group('splitSourceRef/normalize', () {
    test('反斜杠/首尾斜杠/空段/. 归一', () {
      expect(splitSourceRef(r'a\b//c/./d.mp3'), ['a', 'b', 'c', 'd.mp3']);
      expect(normalizeDir('/a/b/'), 'a/b');
      expect(normalizeDir(''), isEmpty);
    });

    test('parentDirOf/baseNameOf', () {
      expect(parentDirOf(''), isEmpty);
      expect(parentDirOf('a'), isEmpty);
      expect(parentDirOf('a/b/c'), 'a/b');
      expect(baseNameOf(''), isEmpty);
      expect(baseNameOf('a/b'), 'b');
    });
  });

  group('displayRelRef', () {
    test('WebDAV 全路径剥离 base', () {
      expect(
        displayRelRef('/dav/music/rock/song.mp3', stripPrefix: '/dav/music'),
        'rock/song.mp3',
      );
    });

    test('SMB 含 root 前缀的 legacy 行剥离', () {
      expect(
        displayRelRef('music/flac/a.mp3', stripPrefix: 'music/flac'),
        'a.mp3',
      );
    });

    test('已是相对路径时不误伤', () {
      expect(displayRelRef('rock/song.mp3', stripPrefix: 'music'),
          'rock/song.mp3');
      expect(displayRelRef('a.mp3', stripPrefix: ''), 'a.mp3');
    });

    test('大小写敏感：前缀不一致不剥离', () {
      expect(displayRelRef('Music/a.mp3', stripPrefix: 'music'), 'Music/a.mp3');
    });
  });

  group('groupSourceSongs', () {
    const refs = [
      'root.mp3',
      'rock/a.mp3',
      'rock/b.mp3',
      'rock/deep/c.mp3',
      'pop/d.mp3',
    ];

    test('根目录：直属文件夹 + 根歌曲', () {
      final g = groupSourceSongs(refs, '');
      expect(g.folders.map((f) => f.name), ['pop', 'rock']);
      expect(g.folders.firstWhere((f) => f.name == 'rock').total, 3);
      expect(g.folders.firstWhere((f) => f.name == 'pop').total, 1);
      expect(g.songIndices, [0]);
    });

    test('钻取一层：本层歌曲 + 直属子文件夹', () {
      final g = groupSourceSongs(refs, 'rock');
      expect(g.folders.map((f) => f.name), ['deep']);
      expect(g.folders.single.total, 1);
      expect(g.songIndices, [1, 2]);
    });

    test('深层目录', () {
      final g = groupSourceSongs(refs, 'rock/deep');
      expect(g.folders, isEmpty);
      expect(g.songIndices, [3]);
    });

    test('目录写法容错（首尾斜杠）', () {
      final g = groupSourceSongs(refs, '/rock/');
      expect(g.songIndices, [1, 2]);
    });

    test('空源', () {
      final g = groupSourceSongs(const [], '');
      expect(g.folders, isEmpty);
      expect(g.songIndices, isEmpty);
    });

    test('不存在的目录为空（扫描后文件夹消失的兜底）', () {
      final g = groupSourceSongs(refs, 'gone');
      expect(g.folders, isEmpty);
      expect(g.songIndices, isEmpty);
    });

    test('空文件夹：按直属子文件夹显示且计数 0', () {
      final g = groupSourceSongs(const [], '');
      expect(g.folders.map((f) => f.name), isEmpty);
      final g2 = groupSourceSongs(const [], '', extraFolders: ['新建/深层', '空']);
      expect(g2.folders.map((f) => f.name), ['新建', '空']);
      expect(g2.folders.every((f) => f.total == 0), isTrue);
      // 进入新建后显示深层（仍为空）。
      final g3 = groupSourceSongs(const [], '新建', extraFolders: ['新建/深层', '空']);
      expect(g3.folders.map((f) => f.name), ['深层']);
      // 文件夹已有歌时不重复，计数以歌曲为准。
      final g4 =
          groupSourceSongs(const ['rock/a.mp3'], '', extraFolders: ['rock']);
      expect(g4.folders.single.total, 1);
    });

    test('SourceFolderCache 命中与失效', () {
      final cache = SourceFolderCache();
      const refs2 = ['a/x.mp3'];
      final a = cache.resolve(relRefs: refs2, dir: '', extraFolders: const []);
      final b = cache.resolve(relRefs: refs2, dir: '', extraFolders: const []);
      expect(identical(a, b), isTrue);
      final c = cache.resolve(relRefs: refs2, dir: 'a', extraFolders: const []);
      expect(identical(a, c), isFalse);
      expect(c.songIndices, [0]);
    });
  });

  group('indicesUnder', () {
    const refs = ['root.mp3', 'rock/a.mp3', 'rock/deep/c.mp3'];
    test('递归下标', () {
      expect(indicesUnder(refs, ''), [0, 1, 2]);
      expect(indicesUnder(refs, 'rock'), [1, 2]);
      expect(indicesUnder(refs, 'rock/deep'), [2]);
      expect(indicesUnder(refs, 'gone'), isEmpty);
    });
  });
}
