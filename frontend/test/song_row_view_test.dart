import 'package:flutter/widgets.dart';
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
    test('播放源 · 格式 · 码率 · 大小（码率 = size*8/duration）', () {
      // 25 MiB / 240s = 853 kbps；大小 25.0 MB。
      final info = SongRowView.wideInfoOf(
        _song(
          format: 'flac',
          duration: 240,
          fileSize: 25 * 1024 * 1024,
        ),
        sourceName: 'NAS',
      );
      expect(info, 'NAS · FLAC · 853 kbps · 25.0 MB');
    });

    test('无友好源名时回退到 Song.source', () {
      final info = SongRowView.wideInfoOf(_song(format: 'flac'));
      expect(info, 'local · FLAC');
    });

    test('缺时长跳过码率；不足 1MB 降为 KB', () {
      final info = SongRowView.wideInfoOf(
        _song(
          format: 'mp3',
          duration: null,
          fileSize: 512 * 1024,
        ),
        sourceName: 'NAS',
      );
      expect(info, 'NAS · MP3 · 512 KB');
    });

    test('无格式/码率/大小时仍保留播放源', () {
      expect(SongRowView.wideInfoOf(_song(), sourceName: 'NAS'), 'NAS');
    });
  });

  group('SongTableCells', () {
    test('表格标题去掉歌手前缀；技术列格式化', () {
      final s = _song(
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 240,
        fileSize: 25 * 1024 * 1024,
        format: 'flac',
      );
      final cells = SongTableCells.of(
        s,
        titleFormat: SongTitleFormat.artistTitle,
        sourceName: 'NAS',
      );
      expect(cells.title, '晴天');
      expect(cells.artist, '周杰伦');
      expect(cells.album, '叶惠美');
      expect(cells.source, 'NAS');
      expect(cells.format, 'FLAC');
      expect(cells.bitrate, '853 kbps');
      expect(cells.size, '25.0 MB');
      expect(cells.duration, '04:00');
    });

    test('缺失字段用 — 兜底；文件名设置保留文件名语义', () {
      final s = _song(
        title: '',
        artist: null,
        album: null,
        sourceRef: '/m/x.flac',
      );
      final cells = SongTableCells.of(
        s,
        titleFormat: SongTitleFormat.fileName,
      );
      expect(cells.title, 'x');
      expect(cells.artist, '—');
      expect(cells.album, '—');
      expect(cells.source, 'local');
      expect(cells.format, '—');
      expect(cells.bitrate, '—');
      expect(cells.size, '—');
      expect(cells.duration, '—');
    });

    test('SongRowView.of(table: true) 同时给出标题与 9 列', () {
      final s = _song(title: 'T', artist: 'A', album: 'B');
      final row = SongRowView.of(
        song: s,
        titleFormat: SongTitleFormat.artistTitle,
        table: true,
      );
      expect(row.titleText, 'T');
      expect(row.tableCells, isNotNull);
      expect(row.wideInfoText, isNull);
    });
  });

  group('SongRowView.of', () {
    test('宽行带上 wideInfoText（含播放源），窄行不带', () {
      final s = _song(format: 'flac', duration: 240, fileSize: 1024 * 1024);
      final wide = SongRowView.of(
        song: s,
        titleFormat: SongTitleFormat.titleOnly,
        sourceName: 'NAS',
        wide: true,
      );
      expect(wide.wideInfoText, startsWith('NAS · FLAC'));
      expect(
          SongRowView.of(song: s, titleFormat: SongTitleFormat.titleOnly)
              .wideInfoText,
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
      expect(
          SongRowView.of(song: s, titleFormat: SongTitleFormat.titleOnly)
              .songKey,
          'webdav:t|/dav/x.mp3|7');
    });
  });

  group('SongRowCache', () {
    testWidgets('按需懒求值：只算被访问的行，复用缓存不再重复计算', (tester) async {
      final cache = SongRowCache();
      var builds = 0;
      SongRowView row(int i) {
        builds++;
        return SongRowView(songKey: 'k$i', titleText: 't', subtitleText: 's');
      }

      cache.begin('sig', 3);
      expect(cache.rowAt(1, () => row(1)).songKey, 'k1');
      expect(builds, 1); // 仅访问行 1
      cache.rowAt(1, () => row(1));
      cache.rowAt(2, () => row(2));
      expect(builds, 2); // 行 1 复用，行 2 新算
      await tester.pump();
    });

    testWidgets('签名或长度变化即重算', (tester) async {
      final cache = SongRowCache();
      var builds = 0;
      SongRowView row(int i) {
        builds++;
        return SongRowView(songKey: 'k$i', titleText: 't', subtitleText: 's');
      }

      cache.begin('a', 1);
      cache.rowAt(0, () => row(0));
      cache.begin('b', 1);
      cache.rowAt(0, () => row(0));
      cache.begin('b', 2);
      cache.rowAt(0, () => row(0));
      cache.rowAt(1, () => row(1));
      expect(builds, 1 + 1 + 2);
      await tester.pump();
    });

    testWidgets('invalidate 后强制重算', (tester) async {
      final cache = SongRowCache();
      var builds = 0;
      SongRowView row(int i) {
        builds++;
        return SongRowView(songKey: 'k$i', titleText: 't', subtitleText: 's');
      }

      cache.begin('a', 1);
      cache.rowAt(0, () => row(0));
      cache.invalidate();
      cache.begin('a', 1);
      cache.rowAt(0, () => row(0));
      expect(builds, 2);
      await tester.pump();
    });

    testWidgets('begin 失效时编排一次 post-frame 预热（onWarm）', (tester) async {
      final cache = SongRowCache();
      var warms = 0;
      var sig = 'sig';

      // 模拟真实用法：build 里 begin（帧内登记 → 帧末执行一次）。
      Widget probe() {
        cache.begin(sig, 1, onWarm: () => warms++);
        cache.rowAt(
            0,
            () => const SongRowView(
                songKey: 'k0', titleText: 't', subtitleText: 's'));
        return const SizedBox(width: 10, height: 10);
      }

      await tester.pumpWidget(probe());
      expect(warms, 1); // 首帧 build 编排、帧末已执行一次

      await tester.pumpWidget(probe()); // 同签名同长度 → 不失效不再预热
      expect(warms, 1);

      sig = 'sig2'; // 签名变化 → 再编排一次
      await tester.pumpWidget(probe());
      expect(warms, 2);
    });
  });
}
