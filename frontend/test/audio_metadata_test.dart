import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';

/// 写入 28-bit syncsafe 整数（ID3 尺寸/帧长）。
Uint8List syncsafe(int v) {
  return Uint8List.fromList([
    (v >> 21) & 0x7F,
    (v >> 14) & 0x7F,
    (v >> 7) & 0x7F,
    v & 0x7F,
  ]);
}

Uint8List textFrame(String id, String text) {
  final body = <int>[0]; // encoding: latin1
  body.addAll(text.codeUnits);
  return Uint8List.fromList([
    ...id.codeUnits,
    ...syncsafe(body.length),
    0,
    0, // frame flags
    ...body,
  ]);
}

/// enc==3 的 UTF-8 文本帧（此前误用 String.fromCharCodes 会乱码）。
Uint8List utf8Frame(String id, String text) {
  final body = <int>[3]; // encoding: UTF-8
  body.addAll(utf8.encode(text));
  return Uint8List.fromList([
    ...id.codeUnits,
    ...syncsafe(body.length),
    0,
    0,
    ...body,
  ]);
}

/// enc==0 声明 latin1、实际却是 UTF-8 字节（中文 MP3 常见误标）。
Uint8List misTaggedUtf8Frame(String id, String text) {
  final body = <int>[0]; // declared latin1
  body.addAll(utf8.encode(text));
  return Uint8List.fromList([
    ...id.codeUnits,
    ...syncsafe(body.length),
    0,
    0, // frame flags
    ...body,
  ]);
}

/// ISO-BMFF 盒：4 字节大端长度 + 4 字节类型 + body。
Uint8List mp4Box(String type, List<int> body) {
  final size = body.length + 8;
  return Uint8List.fromList([
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...body,
  ]);
}

int _mp4BoxSize(Uint8List b, int offset) =>
    (b[offset] << 24) |
    (b[offset + 1] << 16) |
    (b[offset + 2] << 8) |
    b[offset + 3];

/// ilst 的 `data` 盒：type(4) + locale(4) + payload。
Uint8List mp4Data(int type, List<int> payload) => mp4Box('data', [
      (type >> 24) & 0xFF,
      (type >> 16) & 0xFF,
      (type >> 8) & 0xFF,
      type & 0xFF,
      0, 0, 0, 0,
      ...payload,
    ]);

Uint8List mp4TextItem(String type, String text) =>
    mp4Box(type, mp4Data(1, utf8.encode(text)));

Uint8List mp4Mvhd(int timescale, int duration) {
  final body = Uint8List(20);
  ByteData.view(body.buffer)
    ..setUint32(12, timescale)
    ..setUint32(16, duration);
  return mp4Box('mvhd', body);
}

/// 测试用 JPEG（首尾完整，可通过 isCompleteImageBytes）。
Uint8List fakeJpeg(int bytes) => Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0,
      ...List<int>.filled(bytes, 0x11),
      0xFF, 0xD9,
    ]);

/// 构造带完整标签的 m4a：moov 在文件头，标签/歌词在前、大封面在后。
/// 返回 [ftyp + moov + mdat]，[moovEnd] 为 moov 盒的结束偏移。
({Uint8List bytes, int moovEnd}) m4aWithFrontMoov(Uint8List cover) {
  final ilst = mp4Box('ilst', [
    ...mp4TextItem('©nam', '应徵爱'),
    ...mp4TextItem('©ART', '陶喆'),
    ...mp4TextItem('aART', '陶喆'),
    ...mp4TextItem('©alb', '六九乐章'),
    ...mp4TextItem('©gen', '国语流行'),
    ...mp4TextItem('©day', '2009-08-21'),
    ...mp4Box('trkn', mp4Data(0, [0, 0, 0, 11, 0, 13, 0, 0])),
    ...mp4TextItem('©lyr', '[00:01.00]歌词一\n[00:02.00]歌词二'),
    ...mp4Box('covr', mp4Data(13, cover)),
  ]);
  final meta = mp4Box('meta', [
    0, 0, 0, 0, // version/flags
    ...mp4Box('hdlr', List<int>.filled(25, 0)),
    ...ilst,
  ]);
  final moov = mp4Box('moov', [
    ...mp4Mvhd(1000, 223000),
    ...mp4Box('udta', meta),
  ]);
  final ftyp = mp4Box('ftyp', [
    ...'M4A '.codeUnits,
    0, 0, 0, 1,
    ...'M4A '.codeUnits,
    ...'mp42'.codeUnits,
  ]);
  final mdat = mp4Box('mdat', List<int>.filled(64 * 1024, 0));
  final bytes = Uint8List.fromList([...ftyp, ...moov, ...mdat]);
  return (bytes: bytes, moovEnd: ftyp.length + moov.length);
}

