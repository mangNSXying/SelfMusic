import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';

Uint8List syncsafe(int v) => Uint8List.fromList([
      (v >> 21) & 0x7F,
      (v >> 14) & 0x7F,
      (v >> 7) & 0x7F,
      v & 0x7F,
    ]);

/// 最小 JPEG 字节（签名 + 结束标记 + 填充，足够签名校验）。
final jpeg = Uint8List.fromList(
    [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6, 7, 0xFF, 0xD9]);

/// 大体积伪 JPEG（0xE0 段后全是填充），用于验证超采样长度的封面读取。
Uint8List bigJpeg(int bodyBytes) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8, 0xFF, 0xE0]);
  b.add(Uint8List(bodyBytes));
  b.add([0xFF, 0xD9]);
  return b.toBytes();
}

/// 构造带 APIC 的 ID3v2.3 头部（encoding=1 UTF-16 描述，BOM 前缀）。
Uint8List id3WithApic({required int enc, required List<int> descBytes}) {
  final body = <int>[
    enc,
    ...'image/jpeg'.codeUnits,
    0, // mime 终止
    3, // 图片类型
    ...descBytes,
    ...jpeg,
  ];
  final frame = <int>[
    ...'APIC'.codeUnits,
    ...syncsafe(body.length),
    0,
    0,
    ...body,
  ];
  final tagSize = frame.length;
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    3, 0, // v2.3
    0, // flags
    ...syncsafe(tagSize),
    ...frame,
  ]);
}

/// 构造带超大 APIC 的 ID3v2.3 头（enc=0），用于截断/两段读测试。
Uint8List id3WithLargeApic({required int imgBytes}) {
  final img = bigJpeg(imgBytes);
  final body = <int>[
    0,
    ...'image/jpeg'.codeUnits,
    0,
    3,
    0,
    ...img,
  ];
  final frame = <int>[
    ...'APIC'.codeUnits,
    ...syncsafe(body.length),
    0,
    0,
    ...body,
  ];
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    3, 0,
    0,
    ...syncsafe(frame.length),
    ...frame,
    // 一个 MPEG 帧头 + 载荷占位（模拟音频数据）
    0xFF, 0xFB, 0x90, 0x00,
  ]);
}

/// 构造 PICTURE 在 VORBIS_COMMENT 之前的 FLAC（块序非标准但合法）：
/// 封面块被采样截断时，旧解析会在 PICTURE 处中断，读不到其后的标题/歌手。
Uint8List flacPictureBeforeVorbis() {
  List<int> le32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
  final img = bigJpeg(600 * 1024);
  final picBody = <int>[
    0, 0, 0, 3, // 图片类型
    0, 0, 0, 0, // mime 长度 0
    0, 0, 0, 0, // 描述长度 0
    ...List.filled(16, 0), // 宽/高/色深/色数占位
    (img.length >> 24) & 0xFF,
    (img.length >> 16) & 0xFF,
    (img.length >> 8) & 0xFF,
    img.length & 0xFF,
    ...img,
  ];
  final streamInfo = <int>[0, 0, 0, 34, ...List.filled(34, 0)];
  final picture = <int>[
    6,
    (picBody.length >> 16) & 0xFF,
    (picBody.length >> 8) & 0xFF,
    picBody.length & 0xFF,
    ...picBody,
  ];
  const vendor = 'test';
  final tags = ['TITLE=曲名', 'ARTIST=歌手'];
  final vorbisBody = <int>[
    ...le32(vendor.length),
    ...vendor.codeUnits,
    ...le32(tags.length),
    for (final t in tags) ...[...le32(utf8.encode(t).length), ...utf8.encode(t)],
  ];
  // VORBIS_COMMENT 为最后一个元数据块（last 位）。
  final vorbis = <int>[
    0x80 | 4,
    (vorbisBody.length >> 16) & 0xFF,
    (vorbisBody.length >> 8) & 0xFF,
    vorbisBody.length & 0xFF,
    ...vorbisBody,
  ];
  return Uint8List.fromList([
    ...'fLaC'.codeUnits,
    ...streamInfo,
    ...picture,
    ...vorbis,
    0xFF, 0xF8, 0x69, 0x00, // 音频数据占位：给足 5MB，避免「读完元数据区」
    ...List.filled(5 * 1024 * 1024, 0), // 恰好等于整读，掩盖住无谓的整读
  ]);
}

