import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/music_source.dart';

void main() {
  test('isSidecarFileName：歌词与封面后缀', () {
    expect(isSidecarFileName('a.lrc'), isTrue);
    expect(isSidecarFileName('a.LRC'), isTrue);
    expect(isSidecarFileName('cover.jpg'), isTrue);
    expect(isSidecarFileName('cover.jpeg'), isTrue);
    expect(isSidecarFileName('cover.png'), isTrue);
    expect(isSidecarFileName('cover.webp'), isTrue);
    expect(isSidecarFileName('song.mp3'), isFalse);
    expect(isSidecarFileName('song.flac'), isFalse);
    expect(isSidecarFileName('noext'), isFalse);
    expect(isSidecarFileName('.lrc'), isTrue);
  });
}