void main() {
  group('parseAudioHead - mp3', () {
    test('exposes ID3v2 tags and estimates duration', () {
      final frames = <int>[
        ...textFrame('TIT2', 'Song Title'),
        ...textFrame('TPE1', 'Some Artist'),
        ...textFrame('TALB', 'Some Album'),
        ...textFrame('TCON', 'Rock'),
        ...textFrame('TRCK', '3/12'),
        ...textFrame('TYER', '2021'),
      ];
      final tagSize = frames.length;
      final tag = <int>[
        ...'ID3'.codeUnits,
        0x04,
        0x00,
        0x00,
        ...syncsafe(tagSize),
        ...frames,
      ];
      // MPEG1 Layer3 128kbps 44.1kHz frame header
      tag.addAll([0xFF, 0xFB, 0x90, 0x00]);

      final head = Uint8List.fromList(tag);
      final fileSize = tag.length + 100000; // pretend payload beyond head
      final meta = parseAudioHead(head, 'mp3', fileSize)!;

      expect(meta.title, 'Song Title');
      expect(meta.artist, 'Some Artist');
      expect(meta.album, 'Some Album');
      expect(meta.genre, 'Rock');
      expect(meta.year, 2021);
      expect(meta.trackNo, 3);
      // duration = (fileSize*8) / (128*1000)
      expect(meta.duration, ((fileSize * 8) / (128 * 1000)).round());
    });

    test('returns metadata even without a tag (fallback title path)', () {
      final head = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x00]);
      final meta = parseAudioHead(head, 'mp3', 64000);
      expect(meta, isNotNull);
    });

    test('decodes UTF-8 (enc==3) CJK tags correctly', () {
      final frames = <int>[
        ...utf8Frame('TIT2', '日本語の曲'),
        ...utf8Frame('TPE1', '中島みゆき'),
        ...utf8Frame('TALB', 'COM.ALBUM'),
      ];
      final tag = <int>[
        ...'ID3'.codeUnits,
        0x04,
        0x00,
        0x00,
        ...syncsafe(frames.length),
        ...frames,
        0xFF, 0xFB, 0x90, 0x00,
      ];
      final meta = parseAudioHead(Uint8List.fromList(tag), 'mp3', tag.length + 1)!;
      expect(meta.title, '日本語の曲');
      expect(meta.artist, '中島みゆき');
      expect(meta.album, 'COM.ALBUM');
    });

    test('recovers mis-tagged ISO-8859-1 frames that are actually UTF-8', () {
      final frames = <int>[
        ...misTaggedUtf8Frame('TIT2', '雨中曲'),
        ...misTaggedUtf8Frame('TPE1', '張學友'),
      ];
      final tag = <int>[
        ...'ID3'.codeUnits,
        0x04,
        0x00,
        0x00,
        ...syncsafe(frames.length),
        ...frames,
        0xFF, 0xFB, 0x90, 0x00,
      ];
      final meta = parseAudioHead(Uint8List.fromList(tag), 'mp3', tag.length + 1)!;
      expect(meta.title, '雨中曲');
      expect(meta.artist, '張學友');
    });

    test('exposes album artist (TPE2)', () {
      final frames = <int>[
        ...textFrame('TIT2', 'Song Title'),
        ...textFrame('TPE1', 'Track Artist'),
        ...textFrame('TPE2', 'Album Artist'),
      ];
      final tag = <int>[
        ...'ID3'.codeUnits,
        0x04,
        0x00,
        0x00,
        ...syncsafe(frames.length),
        ...frames,
        0xFF,
        0xFB,
        0x90,
        0x00,
      ];
      final meta =
          parseAudioHead(Uint8List.fromList(tag), 'mp3', tag.length + 1)!;
      expect(meta.artist, 'Track Artist');
      expect(meta.albumArtist, 'Album Artist');
    });

    test('exposes embedded lyrics (USLT, UTF-8)', () {
      // USLT 帧体：encoding(1) + language(3) + 描述(以 00 结束) + 歌词文本。
      Uint8List usltFrame(String text) {
        final body = <int>[3, ...'eng'.codeUnits, 0];
        body.addAll(utf8.encode(text));
        return Uint8List.fromList([
          ...'USLT'.codeUnits,
          ...syncsafe(body.length),
          0,
          0,
          ...body,
        ]);
      }

      final frames = <int>[
        ...utf8Frame('TIT2', '带歌词的歌'),
        ...usltFrame('[00:01.00]第一句\n[00:05.50]第二句'),
      ];
      final tag = <int>[
        ...'ID3'.codeUnits,
        0x04,
        0x00,
        0x00,
        ...syncsafe(frames.length),
        ...frames,
        0xFF,
        0xFB,
        0x90,
        0x00,
      ];
      final meta =
          parseAudioHead(Uint8List.fromList(tag), 'mp3', tag.length + 1)!;
      expect(meta.lyrics, '[00:01.00]第一句\n[00:05.50]第二句');
    });
  });

  group('parseAudioHead - flac', () {
    Uint8List u32le(int v) => Uint8List.fromList(
        [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

    test('exposes VORBIS_COMMENT tags and STREAMINFO duration', () {
      // STREAMINFO：18-byte body，尾 8 字节含 sample_rate(20) + total_samples(36)。
      // 0.44s @ 44.1kHz = 19404 samples
      const sampleRate = 44100;
      const totalSamples = 19404;
      final si = List<int>.filled(18, 0);
      si[10] = (sampleRate >> 12) & 0xFF;
      si[11] = (sampleRate >> 4) & 0xFF;
      si[12] = (sampleRate & 0x0F) << 4;
      si[13] = ((totalSamples >> 32) & 0x0F);
      si[14] = (totalSamples >> 24) & 0xFF;
      si[15] = (totalSamples >> 16) & 0xFF;
      si[16] = (totalSamples >> 8) & 0xFF;
      si[17] = totalSamples & 0xFF;

      // VORBIS_COMMENT
      final entries = <String>['TITLE=Flac Track', 'ARTIST=Flac Artist', 'ALBUM=Flac Album', 'DATE=2022', 'TRACKNUMBER=7'];
      final vc = <int>[];
      vc.addAll(u32le(0)); // vendor len 0 (LE)
      vc.addAll(u32le(entries.length));
      for (final e in entries) {
        vc.addAll(u32le(e.length));
        vc.addAll(e.codeUnits);
      }

      List<int> block(int type, List<int> body, {bool last = false}) =>
          [(last ? 0x80 : 0) | type, body.length >> 16 & 0xFF, body.length >> 8 & 0xFF, body.length & 0xFF, ...body];

      final head = Uint8List.fromList([
        ...'fLaC'.codeUnits,
        ...block(0, si),
        ...block(4, vc, last: true),
      ]);

      final meta = parseAudioHead(head, 'flac', head.length)!;
      expect(meta.title, 'Flac Track');
      expect(meta.artist, 'Flac Artist');
      expect(meta.album, 'Flac Album');
      expect(meta.year, 2022);
      expect(meta.trackNo, 7);
      expect(meta.duration, (totalSamples / sampleRate).round());
    });

    test('decodes UTF-8 CJK VORBIS_COMMENT entries (was garbled latin1)', () {
      List<int> u32le(int v) => Uint8List.fromList(
          [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
      final entries = <String>[
        'TITLE=日本語の曲',
        'ARTIST=中島みゆき',
        'ALBUM=COM.ALBUM',
      ];
      final vc = <int>[];
      vc.addAll(u32le(0)); // vendor len 0 (LE)
      vc.addAll(u32le(entries.length));
      for (final e in entries) {
        final bytes = utf8.encode(e);
        vc.addAll(u32le(bytes.length));
        vc.addAll(bytes);
      }
      List<int> block(int type, List<int> body, {bool last = false}) =>
          [(last ? 0x80 : 0) | type, body.length >> 16 & 0xFF, body.length >> 8 & 0xFF, body.length & 0xFF, ...body];

      final head = Uint8List.fromList([
        ...'fLaC'.codeUnits,
        ...block(0, List<int>.filled(18, 0)),
        ...block(4, vc, last: true),
      ]);

      final meta = parseAudioHead(head, 'flac', head.length)!;
      expect(meta.title, '日本語の曲');
      expect(meta.artist, '中島みゆき');
      expect(meta.album, 'COM.ALBUM');
    });

    test('parses ALBUMARTIST from VORBIS_COMMENT', () {
      List<int> u32le(int v) => Uint8List.fromList(
          [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
      final entries = <String>[
        'TITLE=群星合辑',
        'ARTIST=张三',
        'ALBUMARTIST=群星',
      ];
      final vc = <int>[];
      vc.addAll(u32le(0));
      vc.addAll(u32le(entries.length));
      for (final e in entries) {
        final bytes = utf8.encode(e);
        vc.addAll(u32le(bytes.length));
        vc.addAll(bytes);
      }
      List<int> block(int type, List<int> body, {bool last = false}) => [
            (last ? 0x80 : 0) | type,
            body.length >> 16 & 0xFF,
            body.length >> 8 & 0xFF,
            body.length & 0xFF,
            ...body
          ];

      final head = Uint8List.fromList([
        ...'fLaC'.codeUnits,
        ...block(0, List<int>.filled(18, 0)),
        ...block(4, vc, last: true),
      ]);
      final meta = parseAudioHead(head, 'flac', head.length)!;
      expect(meta.artist, '张三');
      expect(meta.albumArtist, '群星');
    });

    test('parses embedded lyrics (LYRICS/UNSYNCEDLYRICS)', () {
      List<int> u32le(int v) => Uint8List.fromList(
          [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
      final entries = <String>[
        'TITLE=带歌词的歌',
        'LYRICS=[00:01.00]第一句\n[00:03.00]第二句',
      ];
      final vc = <int>[];
      vc.addAll(u32le(0));
      vc.addAll(u32le(entries.length));
      for (final e in entries) {
        final bytes = utf8.encode(e);
        vc.addAll(u32le(bytes.length));
        vc.addAll(bytes);
      }
      List<int> block(int type, List<int> body, {bool last = false}) => [
            (last ? 0x80 : 0) | type,
            body.length >> 16 & 0xFF,
            body.length >> 8 & 0xFF,
            body.length & 0xFF,
            ...body
          ];
      final head = Uint8List.fromList([
        ...'fLaC'.codeUnits,
        ...block(0, List<int>.filled(18, 0)),
        ...block(4, vc, last: true),
      ]);
      final meta = parseAudioHead(head, 'flac', head.length)!;
      expect(meta.lyrics, '[00:01.00]第一句\n[00:03.00]第二句');
    });

    test('不因元数据块超出头部采样而越界（大内嵌封面场景）', () {
      // STREAMINFO（有效，含时长）后跟一个声明长度 300000、实际远小的 PICTURE 块。
      // 旧实现 head.sublist(i+4, i+4+len) 会抛 RangeError。
      const sampleRate = 44100;
      const totalSamples = 44100;
      final si = List<int>.filled(18, 0);
      si[10] = (sampleRate >> 12) & 0xFF;
      si[11] = (sampleRate >> 4) & 0xFF;
      si[12] = (sampleRate & 0x0F) << 4;
      si[13] = (totalSamples >> 32) & 0x0F;
      si[14] = (totalSamples >> 24) & 0xFF;
      si[15] = (totalSamples >> 16) & 0xFF;
      si[16] = (totalSamples >> 8) & 0xFF;
      si[17] = totalSamples & 0xFF;
      const huge = 300000;
      final head = Uint8List.fromList([
        ...'fLaC'.codeUnits,
        0x00, 0x00, 0x00, 18, ...si, // STREAMINFO
        0x06, (huge >> 16) & 0xFF, (huge >> 8) & 0xFF, huge & 0xFF, 1, 2, 3,
      ]);
      final meta = parseAudioHead(head, 'flac', head.length);
      expect(meta, isNotNull);
      expect(meta!.duration, (totalSamples / sampleRate).round());
    });
  });

  group('parseAudioHead - flac 前置 ID3v2（MusicPlayer2/TagLib 口径）', () {
    Uint8List id3v23Frame(String id, List<int> body) => Uint8List.fromList([
          ...id.codeUnits,
          (body.length >> 24) & 0xFF,
          (body.length >> 16) & 0xFF,
          (body.length >> 8) & 0xFF,
          body.length & 0xFF,
          0,
          0, // 帧 flags
          ...body,
        ]);

    Uint8List id3v23Tag(List<Uint8List> frames) {
      final body = <int>[];
      for (final f in frames) {
        body.addAll(f);
      }
      return Uint8List.fromList([
        ...'ID3'.codeUnits,
        0x03,
        0x00,
        0x00,
        ...syncsafe(body.length),
        ...body,
      ]);
    }

    List<int> utf8Body(String s) => [3, ...utf8.encode(s)];
    List<int> usltBody(String s) => [3, ...'eng'.codeUnits, 0, ...utf8.encode(s)];
    List<int> apicBody(List<int> img) =>
        [3, ...'image/jpeg'.codeUnits, 0, 3, 0, ...img];
    Uint8List fakeJpeg() => Uint8List.fromList([
          0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
          0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0xFF, 0xD9,
        ]);

    Uint8List flacHead({List<String> entries = const []}) {
      final si = List<int>.filled(34, 0);
      const sampleRate = 44100;
      const totalSamples = 44100;
      si[10] = (sampleRate >> 12) & 0xFF;
      si[11] = (sampleRate >> 4) & 0xFF;
      si[12] = (sampleRate & 0x0F) << 4;
      si[13] = (totalSamples >> 32) & 0x0F;
      si[14] = (totalSamples >> 24) & 0xFF;
      si[15] = (totalSamples >> 16) & 0xFF;
      si[16] = (totalSamples >> 8) & 0xFF;
      si[17] = totalSamples & 0xFF;
      List<int> u32le(int v) =>
          [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
      final vc = <int>[];
      final vendor = utf8.encode('test');
      vc.addAll(u32le(vendor.length));
      vc.addAll(vendor);
      vc.addAll(u32le(entries.length));
      for (final e in entries) {
        final b = utf8.encode(e);
        vc.addAll(u32le(b.length));
        vc.addAll(b);
      }
      List<int> block(int type, List<int> body, {bool last = false}) => [
            (last ? 0x80 : 0) | type,
            (body.length >> 16) & 0xFF,
            (body.length >> 8) & 0xFF,
            body.length & 0xFF,
            ...body,
          ];
      return Uint8List.fromList([
        ...'fLaC'.codeUnits,
        ...block(0, si),
        if (entries.isNotEmpty) ...block(4, vc),
        ...block(1, List<int>.filled(16, 0), last: true),
        1, 2, 3, 4, 5, 6, 7, 8, // 伪音频区（读侧不校验）
      ]);
    }

    test('Xiph 优先：文本/歌词取 VORBIS_COMMENT，ID3 APIC 不作为封面', () {
      final id3 = id3v23Tag([
        id3v23Frame('TIT2', utf8Body('ID3 标题')),
        id3v23Frame('TPE1', utf8Body('ID3 歌手')),
        id3v23Frame('TALB', utf8Body('ID3 专辑')),
        id3v23Frame('USLT', usltBody('ID3 歌词')),
        id3v23Frame('APIC', apicBody(fakeJpeg())),
      ]);
      final flac = flacHead(entries: [
        'TITLE=FLAC 标题',
        'ARTIST=FLAC 歌手',
        'ALBUM=FLAC 专辑',
        'LYRICS=FLAC 歌词',
      ]);
      final full = Uint8List.fromList([...id3, ...flac]);
      final meta = parseAudioHead(full, 'flac', full.length)!;
      expect(meta.title, 'FLAC 标题');
      expect(meta.artist, 'FLAC 歌手');
      expect(meta.album, 'FLAC 专辑');
      expect(meta.lyrics, 'FLAC 歌词'); // Xiph 有内容 → 不读 ID3 USLT
      expect(meta.cover, isNull); // 只认 FLAC PICTURE，不读 APIC
      expect(meta.duration, 1);
    });

    test('FLAC 无 Vorbis 条目时，文本与 USLT 按 ID3 兜底', () {
      final id3 = id3v23Tag([
        id3v23Frame('TIT2', utf8Body('ID3 标题')),
        id3v23Frame('TPE1', utf8Body('ID3 歌手')),
        id3v23Frame('TPE2', utf8Body('ID3 专辑歌手')),
        id3v23Frame('TALB', utf8Body('ID3 专辑')),
        id3v23Frame('TCON', utf8Body('Pop')),
        id3v23Frame('TYER', utf8Body('2015')),
        id3v23Frame('TRCK', utf8Body('3/12')),
        id3v23Frame('USLT', usltBody('ID3 歌词')),
        id3v23Frame('APIC', apicBody(fakeJpeg())),
      ]);
      final flac = flacHead();
      final full = Uint8List.fromList([...id3, ...flac]);
      final meta = parseAudioHead(full, 'flac', full.length)!;
      expect(meta.title, 'ID3 标题');
      expect(meta.artist, 'ID3 歌手');
      expect(meta.albumArtist, 'ID3 专辑歌手');
      expect(meta.album, 'ID3 专辑');
      expect(meta.genre, 'Pop');
      expect(meta.year, 2015);
      expect(meta.trackNo, 3);
      expect(meta.lyrics, 'ID3 歌词'); // 没有 Vorbis 标签 → 取 USLT
      expect(meta.cover, isNull); // 封面仍不取 APIC
      expect(meta.duration, 1);
    });

    test('前置 ID3 标签超过首轮采样：提示补到标签尾，readAudioMeta 阶梯读全', () async {
      // 300KB APIC → ID3 标签大于 64KB 首轮窗口，fLaC 在采样之外。
      final bigJpeg = Uint8List.fromList([
        0xFF, 0xD8,
        ...List<int>.filled(300 * 1024, 0x11),
        0xFF, 0xD9,
      ]);
      final id3 = id3v23Tag([
        id3v23Frame('TIT2', utf8Body('大标签之后')),
        id3v23Frame('APIC', apicBody(bigJpeg)),
      ]);
      final flac = flacHead(entries: ['ARTIST=阶梯歌手']);
      final full = Uint8List.fromList([...id3, ...flac]);
      const headBytes = 64 * 1024;
      final head = Uint8List.sublistView(full, 0, headBytes);
      expect(coverReadHint(head, 'flac'), id3.length + 4);

      final meta = await readAudioMeta(
        readRange: (start, length) async {
          final end = start + length > full.length ? full.length : start + length;
          return Uint8List.sublistView(full, start, end);
        },
        format: 'flac',
        fileSize: full.length,
        headBytes: headBytes,
      );
      expect(meta, isNotNull);
      expect(meta!.title, '大标签之后');
      expect(meta.artist, '阶梯歌手');
      expect(meta.duration, 1);
      expect(meta.cover, isNull);
    });
  });

  group('parseAudioHead - m4a（moov 位置）', () {
    test('moov 在文件头且大于首采：头部阶梯补读到 moov 末尾，读全标签/封面/歌词', () async {
      final cover = fakeJpeg(300 * 1024);
      final f = m4aWithFrontMoov(cover);
      const headBytes = 256 * 1024;
      expect(f.moovEnd, greaterThan(headBytes));

      final head = Uint8List.sublistView(f.bytes, 0, headBytes);
      // 首采内先解析出文本标签/歌词（截断的大封面丢弃），并标记容器不完整。
      final partial = parseAudioHead(head, 'm4a', f.bytes.length)!;
      expect(partial.title, '应徵爱');
      expect(partial.artist, '陶喆');
      expect(partial.albumArtist, '陶喆');
      expect(partial.album, '六九乐章');
      expect(partial.genre, '国语流行');
      expect(partial.year, 2009);
      expect(partial.trackNo, 11);
      expect(partial.lyrics, contains('歌词一'));
      expect(partial.cover, isNull);
      expect(partial.truncatedContainer, isTrue);

      // 头部阶梯：提示补读到 moov 末尾；不再误判为 moov-at-end 走尾扫。
      expect(coverReadHint(head, 'm4a'), f.moovEnd);
      expect(tailReadHint(head, 'm4a', f.bytes.length), isNull);

      final requests = <(int, int)>[];
      final meta = await readAudioMeta(
        readRange: (start, length) async {
          requests.add((start, length));
          final end =
              start + length > f.bytes.length ? f.bytes.length : start + length;
          return Uint8List.sublistView(f.bytes, start, end);
        },
        format: 'm4a',
        fileSize: f.bytes.length,
        headBytes: headBytes,
      );
      expect(meta, isNotNull);
      expect(meta!.title, '应徵爱');
      expect(meta.artist, '陶喆');
      expect(meta.albumArtist, '陶喆');
      expect(meta.album, '六九乐章');
      expect(meta.genre, '国语流行');
      expect(meta.year, 2009);
      expect(meta.trackNo, 11);
      expect(meta.duration, 223);
      expect(meta.lyrics, contains('歌词一'));
      expect(meta.cover, isNotNull);
      expect(meta.cover!.length, cover.length);
      expect(meta.truncatedContainer, isFalse);

      expect(requests.length, 2, reason: '首采 + 增量补读到 moov 末尾');
      expect(requests.first, (0, headBytes));
      expect(requests.last.$1, headBytes);
      expect(requests.last.$1 + requests.last.$2, f.moovEnd);
    });

    test('moov 在文件尾：仍走尾部阶梯读到标签', () async {
      final cover = fakeJpeg(100 * 1024);
      final front = m4aWithFrontMoov(cover);
      final ftypSize = _mp4BoxSize(front.bytes, 0);
      final tailMoov = Uint8List.sublistView(front.bytes, ftypSize, front.moovEnd);
      final ftyp = Uint8List.sublistView(front.bytes, 0, ftypSize);
      final mdat = mp4Box('mdat', List<int>.filled(400 * 1024, 0));
      final bytes = Uint8List.fromList([...ftyp, ...mdat, ...tailMoov]);

      final head = Uint8List.sublistView(bytes, 0, 256 * 1024);
      expect(tailReadHint(head, 'm4a', bytes.length), 256 * 1024);

      final meta = await readAudioMeta(
        readRange: (start, length) async {
          final end = start + length > bytes.length ? bytes.length : start + length;
          return Uint8List.sublistView(bytes, start, end);
        },
        format: 'm4a',
        fileSize: bytes.length,
        headBytes: 256 * 1024,
      );
      expect(meta, isNotNull);
      expect(meta!.title, '应徵爱');
      expect(meta.artist, '陶喆');
      expect(meta.duration, 223);
      expect(meta.cover, isNotNull);
    });
  });

  test('mp3 ID3 tag 声明长度超出头部采样时不越界', () {
    // 仅 ID3v2 头 10 字节，声明 tag 长度 100000，远大于实际 10 字节。
    final head = Uint8List.fromList([
      ...'ID3'.codeUnits,
      0x04,
      0x00,
      0x00,
      ...syncsafe(100000),
    ]);
    final meta = parseAudioHead(head, 'mp3', 200000);
    expect(meta, isNotNull);
  });
}