void main() {
  test('APIC：UTF-16 描述（BOM + 00 00 终止）不应把描述字节当成封面', () {
    // BOM FF FE + "cover" UTF-16LE + 00 00 终止
    final desc = <int>[
      0xFF, 0xFE,
      ...'cover'.codeUnits.expand((c) => [c, 0]),
      0, 0,
    ];
    final head = id3WithApic(enc: 1, descBytes: desc);
    final meta = parseAudioHead(head, 'mp3', head.length);
    expect(meta, isNotNull);
    expect(meta!.cover, isNotNull);
    // 封面必须以 JPEG 签名开头（此前 bug 会以描述残留 0x6F 开头）。
    expect(meta.cover!.sublist(0, 2), [0xFF, 0xD8]);
  });

  test('APIC：UTF-16BE 描述（enc=2）同样正确跳过', () {
    final desc = <int>[
      ...'c'.codeUnits.expand((c) => [0, c]),
      ...'over'.codeUnits.expand((c) => [0, c]),
      0, 0,
    ];
    final head = id3WithApic(enc: 2, descBytes: desc);
    final meta = parseAudioHead(head, 'mp3', head.length);
    expect(meta?.cover?.sublist(0, 2), [0xFF, 0xD8]);
  });

  test('APIC：latin1 描述（enc=0）保持原行为', () {
    final desc = <int>[...'cover'.codeUnits, 0];
    final head = id3WithApic(enc: 0, descBytes: desc);
    final meta = parseAudioHead(head, 'mp3', head.length);
    expect(meta?.cover?.sublist(0, 2), [0xFF, 0xD8]);
  });

  test('APIC：mime 为 --> 的 URL 链接不当作封面字节', () {
    final body = <int>[
      0,
      ...'-->'.codeUnits,
      0,
      3,
      0, // 空描述
      ...'https://example.com/cover.jpg'.codeUnits,
    ];
    final frame = <int>[...'APIC'.codeUnits, ...syncsafe(body.length), 0, 0, ...body];
    final head = Uint8List.fromList([
      ...'ID3'.codeUnits,
      3, 0,
      0,
      ...syncsafe(frame.length),
      ...frame,
    ]);
    final meta = parseAudioHead(head, 'mp3', head.length);
    expect(meta?.cover, isNull);
  });

  group('coverReadHint - 大内嵌封面两段读', () {
    test('mp3：标签被采样截断时提示补读长度；完整标签返回 null', () {
      final full = id3WithLargeApic(imgBytes: 400 * 1024);
      final declared = 10 + syncsafeInt(full, 6);
      final truncated = Uint8List.sublistView(full, 0, 256 * 1024);
      expect(coverReadHint(truncated, 'mp3'), declared);
      expect(coverReadHint(full, 'mp3'), isNull);
    });

    test('mp3：400KB 封面经两段读可完整解析', () {
      final full = id3WithLargeApic(imgBytes: 400 * 1024);
      final truncated = Uint8List.sublistView(full, 0, 256 * 1024);
      // 一段读：封面丢失
      expect(parseAudioHead(truncated, 'mp3', full.length)?.cover, isNull);
      // 二段读（按提示读取完整标签）：封面恢复
      final hint = coverReadHint(truncated, 'mp3')!;
      expect(hint, greaterThan(256 * 1024));
      expect(hint, lessThanOrEqualTo(kMetaRegionCapBytes));
      final deeper = Uint8List.sublistView(full, 0, hint);
      final meta = parseAudioHead(deeper, 'mp3', full.length);
      expect(meta?.cover, isNotNull);
      expect(meta!.cover!.sublist(0, 2), [0xFF, 0xD8]);
      expect(meta.cover!.length, greaterThan(400 * 1024));
    });

    test('mp3：9MB 封面正常恢复（元数据区上限 16MB，不再有 8MB 丢封面）', () async {
      final full = id3WithLargeApic(imgBytes: 9 * 1024 * 1024);
      final lengths = <int>[];
      Future<Uint8List> range(int s, int l) async {
        lengths.add(l);
        return Uint8List.sublistView(
            full, s, (s + l) > full.length ? full.length : s + l);
      }
      // 原行为：默认路径封面被 8MB 上限截断丢弃，只有播放链路的 fullRead 能拿到。
      // 现在两条链路都是同一个结构化读取，9MB 封面一样拿得到。
      final meta = await readAudioMeta(
          readRange: range, format: 'mp3', fileSize: full.length);
      expect(meta, isNotNull);
      expect(meta!.cover, isNotNull);
      expect(meta.cover!.sublist(0, 2), [0xFF, 0xD8]);
      expect(meta.cover!.length, greaterThan(9 * 1024 * 1024 - 1024));
      expect(lengths.every((l) => l <= kMetaRegionCapBytes), isTrue);
    });

    test('flac：PICTURE 在 VORBIS_COMMENT 之前被采样截断 → 结构阶梯恢复（不整读）', () async {
      final full = flacPictureBeforeVorbis();
      final lengths = <int>[];
      Future<Uint8List> range(int s, int l) async {
        lengths.add(l);
        final end = (s + l) > full.length ? full.length : s + l;
        return Uint8List.sublistView(full, s, end);
      }
      // 采样（256KB）内封面块未读完：其后的 VORBIS_COMMENT 标题/歌手读不到。
      final sample = Uint8List.sublistView(full, 0, 256 * 1024);
      final sampled = parseAudioHead(sample, 'flac', full.length);
      expect(sampled?.title, isNull);
      expect(sampled?.cover, isNull);
      // 现在靠结构阶梯恢复：跳到 PICTURE 声明的块尾，再放大够到其后的
      // VORBIS_COMMENT——全程不出现覆盖整首的读取区间。
      final meta = await readAudioMeta(
          readRange: range, format: 'flac', fileSize: full.length);
      expect(meta, isNotNull);
      expect(meta!.title, '曲名');
      expect(meta.artist, '歌手');
      expect(meta.cover, isNotNull);
      expect(meta.cover!.sublist(0, 2), [0xFF, 0xD8]);
      expect(lengths.every((l) => l < full.length), isTrue,
          reason: '不能为了拿标签把整个文件读下来');
      expect(lengths.length, greaterThanOrEqualTo(2));
    });

    test('flac：PICTURE 块被截断时提示块尾；完整后返回 null', () {
      final img = bigJpeg(300 * 1024);
      final picBody = <int>[
        0, 0, 0, 3, // 大端图片类型
        0, 0, 0, 0, // mime 长度 0
        0, 0, 0, 0, // 描述长度 0
        ...List.filled(16, 0), // 宽/高/色深/色数占位
        (img.length >> 24) & 0xFF,
        (img.length >> 16) & 0xFF,
        (img.length >> 8) & 0xFF,
        img.length & 0xFF,
        ...img,
      ];
      final picHeader = <int>[
        0x80 | 6, // PICTURE，带 last 位：块列表到此结束
        (picBody.length >> 16) & 0xFF,
        (picBody.length >> 8) & 0xFF,
        picBody.length & 0xFF,
      ];
      final streamInfo = <int>[
        0, // STREAMINFO，非最后块
        0, 0, 34,
        ...List.filled(34, 0),
      ];
      final flac = Uint8List.fromList([
        ...'fLaC'.codeUnits,
        ...streamInfo,
        ...picHeader,
        ...picBody,
      ]);
      final picEnd = 4 + streamInfo.length + 4 + picBody.length;
      final truncated = Uint8List.sublistView(flac, 0, 256 * 1024);
      expect(coverReadHint(truncated, 'flac'), picEnd);
      final deeper = Uint8List.sublistView(flac, 0, picEnd);
      expect(coverReadHint(deeper, 'flac'), isNull,
          reason: '走到 last 块 = 元数据区完整，不该再提示补读');
      final meta = parseAudioHead(deeper, 'flac', flac.length);
      expect(meta?.cover, isNotNull);
    });

    test('无 ID3/fLaC 魔数时返回 null（不误报补读）', () {
      final junk = Uint8List.fromList(List.filled(100, 0x55));
      expect(coverReadHint(junk, 'mp3'), isNull);
      expect(coverReadHint(junk, 'flac'), isNull);
    });
  });
}

/// 从 ID3 头读取 syncsafe 标签长度（测试断言用）。
int syncsafeInt(Uint8List b, int o) =>
    ((b[o] & 0x7F) << 21) |
    ((b[o + 1] & 0x7F) << 14) |
    ((b[o + 2] & 0x7F) << 7) |
    (b[o + 3] & 0x7F);
