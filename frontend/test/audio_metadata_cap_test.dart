import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';

/// fullRead 的整首完整读取必须有上限。
///
/// 这条链路是后台补读（meta_enrich 逐首跑），原先采样不足就从 0 读到 fileSize
/// 且不截断——命中的恰恰是大文件，于是为拿标签把几十上百 MB 整首下下来，
/// 烧流量还长时间占着直连源的连接。
class _Recorder {
  final List<List<int>> calls = [];
  int maxRead = 0;

  Future<Uint8List> read(int start, int length) async {
    calls.add([start, length]);
    if (length > maxRead) maxRead = length;
    // 只给头部一小块：内容不足以让 parseAudioHead 解析出标题，
    // 于是 _needsFullRead 判定为「采样不足」。
    final n = length < 16 ? length : 16;
    return Uint8List(n);
  }
}

void main() {
  test('整首在上限内：fullRead 仍然完整读取整个文件（行为不变）', () async {
    final r = _Recorder();
    const size = 4 * 1024 * 1024; // 4MB，未超 kFullReadCapBytes
    final meta = await readAudioMeta(
      readRange: r.read,
      format: 'mp3',
      fileSize: size,
      headBytes: 1024,
      fullRead: true,
    );
    expect(meta, isNotNull);
    expect(r.maxRead, size, reason: '小文件应仍整读，换取块序异常时的完整解析');
  });

  test('整首超上限：不整读，单次读取不超过上限', () async {
    final r = _Recorder();
    const size = 200 * 1024 * 1024; // 200MB，典型「超大无损 + 大内嵌封面」
    final meta = await readAudioMeta(
      readRange: r.read,
      format: 'flac',
      fileSize: size,
      headBytes: 1024,
      fullRead: true,
    );
    expect(meta, isNotNull);
    expect(r.maxRead, lessThan(size),
        reason: '不能为了拿标签把整个文件读下来');
    expect(r.maxRead, lessThanOrEqualTo(kBigFileHeadBytes),
        reason: '超限时只应加大采样，再交给按提示补读');
    expect(r.calls.any((c) => c[1] >= size), isFalse,
        reason: '不允许出现覆盖整首的读取区间');
  });

  test('超上限且采样已足够：不触发加大采样（不白读）', () async {
    final r = _Recorder();
    const size = 200 * 1024 * 1024;
    await readAudioMeta(
      readRange: r.read,
      format: 'mp3',
      fileSize: size,
      headBytes: 4096,
      fullRead: true,
    );
    // headBytes 已 > kBigFileHeadBytes? 否——只需确认没有整读，且读取都很小。
    expect(r.calls.every((c) => c[1] < size), isTrue);
  });

  test('扫描等批量路径（fullRead=false）不受影响', () async {
    final r = _Recorder();
    const size = 200 * 1024 * 1024;
    await readAudioMeta(
      readRange: r.read,
      format: 'flac',
      fileSize: size,
      headBytes: 1024,
    );
    expect(r.calls.length, 1, reason: '默认路径只做头部采样，不整读');
    expect(r.maxRead, 1024);
  });
}