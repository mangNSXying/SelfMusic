import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';

// ---------- 合成样本工具 ----------

List<int> be32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
List<int> le32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
List<int> le64(int v) => [...le32(v & 0xFFFFFFFF), ...le32((v >> 32) & 0xFFFFFFFF)];

Uint8List jpegBytes([int fill = 100]) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8, 0xFF, 0xE0]);
  b.add(Uint8List(fill));
  b.add([0xFF, 0xD9]);
  return b.toBytes();
}

List<int> mp4Box(List<int> type, List<int> body) =>
    [...be32(8 + body.length), ...type, ...body];

List<int> mp4Text(String type, String text) => mp4Box(type.codeUnits,
    mp4Box('data'.codeUnits, [...be32(1), 0, 0, 0, 0, ...utf8.encode(text)]));

List<int> mp4DataBox(int dataType, List<int> payload) =>
    mp4Box('data'.codeUnits, [...be32(dataType), 0, 0, 0, 0, ...payload]);

/// 最小可解析 m4a：moov(mvhd + udta/meta/ilst)（可指定 moov 位置）。
Uint8List m4aBytes({bool moovAtEnd = false}) {
  final ftyp = mp4Box('ftyp'.codeUnits, [...'M4A '.codeUnits, ...be32(0)]);
  final mvhd = mp4Box('mvhd'.codeUnits, [
    0, 0, 0, 0, // version/flags
    ...be32(0), ...be32(0), // creation/modification
    ...be32(1000), ...be32(180000), // timescale, duration → 180s
  ]);
  final ilst = mp4Box('ilst'.codeUnits, [
    ...mp4Text('©nam', 'M4A 标题'),
    ...mp4Text('©ART', 'M4A 歌手'),
    ...mp4Text('aART', 'M4A 专辑歌手'),
    ...mp4Text('©alb', 'M4A 专辑'),
    ...mp4Text('©day', '2019-05-01'),
    ...mp4Box('trkn'.codeUnits, mp4DataBox(0, [0, 0, 0, 7, 0, 12, 0, 0])),
    ...mp4Box('covr'.codeUnits, mp4DataBox(13, jpegBytes(200))),
  ]);
  final meta = mp4Box('meta'.codeUnits, [0, 0, 0, 0, ...ilst]);
  final udta = mp4Box('udta'.codeUnits, [...meta]);
  final moov = mp4Box('moov'.codeUnits, [...mvhd, ...udta]);
  if (!moovAtEnd) return Uint8List.fromList([...ftyp, ...moov, ...mp4Box('mdat'.codeUnits, List.filled(64, 0))]);
  final mdat = mp4Box('mdat'.codeUnits, List.filled(300000, 0));
  return Uint8List.fromList([...ftyp, ...mdat, ...moov]);
}

/// Vorbis comment 条目（LE 长度前缀）。
List<int> vorbisComment(List<String> entries, {List<int>? vendor}) {
  final v = vendor ?? 'test'.codeUnits;
  final b = <int>[...le32(v.length), ...v, ...le32(entries.length)];
  for (final e in entries) {
    final bytes = utf8.encode(e);
    b.addAll([...le32(bytes.length), ...bytes]);
  }
  return b;
}

/// FLAC PICTURE 块体（METADATA_BLOCK_PICTURE 编码用）。
List<int> flacPictureBlock(Uint8List img) => [
      0, 0, 0, 3,
      0, 0, 0, 0,
      0, 0, 0, 0,
      ...List.filled(16, 0),
      ...be32(img.length),
      ...img,
    ];

List<int> oggPage({
  required int seq,
  required List<int> packet,
  required int granule,
  bool continued = false,
}) {
  final lacing = <int>[];
  var rest = packet.length;
  while (rest >= 255) {
    lacing.add(255);
    rest -= 255;
  }
  lacing.add(rest);
  return [
    ...'OggS'.codeUnits,
    0, // version
    continued ? 1 : 0, // flags
    ...le64(granule),
    ...le32(1), ...le32(seq), ...le32(0), // serial, seq, crc
    lacing.length, ...lacing, ...packet,
  ];
}

/// 最小 Ogg Vorbis：ID 页 + comment 页 + 末页（granule=秒*采样率）。
/// [tailPad] 在 comment 与末页之间填充字节，模拟音频数据。
Uint8List oggBytes(
    {int seconds = 123,
    int tailPad = 0,
    bool withPicture = true,
    int pictureBytes = 300}) {
  final id = <int>[
    0x01, ...'vorbis'.codeUnits,
    ...le32(0), 2, ...le32(44100), ...le32(0), ...le32(0), ...le32(0), 0xB8, 0x01,
  ];
  final entries = <String>['TITLE=Ogg 标题', 'ARTIST=Ogg 歌手', 'ALBUM=Ogg 专辑'];
  if (withPicture) {
    entries.add(
        'METADATA_BLOCK_PICTURE=${base64Encode(flacPictureBlock(jpegBytes(pictureBytes)))}');
  }
  final comment = <int>[
    0x03, ...'vorbis'.codeUnits, ...vorbisComment(entries),
  ];
  return Uint8List.fromList([
    ...oggPage(seq: 0, packet: id, granule: 0),
    ...oggPage(seq: 1, packet: comment, granule: 0),
    ...List.filled(tailPad, 0xAA),
    ...oggPage(seq: 2, packet: [0x00], granule: 44100 * seconds),
  ]);
}

