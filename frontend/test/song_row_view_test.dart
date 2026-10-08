import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/models/song.dart';
import 'package:selfmusic/widgets/song_row_view.dart';

Song _song({
  String title = '歌名',
  String? artist = '歌手',
  String? album,
  String? albumArtist,
  int? duration,
  int fileSize = 0,
  String? format,
  String? coverPath,
  String sourceKey = 'local:x',
  String sourceRef = '/m/a.flac',
  int id = 1,
}) =>
    Song(
      id: id,
      sourceKey: sourceKey,
      title: title,
      artist: artist,
      albumName: album,
      albumArtist: albumArtist,
      duration: duration,
      source: 'local',
      sourceRef: sourceRef,
      fileSize: fileSize,
      format: format,
      coverPath: coverPath,
    );

void main() {
  group('SongRowView.subtitleOf', () {
    test('歌手 · 专辑', () {
      expect(
        SongRowView.subtitleOf(_song(artist: 'A', album: 'B')),
        'A · B',
      );
    });

    test('专辑歌手与歌手不同才追加，相同不冗余', () {
      expect(
        SongRowView.subtitleOf(
            _song(artist: 'A', album: 'B', albumArtist: 'C')),
        'A · B · 专辑歌手：C',
      );
      expect(
        SongRowView.subtitleOf(
            _song(artist: 'A', album: 'B', albumArtist: 'A')),
        'A · B',
      );
    });

    test('无歌手回退 Unknown，无专辑只留歌手', () {
      expect(SongRowView.subtitleOf(_song(artist: null)), 'Unknown');
    });
  });

  group('SongRowView.wideInfoOf', () {
    test('格式 · 码率 · 大小（码率 = size*8/duration）', () {
      // 25 MiB / 240s = 853 kbps；大小 25.0 MB。
      final info = SongRowView.wideInfoOf(_song(
        format: 'flac',
        duration: 240,
        fileSize: 25 * 1024 * 1024,
      ));
      expect(info, 'FLAC · 853 kbps · 25.0 MB');
    });

    test('缺时长跳过码率；不足 1MB 降为 KB', () {
      final info = SongRowView.wideInfoOf(_song(
        format: 'mp3',
        duration: null,
        fileSize: 512 * 1024,
      ));
      expect(info, 'MP3 · 512 KB');
    });

    test('全缺返回 null', () {
      expect(SongRowView.wideInfoOf(_song()), isNull);
    });
  });

  group('SongRowView.of', () {
    test('宽行带上 wideInfoText，窄行不带', () {
      final s = _song(format: 'flac', duration: 240, fileSize: 1024 * 1024);
      expect(SongRowView.of(song: s, titleFormat: SongTitleFormat.titleOnly, wide: true)
          .wideInfoText, isNotNull);
      expect(SongRowView.of(song: s, titleFormat: SongTitleFormat.titleOnly).wideInfoText,
          isNull);
    });

    test('标题按显示格式计算；封面/收藏/不喜欢随值透传', () {
      final s = _song(title: 'T', artist: 'A', coverPath: '/c.jpg');
      final row = SongRowView.of(
        song: s,
        titleFormat: SongTitleFormat.artistTitle,
        favorite: true,
        disliked: true,
      );
      expect(row.titleText, 'A - T');
      expect(row.subtitleText, 'A');
      expect(row.coverPath, '/c.jpg');
      expect(row.favorite, isTrue);
      expect(row.disliked, isTrue);
    });

    test('songKey 与列表多选口径一致（sourceKey|sourceRef|id）', () {
      final s = _song(sourceKey: 'webdav:t', sourceRef: '/dav/x.mp3', id: 7);
      expect(SongRowView.of(song: s, titleFormat: SongTitleFormat.titleOnly).songKey,
          'webdav:t|/dav/x.mp3|7');
    });
  });

  group('SongRowCache', () {
    test('同签名同长度复用整表', () {
      final cache = SongRowCache();
      var builds = 0;
      List<SongRowView> resolve() => cache.resolve(
            signature: 'sig',
            length: 2,
            build: (i) {
              builds++;
              return SongRowView(
                songKey: 'k$i',
                titleText: 't$i',
                subtitleText: 's',
              );
            },
          );
      final a = resolve();
      final b = resolve();
      expect(identical(a, b), isTrue);
      expect(builds, 2); // 仅首次构建两行
    });

    test('签名或长度变化即重算', () {
      final cache = SongRowCache();
      var builds = 0;
      SongRowView row(int i) {
        builds++;
        return SongRowView(songKey: 'k$i', titleText: 't', subtitleText: 's');
      }

      cache.resolve(signature: 'a', length: 1, build: row);
      cache.resolve(signature: 'b', length: 1, build: row);
      cache.resolve(signature: 'b', length: 2, build: row);
      expect(builds, 1 + 1 + 2);
    });

    test('invalidate 后强制重算', () {
      final cache = SongRowCache();
      var builds = 0;
      SongRowView row(int i) {
        builds++;
        return SongRowView(songKey: 'k$i', titleText: 't', subtitleText: 's');
      }

      cache.resolve(signature: 'a', length: 1, build: row);
      cache.invalidate();
      cache.resolve(signature: 'a', length: 1, build: row);
      expect(builds, 2);
    });
  });
}
