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
}