Uint8List wavBytes() {
  const dataSize = 1764000; // 176400 B/s × 10s
  List<int> chunk(String id, List<int> body) {
    final size = body.length;
    return [...id.codeUnits, ...le32(size), ...body, if (size.isOdd) 0];
  }

  final fmt = chunk('fmt ', [
    1, 0, // PCM
    2, 0, // channels
    ...le32(44100),
    ...le32(176400),
    4, 0, 16, 0,
  ]);
  final data = chunk('data', List.filled(64, 0));
  final list = chunk('LIST', [
    ...'INFO'.codeUnits,
    ...chunk('INAM', utf8.encode('Wav 标题')),
    ...chunk('IART', utf8.encode('Wav 歌手')),
    ...chunk('IPRD', utf8.encode('Wav 专辑')),
  ]);
  final body = [...'WAVE'.codeUnits, ...fmt, ...list, ...data];
  // data 块声明完整大小（文件本体只放少量字节，时长按声明计算）。
  final withRealSize = <int>[
    ...le32(dataSize),
  ];
  // 找到 data 块体大小字段位置并覆写为 dataSize。
  final out = <int>[...'RIFF'.codeUnits, ...le32(4 + body.length), ...body];
  final p = _indexOfBytes(out, 'data'.codeUnits);
  for (var i = 0; i < 4; i++) {
    out[p + 4 + i] = withRealSize[i];
  }
  return Uint8List.fromList(out);
}

