import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/utils/collection_sort.dart';
import 'package:selfmusic/utils/song_search.dart';
import 'package:selfmusic/utils/zh_variant.dart';

OpenccConverter _conv(Map<String, String> entries) =>
    OpenccConverter.fromEntries(entries);

void main() {
  group('搜索与排序跟随显示口径', () {
    tearDown(debugResetZhForTest);

    Song song() => Song(
          id: 1,
          sourceKey: 'k',
          title: '夜曲',
          artist: '周傑倫',
          albumName: '十一月的蕭邦',
          source: 'local',
          sourceRef: 'r',
          fileSize: 0,
        );

    test('显示简体时，简体/繁体关键词都能命中', () {
      debugInstallZhConvertersForTest(
        t2s: _conv({'傑': '杰', '倫': '伦', '蕭': '萧', '邦': '邦'}),
        s2t: _conv({'杰': '傑', '伦': '倫', '萧': '蕭'}),
      );
      expect(songMatchesQuery(song(), '周杰伦'), isTrue);
      expect(songMatchesQuery(song(), '周傑倫'), isTrue);
      expect(songMatchesQuery(song(), '萧邦'), isTrue);
      expect(songMatchesQuery(song(), '蕭邦'), isTrue);
    });

    test('字符排序按转换后的文字比较', () {
      debugInstallZhConvertersForTest(
        t2s: _conv({'劉': '刘', '華': '华', '德': '德'}),
        s2t: _conv({'刘': '劉', '华': '華'}),
      );
      // 原始码位：前(524D) < 劉(5289)；转简体后：刘(5218) < 前(524D)，
      // 顺序翻转，证明比较前确实做了显示转换。
      final names = ['前田', '劉德華'];
      expect(sortByChars(names, (e) => e, false), ['劉德華', '前田']);
    });
  });
}
