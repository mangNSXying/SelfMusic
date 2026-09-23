import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/lrc_parser.dart';

void main() {
  test('基本时间轴解析并排序', () {
    final p = parseLyrics('[00:12.34]第二行\n[00:03.5]第一行\n[01:02]第三行');
    expect(p.lines.length, 3);
    expect(p.lines[0].time, const Duration(seconds: 3, milliseconds: 500));
    expect(p.lines[0].text, '第一行');
    expect(p.lines[1].time, const Duration(seconds: 12, milliseconds: 340));
    expect(p.lines[2].time, const Duration(minutes: 1, seconds: 2));
    expect(p.plain, isNull);
  });

  test('一行多标签生成多行', () {
    final p = parseLyrics('[00:01.00][00:10.00]重复歌词');
    expect(p.lines.length, 2);
    expect(p.lines[0].time, const Duration(seconds: 1));
    expect(p.lines[1].time, const Duration(seconds: 10));
    expect(p.lines.every((l) => l.text == '重复歌词'), isTrue);
  });

  test('offset 元信息作用于所有行', () {
    final p = parseLyrics('[offset:-500]\n[00:01.00]歌词');
    expect(p.lines.single.time, const Duration(milliseconds: 500));
  });

  test('忽略 ti/ar 等元信息与纯时间行', () {
    final p = parseLyrics('[ti:标题]\n[ar:歌手]\n[00:05.00]\n[00:06.00]正文');
    expect(p.lines.length, 1);
    expect(p.lines.single.text, '正文');
  });

  test('无时间标签退化为纯文本', () {
    final p = parseLyrics('第一行\n\n第二行');
    expect(p.lines, isEmpty);
    expect(p.plain, '第一行\n第二行');
  });

  test('空内容不算有歌词', () {
    expect(parseLyrics('').isEmpty, isTrue);
    expect(parseLyrics('\n\n').isEmpty, isTrue);
    expect(parseLyrics('[00:01.00]').isEmpty, isTrue);
  });

  test('毫秒位数一位/两位/三位', () {
    final p = parseLyrics('[00:01.1]a\n[00:02.12]b\n[00:03.123]c');
    expect(p.lines[0].time, const Duration(seconds: 1, milliseconds: 100));
    expect(p.lines[1].time, const Duration(seconds: 2, milliseconds: 120));
    expect(p.lines[2].time, const Duration(seconds: 3, milliseconds: 123));
  });

  group('翻译歌词', () {
    test('同行「原文 / 译文」拆分为译文（同一行整体）', () {
      final p = parseLyrics('[00:01.00]Hello / 你好\n[00:05.00]World');
      expect(p.lines[0].text, 'Hello');
      expect(p.lines[0].translation, '你好');
      expect(p.lines[0].time, const Duration(seconds: 1));
      expect(p.lines[1].translation, isNull);
    });

    test('无时间轴独立译文行归属上一行', () {
      final p = parseLyrics('[00:01.00]Hello\n你好\n[00:05.00]World');
      expect(p.lines.length, 2);
      expect(p.lines[0].text, 'Hello');
      expect(p.lines[0].translation, '你好');
      expect(p.lines[1].translation, isNull);
    });

    test('连续无时间轴行作为多行译文拼接', () {
      final p = parseLyrics('[00:01.00]Hello\n你好\n世界');
      expect(p.lines.single.translation, '你好\n世界');
    });

    test('无时间轴行出现在首行时间轴之前时不误挂', () {
      final p = parseLyrics('作词：某某\n[00:01.00]Hello');
      expect(p.lines.single.text, 'Hello');
      expect(p.lines.single.translation, isNull);
    });

    test('分隔符两侧为空时不当译文拆分', () {
      final (t1, tr1) = splitLyricTranslation('A / ');
      expect(tr1, isNull);
      expect(t1, 'A / ');
      final (t2, tr2) = splitLyricTranslation(' / 译文');
      expect(tr2, isNull);
      expect(t2, ' / 译文');
    });
  });

  group('lyricIndexAt', () {
    final lines = [
      const LyricLine(Duration(seconds: 1), 'a'),
      const LyricLine(Duration(seconds: 3), 'b'),
      const LyricLine(Duration(seconds: 5), 'c'),
    ];

    test('按时间定位当前行', () {
      expect(lyricIndexAt(lines, Duration.zero), -1);
      expect(lyricIndexAt(lines, const Duration(seconds: 1)), 0);
      expect(lyricIndexAt(lines, const Duration(seconds: 4)), 1);
      expect(lyricIndexAt(lines, const Duration(seconds: 5)), 2);
      expect(lyricIndexAt(lines, const Duration(seconds: 99)), 2);
    });

    test('空列表返回 -1', () {
      expect(lyricIndexAt(const [], const Duration(seconds: 1)), -1);
    });
  });
}