int _indexOfBytes(List<int> b, List<int> pat) {
  for (var i = 0; i + pat.length <= b.length; i++) {
    var ok = true;
    for (var j = 0; j < pat.length; j++) {
      if (b[i + j] != pat[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

Uint8List aacBytes() {
  // ID3v2 头（TIT2）+ 一个 ADTS 帧头（44100Hz、帧长 400）。
  final titleBody = <int>[3, ...utf8.encode('AAC 标题')];
  final frame = <int>[
    ...'TIT2'.codeUnits,
    (titleBody.length >> 21) & 0x7F, (titleBody.length >> 14) & 0x7F,
    (titleBody.length >> 7) & 0x7F, titleBody.length & 0x7F,
    0, 0, ...titleBody,
  ];
  final tag = <int>[
    ...'ID3'.codeUnits, 4, 0, 0,
    (frame.length >> 21) & 0x7F, (frame.length >> 14) & 0x7F,
    (frame.length >> 7) & 0x7F, frame.length & 0x7F,
    ...frame,
  ];
  // ADTS: 0xFFF, MPEG-4, SR index 4 (44100), chConfig 2, frame length 400
  const frameLen = 400;
  final adts = <int>[
    0xFF, 0xF1,
    (1 << 6) | (4 << 2) | (0 << 1) | ((2 >> 2) & 1),
    ((2 & 3) << 6) | ((frameLen >> 11) & 0x03),
    (frameLen >> 3) & 0xFF,
    ((frameLen & 0x07) << 5) | 0x1F,
    0xFC,
    ...List.filled(20, 0),
  ];
  return Uint8List.fromList([...tag, ...adts]);
}

Future<Uint8List> Function(int, int) readerOf(Uint8List bytes) {
  return (int start, int length) async {
    final end = (start + length).clamp(0, bytes.length);
    if (start >= bytes.length) return Uint8List(0);
    return Uint8List.sublistView(bytes, start, end);
  };
}

void main() {
  group('m4a', () {
    test('moov 在头部：标题/歌手/专辑歌手/专辑/年份/曲目/封面/时长', () {
      final meta = parseAudioHead(m4aBytes(), 'm4a', 999)!;
      expect(meta.title, 'M4A 标题');
      expect(meta.artist, 'M4A 歌手');
      expect(meta.albumArtist, 'M4A 专辑歌手');
      expect(meta.album, 'M4A 专辑');
      expect(meta.year, 2019);
      expect(meta.trackNo, 7);
      expect(meta.duration, 180);
      expect(meta.cover, isNotNull);
      expect(meta.cover!.sublist(0, 2), [0xFF, 0xD8]);
    });

    test('moov-at-end：尾读提示 + readAudioMeta 自动补读', () async {
      final bytes = m4aBytes(moovAtEnd: true);
      final headLen = bytes.length < 256 * 1024 ? bytes.length : 256 * 1024;
      final head = Uint8List.sublistView(bytes, 0, headLen);
      expect(coverReadHint(head, 'm4a'), isNull);
      expect(tailReadHint(head, 'm4a', bytes.length), 256 * 1024);
      final meta = (await readAudioMeta(
          readRange: readerOf(bytes), format: 'm4a', fileSize: bytes.length))!;
      expect(meta.title, 'M4A 标题');
      expect(meta.duration, 180);
      expect(meta.cover, isNotNull);
    });
  });

  group('ogg/opus', () {
    test('头部解析标题/歌手/专辑/封面（base64 METADATA_BLOCK_PICTURE）', () {
      final meta = parseAudioHead(oggBytes(), 'ogg', 9999)!;
      expect(meta.title, 'Ogg 标题');
      expect(meta.artist, 'Ogg 歌手');
      expect(meta.album, 'Ogg 专辑');
      expect(meta.cover, isNotNull);
      expect(meta.sampleRate, 44100);
    });

    test('时长：末页 granule / 采样率（readAudioMeta 尾读）', () async {
      final bytes = oggBytes(seconds: 123);
      final meta = (await readAudioMeta(
          readRange: readerOf(bytes), format: 'ogg', fileSize: bytes.length))!;
      expect(meta.title, 'Ogg 标题');
      expect(meta.duration, 123);
    });

    test('comment 无封面时 cover 为空（不误报）', () {
      final meta = parseAudioHead(oggBytes(withPicture: false), 'ogg', 9999)!;
      expect(meta.title, 'Ogg 标题');
      expect(meta.cover, isNull);
    });

    test('超大 comment 包（封面 > 首段采样）：按几何阶梯补读', () async {
      final bytes = oggBytes(withPicture: true, pictureBytes: 40 * 1024);
      expect(bytes.length, greaterThan(50 * 1024));
      // 头部只读 1KB → comment 包截断，段表算不出确切位置：给一个 4 倍档位。
      // 原实现在这里直接返回 kCoverReadCapBytes（当时 8MB），于是每个头被截断的
      // ogg 都被一次性请求上限那么大的区间。
      final head = Uint8List.sublistView(bytes, 0, 1024);
      expect(coverReadHint(head, 'ogg'), 4096);
      final meta = (await readAudioMeta(
        readRange: readerOf(bytes),
        format: 'ogg',
        fileSize: bytes.length,
        headBytes: 1024,
      ))!;
      expect(meta.title, 'Ogg 标题');
      expect(meta.cover, isNotNull);
    });

    test('ID3v1 兜底（无 ID3v2 的老 mp3）', () async {
      List<int> padded(String s, int len) {
        final b = utf8.encode(s);
        return [...b.take(len), ...List.filled(len - b.length, 0)];
      }

      final v1 = <int>[
        ...'TAG'.codeUnits,
        ...padded('老歌名', 30),
        ...padded('老歌手', 30),
        ...padded('老专辑', 30),
        ...padded('1999', 4),
        ...padded('', 28), 0, 42, 1, // comment + track 42 + genre 1
      ];
      final bytes = Uint8List.fromList([
        0xFF, 0xFB, 0x90, 0x00, ...List.filled(500, 0x55), ...v1,
      ]);
      final head = Uint8List.sublistView(bytes, 0, 256);
      expect(coverReadHint(head, 'mp3'), isNull);
      expect(tailReadHint(head, 'mp3', bytes.length), 128);
      final meta = (await readAudioMeta(
          readRange: readerOf(bytes), format: 'mp3', fileSize: bytes.length))!;
      expect(meta.title, '老歌名');
      expect(meta.artist, '老歌手');
      expect(meta.album, '老专辑');
      expect(meta.year, 1999);
      expect(meta.trackNo, 42);
    });
  });

  group('wav', () {
    test('LIST INFO 标签 + data 时长', () {
      final meta = parseAudioHead(wavBytes(), 'wav', 9999)!;
      expect(meta.title, 'Wav 标题');
      expect(meta.artist, 'Wav 歌手');
      expect(meta.album, 'Wav 专辑');
      expect(meta.duration, 10);
    });
  });

  group('aac', () {
    test('ID3 标签 + ADTS 时长估算', () {
      final bytes = aacBytes();
      final meta = parseAudioHead(bytes, 'aac', 3 * 1024 * 1024)!;
      expect(meta.title, 'AAC 标题');
      // 400B/帧 × 8000 × 44100 / 1024 ≈ 137.8kbps → 3MB ≈ 22s
      expect(meta.duration, inInclusiveRange(15, 30));
    });
  });

  test('未识别容器返回 null（调用方走文件名/目录回退）', () {
    expect(parseAudioHead(Uint8List.fromList(List.filled(64, 0x11)), 'xyz', 1),
        isNull);
  });
}
