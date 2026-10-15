import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';
import 'package:selfmusic/data/local/audio_tag_writer.dart';

/// 嵌入引擎测试：用 temp/ 真实文件拷贝 → 嵌入 → 自家读侧全路径回读。
///
/// 覆盖 mp3/flac/wav/aiff/m4a 五种；断言歌词+封面写入成功、标题保留、
///
/// 时长不变。另含读侧扫描兜底的大小写回归（大写 `ID3 ` + 声明扰动）。
const String _tempDir = '/home/shamiko/.vscode/project/selfmusic/temp';

/// 最小合法 JPEG（SOI + JFIF + EOI，20B，过轻量头尾校验）。
Uint8List _fakeJpeg() => Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
      0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0xFF, 0xD9,
    ]);

const String _lyrics =
    '[ti:embed-test]\n[ar:embed-test]\n[00:01.00]第一行\n[00:05.00]第二行\n';

Future<Uint8List> _rangeOf(File f, int start, int length) async {
  final raf = await f.open();
  try {
    await raf.setPosition(start);
    final out = BytesBuilder();
    var rest = length;
    while (rest > 0) {
      final c = await raf.read(rest > 65536 ? 65536 : rest);
      if (c.isEmpty) break;
      out.add(c);
      rest -= c.length;
    }
    return out.takeBytes();
  } finally {
    await raf.close();
  }
}

/// 真实全路径回读（头 + 阶梯 + 尾，与生产一致）。
Future<AudioMeta?> _readBack(String path, String format) {
  final f = File(path);
  return readAudioMeta(
    readRange: (start, length) => _rangeOf(f, start, length),
    format: format,
    fileSize: f.lengthSync(),
  );
}

Future<String> _copyToTemp(String name) async {
  final dir = await Directory.systemTemp.createTemp('selfmusic_embed_');
  final dst = '${dir.path}/$name';
  await File('$_tempDir/$name').copy(dst);
  return dst;
}

