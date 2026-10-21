import 'dart:convert';
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

/// 构造最小可解析 FLAC：STREAMINFO + 可选 VORBIS_COMMENT + PADDING + 伪音频。
Uint8List _flacBytes({List<String> entries = const []}) {
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
    1, 2, 3, 4, 5, 6, 7, 8,
  ]);
}

Uint8List _id3v23Frame(String id, List<int> body) => Uint8List.fromList([
      ...id.codeUnits,
      (body.length >> 24) & 0xFF,
      (body.length >> 16) & 0xFF,
      (body.length >> 8) & 0xFF,
      body.length & 0xFF,
      0,
      0,
      ...body,
    ]);

Uint8List _id3v23Tag(List<Uint8List> frames) {
  final body = <int>[];
  for (final f in frames) {
    body.addAll(f);
  }
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    0x03,
    0x00,
    0x00,
    (body.length >> 21) & 0x7F,
    (body.length >> 14) & 0x7F,
    (body.length >> 7) & 0x7F,
    body.length & 0x7F,
    ...body,
  ]);
}

List<int> _id3Utf8Body(String s) => [3, ...utf8.encode(s)];
List<int> _id3UsltBody(String s) => [3, ...'eng'.codeUnits, 0, ...utf8.encode(s)];
List<int> _id3ApicBody(Uint8List img) =>
    [3, ...'image/jpeg'.codeUnits, 0, 3, 0, ...img];

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

  test('FLAC 前置 ID3v2：读侧可读，写入后输出标准 FLAC 并迁移 APIC 封面', () async {
    final src = await _copyToTemp('林俊杰 - 独舞.flac');
    final before = await _readBack(src, 'flac');
    expect(before, isNotNull);
    expect(before!.title, '独舞');
    expect(before.artist, '林俊杰');
    expect(before.album, '和自己对话');
    expect(before.duration, isNotNull);
    // MusicPlayer2/TagLib 口径：FLAC 封面只认 PICTURE 块，不读前置 ID3 APIC。
    expect(before.cover, isNull);
    expect(before.lyrics, isNull);

    final dst = '$src.norm.flac';
    final r = await embedAudioTags(srcPath: src, dstPath: dst, lyrics: _lyrics);
    expect(r.lyricsEmbedded, isTrue);
    expect(r.coverEmbedded, isFalse);

    final file = File(dst);
    final head4 = await _rangeOf(file, 0, 4);
    final len = await file.length();
    final tail = await _rangeOf(file, len - 128, 128);
    expect(String.fromCharCodes(head4), 'fLaC'); // 无前置 ID3v2
    expect(String.fromCharCodes(tail.sublist(0, 3)), isNot('TAG')); // ID3v1 已剥离

    final after = await _readBack(dst, 'flac');
    expect(after, isNotNull);
    expect(after!.title, '独舞'); // Vorbis 文本保留
    expect(after.artist, '林俊杰');
    expect(after.album, '和自己对话');
    expect(after.albumArtist, '林俊杰');
    expect(after.year, 2015);
    expect(after.duration, before.duration);
    expect(after.lyrics, contains('第一行'));
    expect(after.cover, isNotNull); // 原 APIC 封面已转成标准 PICTURE
  });

  test('FLAC 前置 ID3v2：Vorbis 无文本时迁移 ID3 文本/USLT/APIC 后变标准 FLAC', () async {
    final dir = await Directory.systemTemp.createTemp('selfmusic_flac_id3_');
    final src = '${dir.path}/id3-prefixed.flac';
    final id3 = _id3v23Tag([
      _id3v23Frame('TIT2', _id3Utf8Body('ID3 标题')),
      _id3v23Frame('TPE1', _id3Utf8Body('ID3 歌手')),
      _id3v23Frame('TPE2', _id3Utf8Body('ID3 专辑歌手')),
      _id3v23Frame('TALB', _id3Utf8Body('ID3 专辑')),
      _id3v23Frame('TCON', _id3Utf8Body('Pop')),
      _id3v23Frame('TYER', _id3Utf8Body('2015')),
      _id3v23Frame('TRCK', _id3Utf8Body('3/12')),
      _id3v23Frame('USLT', _id3UsltBody('ID3 内嵌歌词')),
      _id3v23Frame('APIC', _id3ApicBody(_fakeJpeg())),
    ]);
    await File(src).writeAsBytes([...id3, ..._flacBytes()], flush: true);

    final before = await _readBack(src, 'flac');
    expect(before, isNotNull);
    expect(before!.title, 'ID3 标题');
    expect(before.artist, 'ID3 歌手');
    expect(before.albumArtist, 'ID3 专辑歌手');
    expect(before.album, 'ID3 专辑');
    expect(before.genre, 'Pop');
    expect(before.year, 2015);
    expect(before.trackNo, 3);
    expect(before.lyrics, 'ID3 内嵌歌词'); // 无 Vorbis 条目 → USLT 兜底
    expect(before.cover, isNull);

    // 仅写新歌词：旧文本/旧 APIC 仍需迁移，USLT 歌词被新歌词替换。
    final dst = '$src.lyrics.flac';
    final r = await embedAudioTags(srcPath: src, dstPath: dst, lyrics: _lyrics);
    expect(r.lyricsEmbedded, isTrue);
    final raw = await File(dst).readAsBytes();
    expect(String.fromCharCodes(raw.sublist(0, 4)), 'fLaC');

    final after = await _readBack(dst, 'flac');
    expect(after, isNotNull);
    expect(after!.title, 'ID3 标题');
    expect(after.artist, 'ID3 歌手');
    expect(after.albumArtist, 'ID3 专辑歌手');
    expect(after.album, 'ID3 专辑');
    expect(after.genre, 'Pop');
    expect(after.year, 2015);
    expect(after.trackNo, 3);
    expect(after.lyrics, contains('第一行'));
    expect(after.cover, isNotNull); // APIC → PICTURE
    expect(after.cover!.length, _fakeJpeg().length);

    // 仅写封面：不写新歌词时 USLT 也要迁移成 LYRICS，避免丢弃 ID3 后丢歌词。
    final dst2 = '$src.cover.flac';
    await embedAudioTags(srcPath: src, dstPath: dst2, coverBytes: _fakeJpeg());
    final after2 = await _readBack(dst2, 'flac');
    expect(after2, isNotNull);
    expect(after2!.lyrics, 'ID3 内嵌歌词');
    expect(after2.cover!.length, _fakeJpeg().length);
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
