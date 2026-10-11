import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';

/// 元数据补读必须「按结构定位」，绝不能整读文件。
///
/// 这条链路是播放补读 + 后台补读（meta_enrich 逐首跑）。原实现有个 `fullRead`
/// 分支：采样不足就从 0 读到 fileSize 且不截断。后台逐首跑时命中的恰恰是大
/// 文件，于是为拿几个标签把几十上百 MB 整首下下来，既烧流量又长时间占着直连源
/// 的连接。现在改为两级阶梯（结构跳 + 几何放大），一律以 kMetaRegionCapBytes
/// 封顶，且**任何情况下都不允许出现覆盖整首的读取区间**。

/// 记录每次读取区间的范围读取器（模拟 Range GET，读不满返回实际长度）。
class _Recorder {
  final List<List<int>> calls = [];
  _Recorder(this.data);

  final Uint8List data;
  int maxRead = 0;

  Future<Uint8List> read(int start, int length) async {
    calls.add([start, length]);
    if (length > maxRead) maxRead = length;
    final end = (start + length) > data.length ? data.length : start + length;
    if (end <= start) return Uint8List(0);
    return Uint8List.sublistView(data, start, end);
  }

  /// 是否出现过覆盖整个文件的读取请求。
  bool get readWholeFile =>
      calls.any((c) => c[0] == 0 && c[1] >= data.length);
}

// ---- 合成音频（与 audio_apic_test 同构）----

Uint8List _syncsafe(int v) => Uint8List.fromList([
      (v >> 21) & 0x7F,
      (v >> 14) & 0x7F,
      (v >> 7) & 0x7F,
      v & 0x7F,
    ]);

Uint8List _bigJpeg(int bodyBytes) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8, 0xFF, 0xE0]);
  b.add(Uint8List(bodyBytes));
  b.add([0xFF, 0xD9]);
  return b.toBytes();
}

/// 带 APIC 的 ID3v2.3；[imgBytes] 决定内嵌封面大小。
/// [declareTagBytes] 非空时伪造 syncsafe 声明长度（synchsafe 上限 2^28-1）。
Uint8List _id3WithApic(int imgBytes, {int? declareTagBytes}) {
  final img = _bigJpeg(imgBytes);
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
    ..._syncsafe(body.length),
    0,
    0,
    ...body,
  ];
  final declared = declareTagBytes ?? frame.length;
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    3, 0,
    0,
    ..._syncsafe(declared),
    ...frame,
    0xFF, 0xFB, 0x90, 0x00,
    ...List.filled(8192, 0),
  ]);
}

/// PICTURE 块排在 VORBIS_COMMENT 之前的 FLAC。
Uint8List _flacPictureBeforeVorbis(int imgBytes) {
  List<int> le32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
  final img = _bigJpeg(imgBytes);
  final picBody = <int>[
    0, 0, 0, 3,
    0, 0, 0, 0,
    0, 0, 0, 0,
    ...List.filled(16, 0),
    // 数据长度是大端（LE32 只用于 vorbis comment 的长度字段）
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
    for (final t in tags)
      ...[...le32(utf8.encode(t).length), ...utf8.encode(t)],
  ];
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
    0xFF, 0xF8, 0x69, 0x00, // 音频数据占位：给足 5MB，模拟真实曲库里的无损
    ...List.filled(5 * 1024 * 1024, 0),
  ]);
}

/// 第一逻辑包 payload 就超出采样的 ogg（段表全是 255 → payload 65025 字节）。
Uint8List _oggPageTooBig() {
  final b = BytesBuilder();
  // OggS 头固定 27 字节：0-3 捕获名、4 版本、5 头类型、6-13 granule、
  // 14-17 serial、18-21 页序号、22-25 CRC、26 段数。
  b.add([0x4F, 0x67, 0x67, 0x53, 0, 2]); // 'OggS' version=0 header_type=2
  b.add(List.filled(20, 0)); // granule(8) + serial(4) + seq(4) + crc(4)
  b.add([255]); // 偏移 26：段数 = 255
  b.add(List.filled(255, 255)); // 段长全 255 → payload 255*255
  b.add(Uint8List(255 * 255)); // payload
  b.add(List.filled(4 * 1024 * 1024, 0)); // 后续包/音频数据占位
  return b.toBytes();
}

