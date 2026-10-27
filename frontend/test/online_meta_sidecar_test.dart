import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/sources/music_source.dart';

void main() {
  test('在线元数据保存口径：内嵌值可解析，旧值/未知值回退仅应用缓存', () {
    expect(OnlineMetaSaveMode.parse('embed'), OnlineMetaSaveMode.embed);
    expect(OnlineMetaSaveMode.parse('sidecar'), OnlineMetaSaveMode.sidecar);
    expect(OnlineMetaSaveMode.parse('appCache'), OnlineMetaSaveMode.appCache);
    expect(OnlineMetaSaveMode.parse(null), OnlineMetaSaveMode.appCache);
    expect(OnlineMetaSaveMode.parse('unknown'), OnlineMetaSaveMode.appCache);
  });

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
