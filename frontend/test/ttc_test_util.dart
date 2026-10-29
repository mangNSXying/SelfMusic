import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// 取 Flutter 自带 MaterialIcons OTF 作为真实 sfnt 字节，避免测试依赖系统字体。
Future<Uint8List> loadMaterialIconsOtf() async {
  final data = await rootBundle.load('fonts/MaterialIcons-Regular.otf');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// 把独立 sfnt 包成 TTC：头部若干字面偏移全部指向同一份字面目录，
/// 并把该目录内的表偏移整体后移，模拟 TTC 的「表偏移以集合文件起点为基准」。
Uint8List buildTtcFromSfnt(Uint8List sfnt, {int faceCount = 1}) {
  assert(faceCount > 0);
  final source = ByteData.sublistView(sfnt);
  final numTables = source.getUint16(4);
  final headerLength = 12 + 4 * faceCount;
  final out = Uint8List(headerLength + sfnt.length);
  out.setRange(headerLength, out.length, sfnt);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, 0x74746366);
  bd.setUint32(4, 0x00010000);
  bd.setUint32(8, faceCount);
  for (var i = 0; i < faceCount; i++) {
    bd.setUint32(12 + 4 * i, headerLength);
  }
  for (var i = 0; i < numTables; i++) {
    final recordOffset = headerLength + 12 + 16 * i + 8;
    bd.setUint32(recordOffset, bd.getUint32(recordOffset) + headerLength);
  }
  return out;
}