void main() {
  test('mp3 大内嵌封面：按 ID3v2 声明长度精确读，不整读文件', () async {
    final data = _id3WithApic(9 * 1024 * 1024); // 9MB 封面
    final r = _Recorder(data);
    final meta = await readAudioMeta(
      readRange: r.read,
      format: 'mp3',
      fileSize: data.length,
      headBytes: 64 * 1024,
    );
    expect(meta, isNotNull);
    expect(meta!.cover, isNotNull, reason: '9MB 封面应能拿到（原 8MB 上限会丢）');
    expect(meta.cover!.length, greaterThan(9 * 1024 * 1024 - 1024));
    expect(r.readWholeFile, isFalse,
        reason: '绝不允许出现覆盖整首的读取区间');
  });

  test('flac：PICTURE 在 VORBIS_COMMENT 之前 → 几何放大补全标签与封面', () async {
    final data = _flacPictureBeforeVorbis(600 * 1024);
    final r = _Recorder(data);
    final meta = await readAudioMeta(
      readRange: r.read,
      format: 'flac',
      fileSize: data.length,
      headBytes: 8 * 1024,
    );
    expect(meta, isNotNull);
    expect(meta!.title, '曲名',
        reason: '读完封面块后标题还在更后面，必须靠放大继续够');
    expect(meta.cover, isNotNull);
    expect(r.readWholeFile, isFalse,
        reason: '原实现靠整读恢复这个 case，现在必须靠阶梯');
    expect(r.maxRead, lessThanOrEqualTo(kMetaRegionCapBytes));
  });

  test('ogg 头被截断：按 4 倍阶梯放大，而不是一次性跳到上限', () async {
    final data = _oggPageTooBig();
    final r = _Recorder(data);
    await readAudioMeta(
      readRange: r.read,
      format: 'ogg',
      fileSize: data.length,
      headBytes: 16 * 1024,
    );
    // 段表在采样内，但 payload（255*255=65025）超出 → 算不出确切位置，
    // 只能给一个放大档位。原实现在这里直接返回 kCoverReadCapBytes（当时 8MB），
    // 于是每个头被截断的 ogg 都被一次性请求上限那么大的区间。
    expect(coverReadHint(Uint8List.sublistView(data, 0, 16 * 1024), 'ogg'),
        4 * 16 * 1024);
    // 只看头部阶梯的读取（尾部阶梯会另有一次尾部读取，不能混进来数）。
    // 增量续读：首采样 16KB，随后从已读末尾续读增量（不再从 0 重下整段）。
    final headReads =
        r.calls.where((c) => c[0] + c[1] <= 4 * 16 * 1024).toList();
    expect(headReads.length, 2);
    expect(headReads[0], [0, 16 * 1024]);
    expect(headReads[1], [16 * 1024, 3 * 16 * 1024],
        reason: '从已读末尾续读到 4 倍档，而非一次性跳到上限');
    expect(headReads.every((c) => c[1] <= 4 * 16 * 1024), isTrue,
        reason: '够用即止，不该跳到 kMetaRegionCapBytes');
  });

  test('声明值异常大（伪造 256MB 标签）：封顶在 kMetaRegionCapBytes', () async {
    // 构造一个声明标签长度 256MB 的 ID3 头，但实际数据很小。
    final data = _id3WithApic(1024, declareTagBytes: 256 * 1024 * 1024);
    final r = _Recorder(data);
    await readAudioMeta(
      readRange: r.read,
      format: 'mp3',
      fileSize: 512 * 1024 * 1024, // 谎报整首 512MB
    );
    expect(r.maxRead, lessThanOrEqualTo(kMetaRegionCapBytes),
        reason: '声明值必须有合理性边界，否则损坏文件能撑爆读取与内存');
    expect(r.calls.every((c) => c[1] < 512 * 1024 * 1024), isTrue);
  });

  test('任意大小文件都不会出现整读区间（阶梯封顶的底线）', () async {
    for (final size in [5 * 1024 * 1024, 80 * 1024 * 1024]) {
      final data = _flacPictureBeforeVorbis(1024 * 1024);
      final r = _Recorder(data);
      await readAudioMeta(
        readRange: r.read,
        format: 'flac',
        fileSize: size,
        headBytes: 4096,
      );
      expect(r.calls.every((c) => c[1] < size), isTrue,
          reason: 'fileSize=$size 时出现覆盖整首的读取');
      expect(r.maxRead, lessThanOrEqualTo(kMetaRegionCapBytes));
    }
  });

  test('采样已经够用时不发额外请求（不白读）', () async {
    final data = _id3WithApic(1024);
    final r = _Recorder(data);
    final meta = await readAudioMeta(
      readRange: r.read,
      format: 'mp3',
      fileSize: data.length,
      headBytes: 64 * 1024,
    );
    expect(meta, isNotNull);
    expect(meta!.cover, isNotNull);
    expect(r.calls.length, 1, reason: '一次采样就拿到封面，不该再补读');
  });
}