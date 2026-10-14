import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/audio_metadata.dart';

/// wav / aiff / aifc 的标签读取。
///
/// 这两种容器都没有官方的标签规范：工具爱把 ID3v2 塞进一个 `id3 ` 块（RIFF/FORM
/// 的块 id 是 4 字节 ASCII；wav 块长小端，FORM 块长大端），位置也不固定——
/// ffmpeg 的 `-write_id3v2 1` 写在音频块**之后**，有些工具写在之前。旧实现只在
/// 头部找块且遇到 `data`/`SSND` 就 break，所以尾部标签与内嵌封面永远读不到，却
/// 照样把行标成了「已读」。
///
/// 关键点是**块头自带声明长度**：按它跳过音频块，就能精确算出后面元数据区的
/// 起点与长度，一次读准，不用盲扫尾部，也不用碰音频数据。

List<int> le32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
List<int> be32(int v) =>
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
Uint8List syncsafe(int v) => Uint8List.fromList([
      (v >> 21) & 0x7F,
      (v >> 14) & 0x7F,
      (v >> 7) & 0x7F,
      v & 0x7F,
    ]);

/// 最小 JPEG（签名够用即可）。
Uint8List jpeg(int bodyBytes) {
  final b = BytesBuilder();
  b.add([0xFF, 0xD8, 0xFF, 0xE0]);
  b.add(Uint8List(bodyBytes));
  b.add([0xFF, 0xD9]);
  return b.toBytes();
}

/// 带 TIT2/TPE1 + 可选 APIC 的 ID3v2.3 标签（含 10 字节头）。
/// v2.3 帧长为 BE32（标签头总长仍 syncsafe）。
Uint8List id3v2({
  String title = 'WAV 标题',
  String artist = 'WAV 歌手',
  int? imgBytes,
}) {
  List<int> frame(String id, List<int> body) =>
      [...id.codeUnits, ...be32(body.length), 0, 0, ...body];
  final frames = <int>[
    ...frame('TIT2', [3, ...utf8.encode(title)]),
    ...frame('TPE1', [3, ...utf8.encode(artist)]),
  ];
  if (imgBytes != null) {
    frames.addAll(frame('APIC', [
      0,
      ...'image/jpeg'.codeUnits,
      0,
      3,
      0,
      ...jpeg(imgBytes),
    ]));
  }
  return Uint8List.fromList([
    ...'ID3'.codeUnits,
    3, 0,
    0,
    ...syncsafe(frames.length),
    ...frames,
  ]);
}

final List<int> _fmtChunk = [
  ...'fmt '.codeUnits, 16, 0, 0, 0, // id + 块长 16
  1, 0, // PCM
  2, 0, // 双声道
  0x44, 0xAC, 0, 0, // 44100
  0xB1, 0x04, 0, 0, // 176400
  4, 0, // blockAlign
  16, 0, // bits
];

/// wav：RIFF + fmt + data + 尾随 `id3 ` 块。
///
/// [dataDeclared] 是 data 块的**声明长度**，[audioBytes] 是实际写入的音频字节。
/// 两者不等即模拟「声明长度不准的老文件」，[tailReadHint] 会因此落进音频或标签
/// 中间，需要尾部阶梯放大才能读全。
Uint8List wavWithTrailingId3({
  required int dataDeclared,
  int audioBytes = 4096,
  int tagImgBytes = 64 * 1024,
  bool zeroRiffSize = false,
}) {
  final tag = id3v2(imgBytes: tagImgBytes);
  final chunks = <int>[
    ..._fmtChunk,
    ...'data'.codeUnits,
    ...le32(dataDeclared),
    ...Uint8List(audioBytes),
    ...'id3 '.codeUnits,
    ...le32(tag.length),
    ...tag,
    // 奇数长度块体的 pad 字节（wav 要求按字对齐）
    if (tag.length.isOdd) 0,
  ];
  final body = <int>[...'WAVE'.codeUnits, ...chunks];
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    ...le32(zeroRiffSize ? 0 : body.length),
    ...body,
  ]);
}

