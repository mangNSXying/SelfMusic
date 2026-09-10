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
      final fileSize = tag.length + 100_000; // pretend payload beyond head
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
  });
}
