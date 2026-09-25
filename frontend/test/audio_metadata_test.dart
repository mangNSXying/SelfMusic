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
    0,
    ...body,
  ]);
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