void main() {
  test('mp3 嵌入：歌词+封面，旧帧保留，时长不变', () async {
    final src = await _copyToTemp('山本希望 - キズナヒトツ (一份羁绊).mp3');
    final dst = '$src.out.mp3';
    final before = await _readBack(src, 'mp3');
    final r = await embedAudioTags(
        srcPath: src,
        dstPath: dst,
        lyrics: _lyrics,
        coverBytes: _fakeJpeg());
    expect(r.lyricsEmbedded, isTrue);
    expect(r.coverEmbedded, isTrue);
    final after = await _readBack(dst, 'mp3');
    expect(after, isNotNull);
    expect(after!.lyrics, contains('第一行'));
    expect(after.cover, isNotNull);
    expect(after.cover!.length, _fakeJpeg().length);
    expect(after.title, before!.title); // 旧帧保留
    // mp3 时长按文件大小估算：tag 体积变化带来 ±1s 舍入噪声，允许1s误差。
    expect((after.duration! - before.duration!).abs(), lessThanOrEqualTo(1));
  });

  test('flac 嵌入：LYRICS 替换+旧条目保留，时长不变', () async {
    final src = await _copyToTemp('周杰伦 - 发如雪.flac');
    final dst = '$src.out.flac';
    final before = await _readBack(src, 'flac');
    final r = await embedAudioTags(
        srcPath: src,
        dstPath: dst,
        lyrics: _lyrics,
        coverBytes: _fakeJpeg());
    expect(r.lyricsEmbedded, isTrue);
    expect(r.coverEmbedded, isTrue);
    final after = await _readBack(dst, 'flac');
    expect(after, isNotNull);
    expect(after!.lyrics, contains('第一行'));
    expect(after.cover, isNotNull);
    expect(after.artist, before!.artist); // 旧条目保留
    expect(after.album, before.album);
    expect(after.duration, before.duration);
  });

  test('wav 嵌入：尾 id3，音频区不动', () async {
    final src = await _copyToTemp('01 スタートリップ.wav');
    final dst = '$src.out.wav';
    final before = await _readBack(src, 'wav');
    final r = await embedAudioTags(
        srcPath: src,
        dstPath: dst,
        lyrics: _lyrics,
        coverBytes: _fakeJpeg());
    expect(r.lyricsEmbedded, isTrue);
    expect(r.coverEmbedded, isTrue);
    final after = await _readBack(dst, 'wav');
    expect(after, isNotNull);
    expect(after!.lyrics, contains('第一行'));
    expect(after.cover, isNotNull);
    expect(after.duration, before!.duration);
  });

  test('aiff 嵌入：大写 ID3 块，COMM 时长不变', () async {
    final src = await _copyToTemp('test-audio-aiff-16bit-44khz.aiff');
    final dst = '$src.out.aiff';
    final before = await _readBack(src, 'aiff');
    final r = await embedAudioTags(
        srcPath: src,
        dstPath: dst,
        lyrics: _lyrics,
        coverBytes: _fakeJpeg());
    expect(r.lyricsEmbedded, isTrue);
    expect(r.coverEmbedded, isTrue);
    final after = await _readBack(dst, 'aiff');
    expect(after, isNotNull);
    expect(after!.lyrics, contains('第一行'));
    expect(after.cover, isNotNull);
    expect(after.duration, before!.duration);
  });

  test('m4a 嵌入：ilst 重建，其余 item 保留', () async {
    final src = await _copyToTemp('test-audio-alac-16bit-44khz.m4a');
    final dst = '$src.out.m4a';
    final before = await _readBack(src, 'm4a');
    final r = await embedAudioTags(
        srcPath: src,
        dstPath: dst,
        lyrics: _lyrics,
        coverBytes: _fakeJpeg());
    expect(r.lyricsEmbedded, isTrue);
    expect(r.coverEmbedded, isTrue);
    final after = await _readBack(dst, 'm4a');
    expect(after, isNotNull);
    expect(after!.lyrics, contains('第一行'));
    expect(after.cover, isNotNull);
    expect(after.artist, before!.artist);
    expect(after.duration, before.duration);
  });

  test('仅歌词嵌入（无封面）：旧封面保留', () async {
    final src = await _copyToTemp('周杰伦 - 发如雪.flac');
    final dst = '$src.lyr.flac';
    final before = await _readBack(src, 'flac');
    expect(before!.cover, isNotNull); // 原文件自带封面
    final r = await embedAudioTags(srcPath: src, dstPath: dst, lyrics: _lyrics);
    expect(r.lyricsEmbedded, isTrue);
    expect(r.coverEmbedded, isFalse);
    final after = await _readBack(dst, 'flac');
    expect(after!.lyrics, contains('第一行'));
    expect(after.cover, isNotNull); // 旧封面保留
    expect(after.cover!.length, before.cover!.length);
  });

  test('扫描兜底回归：大写 ID3 + data 声明扰动仍能读到尾标签', () async {
    final src = await _copyToTemp('01 スタートリップ.wav');
    final raw = await File(src).readAsBytes();
    // 扰动 data 声明长度（-1000）：块列表走不下去，只能靠扫描兜底。
    final broken = Uint8List.fromList(raw);
    const dataOff = 84;
    final dataSize = broken[dataOff + 4] |
        (broken[dataOff + 5] << 8) |
        (broken[dataOff + 6] << 16) |
        (broken[dataOff + 7] << 24);
    final disturbed = dataSize - 1000;
    broken[dataOff + 4] = disturbed & 0xFF;
    broken[dataOff + 5] = (disturbed >> 8) & 0xFF;
    broken[dataOff + 6] = (disturbed >> 16) & 0xFF;
    broken[dataOff + 7] = (disturbed >> 24) & 0xFF;
    final dst = '$src.broken.wav';
    await File(dst).writeAsBytes(broken, flush: true);
    final meta = await _readBack(dst, 'wav');
    expect(meta, isNotNull);
    // 原文件 id3 块里有 USLT（旧歌词）：扫描兜底必须找到大写 ID3 块。
    expect(meta!.lyrics, isNotNull);
    expect(meta.lyrics!.isNotEmpty, isTrue);
  });

  test('空输入抛错：歌词封面均空', () async {
    final src = await _copyToTemp('周杰伦 - 发如雪.flac');
    expect(
      () => embedAudioTags(srcPath: src, dstPath: '$src.x.flac'),
      throwsA(isA<StateError>()),
    );
  });

  test('不支持的格式抛错', () async {
    expect(
      () => embedAudioTags(
          srcPath: '/tmp/x.opus', dstPath: '/tmp/y.opus', lyrics: 'a'),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
