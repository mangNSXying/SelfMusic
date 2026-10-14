import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/online_meta/string_sim.dart';

void main() {
  test('charSimilarDegree：相等/大小写/数字中文', () {
    expect(charSimilarDegree('a', 'a'), 1.0);
    expect(charSimilarDegree('A', 'a'), 0.8);
    expect(charSimilarDegree('1', '一'), 0.7);
    expect(charSimilarDegree('x', 'y'), 0.0);
  });

  test('stringSimilarDegree：相同为1，空为0', () {
    expect(stringSimilarDegree('hello', 'hello'), 1.0);
    expect(stringSimilarDegree('', ''), 1.0);
    expect(stringSimilarDegree('abc', ''), 0.0);
    expect(stringSimilarDegree('Yellow', 'yellow') > 0.8, isTrue);
  });

  test('selectBestMatch：完全一致胜出，阈值下返回-1', () {
    final best = selectBestMatch(
      title: 'Yellow',
      artist: 'Coldplay',
      album: '',
      filename: 'Coldplay - Yellow',
      candidates: const [
        (title: 'Yellow', artist: 'Coldplay', album: 'Parachutes'),
        (title: '完全不相关的标题', artist: '陌生人', album: '未知专辑'),
      ],
    );
    expect(best, 0);

    final none = selectBestMatch(
      title: 'Yellow',
      artist: 'Coldplay',
      album: '',
      filename: 'Yellow',
      candidates: const [
        (title: 'あいうえお', artist: '未知', album: '未知'),
      ],
    );
    expect(none, -1);
  });
}
