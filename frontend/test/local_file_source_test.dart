import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/local_file_direct_source.dart';
import 'package:selfmusic/platform/harmonyos/ohos_platform_bridge.dart';

void main() {
  group('文件级本地源 ref 与配置', () {
    test('重名在扩展名前追加 (2)/(3)，大小写不敏感', () {
      final used = <String>{};
      expect(uniqueLocalFileRef('Song.mp3', used), 'Song.mp3');
      expect(uniqueLocalFileRef('song.MP3', used), 'song (2).MP3');
      expect(uniqueLocalFileRef('Song.mp3', used), 'Song (3).mp3');
    });

    test('mergePickedLocalFiles 按 URI 去重并生成唯一 ref', () {
      final existing = [
        const LocalFileEntry(
          ref: 'a.mp3',
          uri: 'file://docs/a.mp3',
          name: 'a.mp3',
          size: 1,
          mtime: 1,
        ),
      ];
      final merged = mergePickedLocalFiles(
        existing: existing,
        picked: [
          const OhosPickedFile(
            uri: 'file://docs/a.mp3',
            name: 'a.mp3',
            size: 1,
            mtime: 1,
            persisted: true,
            readable: true,
          ),
          const OhosPickedFile(
            uri: 'file://docs/b/a.mp3',
            name: 'a.mp3',
            size: 2,
            mtime: 2,
            persisted: true,
            readable: true,
          ),
        ],
      );
      expect(merged, hasLength(2));
      expect(merged[1].ref, 'a (2).mp3');
      expect(merged[1].uri, 'file://docs/b/a.mp3');
    });

    test('文件名空时回退 URI 末段', () {
      final merged = mergePickedLocalFiles(
        existing: const [],
        picked: [
          const OhosPickedFile(
            uri: 'file://docs/%E6%AD%8C.mp3',
            name: '',
            size: 0,
            mtime: 0,
            persisted: false,
            readable: false,
          ),
        ],
      );
      expect(merged.single.ref, '歌.mp3');
    });

    test('非 files 模式/损坏项解析为空或跳过', () {
      expect(parseLocalFileEntries({'path': 'file://docs'}), isEmpty);
      expect(
        parseLocalFileEntries({
          'mode': 'files',
          'files': [
            {'ref': 'a.mp3', 'uri': 'file://docs/a.mp3'},
            {'ref': '', 'uri': 'file://docs/b.mp3'},
            {'ref': 'c.mp3'},
            {'ref': 'a.mp3', 'uri': 'file://docs/a.mp3'},
            {'ref': 3, 'uri': 'file://docs/n.mp3'},
            {'ref': 'd.mp3', 'uri': 4},
            'bad',
          ],
        }).map((e) => e.ref),
        ['a.mp3'],
      );
    });

    test('配置往返保留 ref/uri/name/size/mtime', () {
      final cfg = localFilesConfig(const [
        LocalFileEntry(
          ref: 'a.mp3',
          uri: 'file://docs/a.mp3',
          name: 'a.mp3',
          size: 10,
          mtime: 20,
        ),
      ]);
      final parsed = parseLocalFileEntries(cfg);
      expect(parsed, hasLength(1));
      expect(parsed.single.ref, 'a.mp3');
      expect(parsed.single.uri, 'file://docs/a.mp3');
      expect(parsed.single.size, 10);
      expect(parsed.single.mtime, 20);
    });
  });
}
