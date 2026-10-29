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

  group('SourceFolderTree', () {
    const refs = [
      'root.mp3',
      'rock/a.mp3',
      'rock/b.mp3',
      'rock/deep/c.mp3',
      'pop/d.mp3',
    ];

    test('根目录：子文件夹、直属歌曲与递归计数', () {
      final tree = SourceFolderTree.build(relRefs: refs);
      final root = tree.nodeOf('')!;
      expect(root.children.keys, ['pop', 'rock']);
      expect(root.children['rock']!.total, 3);
      expect(root.children['pop']!.total, 1);
      expect(root.directSongIndices, [0]);
      expect(root.total, 5);
    });

    test('任意层节点与直属歌曲（路径写法容错）', () {
      final tree = SourceFolderTree.build(relRefs: refs);
      final rock = tree.nodeOf('/rock/')!;
      expect(rock.directSongIndices, [1, 2]);
      expect(rock.children.keys, ['deep']);
      final deep = tree.nodeOf('rock/deep')!;
      expect(deep.directSongIndices, [3]);
      expect(deep.children, isEmpty);
      expect(deep.total, 1);
    });

    test('不存在的目录返回 null（扫描后文件夹消失的兜底）', () {
      final tree = SourceFolderTree.build(relRefs: refs);
      expect(tree.nodeOf('gone'), isNull);
    });

    test('空文件夹：任意层都由 extraFolders 建出', () {
      final tree = SourceFolderTree.build(
        relRefs: const [],
        extraFolders: const ['新建/深层', '空'],
      );
      final root = tree.nodeOf('')!;
      expect(root.children.keys, ['新建', '空']);
      expect(root.children.values.every((n) => n.total == 0), isTrue);
      expect(tree.nodeOf('新建/深层')!.hasChildren, isFalse);
      expect(tree.nodeOf('新建')!.hasChildren, isTrue);
      // 文件夹已有歌时不重复，计数以歌曲为准。
      final withSongs = SourceFolderTree.build(
        relRefs: const ['rock/a.mp3'],
        extraFolders: const ['rock'],
      );
      expect(withSongs.nodeOf('rock')!.total, 1);
    });

    test('同名目录在不同父级不合并', () {
      final tree = SourceFolderTree.build(
        relRefs: const ['live/a.mp3', 'rock/live/b.mp3'],
      );
      expect(tree.nodeOf('live')!.directSongIndices, [0]);
      expect(tree.nodeOf('rock/live')!.directSongIndices, [1]);
    });

    test('后代目录枚举（先序、同级按名排序）', () {
      final tree = SourceFolderTree.build(
        relRefs: const ['a/1.mp3', 'a/b/2.mp3', 'a/b/c/3.mp3', 'z/4.mp3'],
      );
      expect(tree.descendantFolders(''), ['a', 'a/b', 'a/b/c', 'z']);
      expect(tree.descendantFolders('a'), ['a/b', 'a/b/c']);
      expect(tree.descendantFolders('missing'), isEmpty);
    });
  });

  group('SourceFolderTreeCache', () {
    test('命中与失效', () {
      final cache = SourceFolderTreeCache();
      const refs2 = ['a/x.mp3'];
      final a = cache.resolve(relRefs: refs2);
      final b = cache.resolve(relRefs: refs2);
      expect(identical(a, b), isTrue);
      final c = cache.resolve(relRefs: refs2, extraFolders: const ['空']);
      expect(identical(a, c), isFalse);
      expect(c.nodeOf('空'), isNotNull);
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