/// aiff：FORM + COMM（80 位扩展浮点采样率）+ SSND + 尾随 `ID3 ` 块。
Uint8List aiffWithTrailingId3({
  int numSampleFrames = 441000,
  int tagImgBytes = 64 * 1024,
}) {
  final comm = <int>[
    ...'COMM'.codeUnits,
    ...be32(18),
    0, 2, // numChannels
    ...be32(numSampleFrames),
    0, 16, // sampleSize
    0x40, 0x0E, // 指数 = 16398
    0xAC, 0x44, 0, 0, 0, 0, 0, 0, // 尾数
  ];
  final ssnd = <int>[...'SSND'.codeUnits, ...be32(4096), ...Uint8List(4096)];
  final tag =
      id3v2(title: 'AIFF 标题', artist: 'AIFF 歌手', imgBytes: tagImgBytes);
  final body = <int>[
    ...'AIFF'.codeUnits,
    ...comm,
    ...ssnd,
    ...'ID3 '.codeUnits,
    ...be32(tag.length),
    ...tag,
  ];
  return Uint8List.fromList([...'FORM'.codeUnits, ...be32(body.length), ...body]);
}

/// 记录读取区间的范围读取器。
class _Recorder {
  _Recorder(this.data);
  final Uint8List data;
  final List<List<int>> calls = [];

  Future<Uint8List> read(int s, int l) async {
    calls.add([s, l]);
    final end = (s + l) > data.length ? data.length : s + l;
    return end <= s ? Uint8List(0) : Uint8List.sublistView(data, s, end);
  }
}

void main() {
  group('wav 尾随 id3 块', () {
    test('头部解析读不到尾随标签（旧实现的盲区）', () {
      final data = wavWithTrailingId3(dataDeclared: 4096);
      final head = parseAudioHead(data, 'wav', data.length)!;
      expect(head.title, isNull, reason: '标签在音频块之后，头部读不到');
      expect(head.cover, isNull);
      expect(head.duration, isNotNull, reason: 'fmt/data 给的时长仍在头部可得');
    });

    test('tailReadHint 按 data 声明长度算出尾部元数据区，且远小于音频', () {
      final data = wavWithTrailingId3(
          dataDeclared: 4 * 1024 * 1024, audioBytes: 4 * 1024 * 1024);
      final head = Uint8List.sublistView(data, 0, 4096);
      final hint = tailReadHint(head, 'wav', data.length);
      expect(hint, isNotNull);
      expect(hint, lessThan(256 * 1024),
          reason: '尾部只该覆盖 id3 块，不该把 4MB 音频也扫进来');
      expect(hint, lessThanOrEqualTo(kMetaRegionCapBytes));
    });

    test('尾读拿到标题/歌手/封面，且完全不读音频数据', () async {
      final data = wavWithTrailingId3(
          dataDeclared: 4 * 1024 * 1024, audioBytes: 4 * 1024 * 1024);
      final r = _Recorder(data);
      final meta = await readAudioMeta(
        readRange: r.read,
        format: 'wav',
        fileSize: data.length,
        headBytes: 4096,
      );
      expect(meta, isNotNull);
      expect(meta!.title, 'WAV 标题');
      expect(meta.artist, 'WAV 歌手');
      expect(meta.cover, isNotNull);
      expect(meta.cover!.sublist(0, 2), [0xFF, 0xD8]);
      expect(meta.cover!.length, greaterThan(64 * 1024 - 1024));
      // 每次读取的长度都要小于 4MB 音频块：尾读窗口只在音频块之后。
      expect(r.calls.every((c) => c[1] < 4 * 1024 * 1024), isTrue);
      expect(r.calls.every((c) => c[1] <= kMetaRegionCapBytes), isTrue);
    });

    test('data 声明长度偏大（落进标签中间）：尾读阶梯放大后读全', () async {
      // 实际音频 4KB，声明 256KB → 尾部窗口起点落进 id3 块中间，首个窗口解析
      // 必然失败，必须靠 4 倍放大把窗口撑大才能覆盖标签起点。
      final data = wavWithTrailingId3(dataDeclared: 32 * 1024, audioBytes: 4096);
      final head = Uint8List.sublistView(data, 0, 4096);
      final first = tailReadHint(head, 'wav', data.length);
      expect(first, isNotNull);
      expect(first, lessThan(128 * 1024),
          reason: '首窗口不足以覆盖标签（故意构造的错位）');
      final r = _Recorder(data);
      final meta = await readAudioMeta(
        readRange: r.read,
        format: 'wav',
        fileSize: data.length,
        headBytes: 4096,
      );
      expect(meta, isNotNull);
      expect(meta!.title, 'WAV 标题');
      expect(r.calls.length, greaterThanOrEqualTo(2),
          reason: '首窗口不够，应发生放大重试');
      expect(r.calls.every((c) => c[1] <= kMetaRegionCapBytes), isTrue);
    });

    test('RIFF 总长写 0（老设备常见）仍能按 data 声明长度定位尾部', () {
      final data =
          wavWithTrailingId3(dataDeclared: 4096, zeroRiffSize: true);
      // 尾部定位只依赖 data 块的声明长度，不依赖 RIFF 总长。
      expect(tailReadHint(Uint8List.sublistView(data, 0, 4096), 'wav',
          data.length), isNotNull);
    });

    test('尾随 LIST INFO 文本标签（无 id3 块）也能读，且不触发放大重试', () async {
      // 有些工具把 INFO 文本块写在音频块之后。这条路径只能靠块列表解析拿到——
      // 兜底扫签名只找 `id3 `，找不到 LIST INFO。
      List<int> infoChunk() {
        List<int> field(String id, String v) {
          final b = utf8.encode(v);
          return [...id.codeUnits, ...le32(b.length), ...b, if (b.length.isOdd) 0];
        }
        final body = <int>[...'INFO'.codeUnits, ...field('INAM', 'INFO 标题'), ...field('IART', 'INFO 歌手')];
        return <int>[...'LIST'.codeUnits, ...le32(body.length), ...body];
      }

      final list = infoChunk();
      final body = <int>[
        ...'WAVE'.codeUnits,
        ..._fmtChunk,
        ...'data'.codeUnits,
        ...le32(4096),
        ...Uint8List(4096),
        ...list,
      ];
      final data =
          Uint8List.fromList([...'RIFF'.codeUnits, ...le32(body.length), ...body]);
      final r = _Recorder(data);
      final meta = await readAudioMeta(
        readRange: r.read,
        format: 'wav',
        fileSize: data.length,
        headBytes: 4096,
      );
      expect(meta, isNotNull);
      expect(meta!.title, 'INFO 标题');
      expect(meta.artist, 'INFO 歌手');
      expect(r.calls.length, 2,
          reason: '首个尾窗就该读全，不该放大重试');
    });
  });

  group('aiff / aifc', () {
    test('COMM 采样率 → 时长（80 位扩展浮点解码）', () {
      final data = aiffWithTrailingId3();
      final meta = parseAudioHead(data, 'aiff', data.length)!;
      expect(meta.duration, 10); // 441000 帧 / 44100Hz
      expect(meta.sampleRate, 44100);
    });

    test('aifc 变体同样识别', () {
      final out = <int>[...aiffWithTrailingId3()];
      final p = _indexOfBytes(out, 'FORM'.codeUnits) + 8;
      out[p] = 0x41;
      out[p + 1] = 0x49;
      out[p + 2] = 0x46;
      out[p + 3] = 0x43; // 'AIFC'
      final aifc = Uint8List.fromList(out);
      expect(parseAudioHead(aifc, 'aifc', aifc.length)!.duration, 10);
    });

    test('扩展名 aif / aiff / aifc 等价', () {
      for (final f in ['aif', 'aiff', 'aifc']) {
        final data = aiffWithTrailingId3();
        expect(parseAudioHead(data, f, data.length)!.duration, 10,
            reason: 'format=$f 应识别为 AIFF');
      }
    });

    test('尾随 ID3 块 → 标题/歌手/封面，且不读音频数据', () async {
      final data = aiffWithTrailingId3();
      final head = parseAudioHead(
          Uint8List.sublistView(data, 0, 4096), 'aiff', data.length)!;
      expect(head.title, isNull, reason: 'ID3 块在 SSND 之后，头部读不到');
      final r = _Recorder(data);
      final meta = await readAudioMeta(
        readRange: r.read,
        format: 'aiff',
        fileSize: data.length,
        headBytes: 4096,
      );
      expect(meta, isNotNull);
      expect(meta!.title, 'AIFF 标题');
      expect(meta.artist, 'AIFF 歌手');
      expect(meta.cover, isNotNull);
      expect(meta.duration, 10, reason: '头部 COMM 已给时长，不该再尾读');
      // 尾读窗口应从 SSND 音频块之后开始（不是从文件头），且不覆盖整个文件。
      const ssndEnd = 46 + 4096; // SSND 块体起点 + 声明长度
      final tailCalls = r.calls.where((c) => c[0] > 0);
      expect(tailCalls, isNotEmpty, reason: '应有一次尾读');
      expect(tailCalls.every((c) => c[0] >= ssndEnd), isTrue,
          reason: '尾读起点必须落在 SSND 音频块之后');
      expect(r.calls.every((c) => c[1] < data.length), isTrue,
          reason: '不该出现覆盖整首的读取');
    });

    test('非 FORM 魔数不误报（返回空 meta 而非抛异常）', () {
      final junk = Uint8List.fromList(List.filled(64, 0x41));
      final meta = parseAudioHead(junk, 'aiff', junk.length);
      expect(meta, isNotNull);
      expect(meta!.title, isNull);
      expect(meta.duration, isNull);
      expect(tailReadHint(junk, 'aiff', junk.length), isNull);
    });
  });

  group('不误报 / 不白读', () {
    test('wav 无尾随块时 tailReadHint 为 null（不做无用尾读）', () {
      final body = <int>[
        ...'WAVE'.codeUnits,
        ..._fmtChunk,
        ...'data'.codeUnits,
        ...le32(1024),
        ...Uint8List(16),
      ];
      final out =
          Uint8List.fromList([...'RIFF'.codeUnits, ...le32(body.length), ...body]);
      expect(tailReadHint(out, 'wav', out.length), isNull);
    });

    test('data 声明长度大于文件实际大小 → 不猜尾部', () {
      final body = <int>[
        ...'WAVE'.codeUnits,
        ..._fmtChunk,
        ...'data'.codeUnits,
        ...le32(0x7FFFFFFF),
        ...Uint8List(16),
      ];
      final out =
          Uint8List.fromList([...'RIFF'.codeUnits, ...le32(body.length), ...body]);
      expect(tailReadHint(out, 'wav', out.length), isNull);
    });

    test('wav 无尾随标签时补读不发多余请求', () async {
      final body = <int>[
        ...'WAVE'.codeUnits,
        ..._fmtChunk,
        ...'data'.codeUnits,
        ...le32(4096),
        ...Uint8List(4096),
      ];
      final data =
          Uint8List.fromList([...'RIFF'.codeUnits, ...le32(body.length), ...body]);
      final r = _Recorder(data);
      final meta = await readAudioMeta(
        readRange: r.read,
        format: 'wav',
        fileSize: data.length,
        headBytes: 4096,
      );
      expect(meta, isNotNull);
      expect(meta!.duration, isNotNull);
      expect(r.calls.length, 1, reason: '一次头部采样就够，不该尾读');
    });

    test('头部就带 id3 块（标签在音频块之前）也能读到', () {
      final tag = id3v2(imgBytes: 4096);
      final body = <int>[
        ...'WAVE'.codeUnits,
        ..._fmtChunk,
        ...'id3 '.codeUnits,
        ...le32(tag.length),
        ...tag,
        ...'data'.codeUnits,
        ...le32(4096),
        ...Uint8List(4096),
      ];
      final data =
          Uint8List.fromList([...'RIFF'.codeUnits, ...le32(body.length), ...body]);
      final meta = parseAudioHead(data, 'wav', data.length)!;
      expect(meta.title, 'WAV 标题');
      expect(meta.cover, isNotNull);
    });
  });
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