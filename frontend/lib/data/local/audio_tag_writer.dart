/// 音频标签内嵌写入（纯 Dart，无第三方库、无服务端参与）。
///
/// 与 [audio_metadata] 的读口径镜像：只替换歌词与封面，其余帧/块/item 原样
/// 保留；音频区全程流式搬运（不整文件进内存，大文件同样可用）。
/// 写入策略（原型已用 temp/ 5 种文件 + mutagen/ffprobe/自家读侧三方验证）：
/// - mp3：重建头部 ID3v2（版本保持 v2.3/v2.4，帧体一律 UTF-8；v2.2 拒绝改写）；
/// - flac：重建元数据块（STREAMINFO 保留，VORBIS_COMMENT 合并 LYRICS，
///   类型 3 PICTURE 替换，其余块保留，末块置 last 位）；
/// - wav/aiff：删除既有 `ID3 ` 块（`LIST INFO` 等不动），尾部追加新块
///   （统一大写 `ID3 `，与 mutagen AIFF 口径对齐），修正容器总长；
/// - m4a：重建 `ilst`（©lyr/covr 替换，其余 item 保留），尺寸上卷
///   ilst→meta→udta→moov；moov 在尾直接改尾，moov 在前则移位后续数据并修
///   stco/co64 全体 entry。
///
/// 调用方负责 tmp+rename（本函数只写 [dstPath]，崩溃半文件由调用方清理）；
/// 写完必须用读侧重读验签（标题/时长非空 + 封面完整性），通过后再覆盖源文件。
library;

import 'dart:convert' show utf8;
import 'dart:io';
import 'dart:typed_data';

import 'audio_metadata.dart'
    show isCompleteImageBytes, kMetaRegionCapBytes;

/// 单次流式搬运块（I/O 交错让出事件循环，大文件不卡主线程过久）。
const int _kCopyChunkBytes = 1024 * 1024;

/// 嵌入结果。
class TagEmbedResult {
  final String format;
  final bool lyricsEmbedded;
  final bool coverEmbedded;
  final int newSize;
  const TagEmbedResult({
    required this.format,
    required this.lyricsEmbedded,
    required this.coverEmbedded,
    required this.newSize,
  });
}

/// 把 [srcPath] 的歌词/封面改写后写入 [dstPath]（两路径必须不同）。
///
/// [lyrics]/[coverBytes] 至少其一非空；封面须通过 [isCompleteImageBytes]。
/// 不支持的容器/版本抛 [UnsupportedError]，内容非法抛 [StateError]。
Future<TagEmbedResult> embedAudioTags({
  required String srcPath,
  required String dstPath,
  String? lyrics,
  Uint8List? coverBytes,
  String? format,
}) async {
  final lyric = lyrics?.trim();
  Uint8List? cover = coverBytes;
  if ((lyric == null || lyric.isEmpty) && (cover == null || cover.isEmpty)) {
    throw StateError('歌词与封面均为空，不嵌入');
  }
  if (cover != null && cover.isNotEmpty && !isCompleteImageBytes(cover)) {
    throw StateError('封面字节不完整（疑似截断/非图片），拒绝嵌入');
  }
  final fmt = (format ??
          srcPath.substring(srcPath.lastIndexOf('.') + 1).toLowerCase())
      .toLowerCase();
  switch (fmt) {
    case 'mp3':
      return _embedMp3(srcPath, dstPath, lyric, cover);
    case 'flac':
      return _embedFlac(srcPath, dstPath, lyric, cover);
    case 'wav':
      return _embedRiff(srcPath, dstPath, lyric, cover, be: false);
    case 'aiff':
    case 'aif':
    case 'aifc':
      return _embedRiff(srcPath, dstPath, lyric, cover, be: true);
    case 'm4a':
    case 'mp4':
      return _embedM4a(srcPath, dstPath, lyric, cover);
    default:
      throw UnsupportedError('不支持内嵌的格式：$fmt');
  }
}

// ---------- 小工具 ----------

Uint8List _syncsafeEncode(int n) => Uint8List.fromList([
      (n >> 21) & 0x7F,
      (n >> 14) & 0x7F,
      (n >> 7) & 0x7F,
      n & 0x7F
    ]);

int _syncsafeDecode(List<int> b, int o) =>
    ((b[o] & 0x7F) << 21) |
    ((b[o + 1] & 0x7F) << 14) |
    ((b[o + 2] & 0x7F) << 7) |
    (b[o + 3] & 0x7F);

int _be32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _le32u(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

void _patchBe32(Uint8List b, int o, int v) {
  b[o] = (v >> 24) & 0xFF;
  b[o + 1] = (v >> 16) & 0xFF;
  b[o + 2] = (v >> 8) & 0xFF;
  b[o + 3] = v & 0xFF;
}

/// 流式搬运 [src] 的 [start, start+length) 到 [sink]（length<0 表示到文件尾）。
Future<void> _pipeRange(
    RandomAccessFile src, IOSink sink, int start, int length) async {
  await src.setPosition(start);
  var rest = length;
  while (rest != 0) {
    final n = rest < 0 ? _kCopyChunkBytes : (rest < _kCopyChunkBytes ? rest : _kCopyChunkBytes);
    final chunk = await src.read(n);
    if (chunk.isEmpty) break;
    sink.add(chunk);
    if (rest > 0) rest -= chunk.length;
  }
}

/// APIC/covr/PICTURE 的 mime 判定（读侧验签已过，这里只做类型映射）。
String _coverMime(Uint8List img) {
  if (img.length >= 2 && img[0] == 0xFF && img[1] == 0xD8) {
    return 'image/jpeg';
  }
  if (img.length >= 4 &&
      img[0] == 0x89 &&
      img[1] == 0x50 &&
      img[2] == 0x4E &&
      img[3] == 0x47) {
    return 'image/png';
  }
  if (img.length >= 3 &&
      img[0] == 0x47 &&
      img[1] == 0x49 &&
      img[2] == 0x46) {
    return 'image/gif';
  }
  if (img.length >= 12 &&
      img[0] == 0x52 &&
      img[1] == 0x49 &&
      img[8] == 0x57 &&
      img[9] == 0x45 &&
      img[10] == 0x42 &&
      img[11] == 0x50) {
    return 'image/webp';
  }
  throw StateError('不支持的封面图片类型（仅 jpeg/png/gif/webp）');
}

// ---------- ID3v2 共用 ----------

class _Id3Frame {
  final String id;
  final Uint8List body;
  _Id3Frame(this.id, this.body);
}

class _Id3Tag {
  final int major;
  final int flags; // 仅保留 footer 位，其余重建时清零
  final Uint8List extBytes;
  final List<_Id3Frame> frames;
  _Id3Tag(this.major, this.flags, this.extBytes, this.frames);
}

/// 解析既有 ID3v2 tag（v2.2 直接抛不支持；帧体长度按版本口径）。
_Id3Tag? _parseId3Tag(Uint8List tag) {
  if (tag.length < 10 ||
      tag[0] != 0x49 ||
      tag[1] != 0x44 ||
      tag[2] != 0x33) {
    return null;
  }
  final major = tag[3];
  if (major == 2) throw UnsupportedError('ID3v2.2 不支持改写');
  if (major != 3 && major != 4) return null;
  final flags = tag[5];
  final size = _syncsafeDecode(tag, 6);
  if (10 + size > tag.length) return null;
  var p = 10;
  Uint8List ext = Uint8List(0);
  if ((flags & 0x40) != 0) {
    if (major == 4) {
      final esz = _syncsafeDecode(tag, p);
      if (esz < 6 || p + 4 + esz > tag.length) return null;
      ext = Uint8List.sublistView(tag, p, p + 4 + esz);
      p += 4 + esz;
    } else {
      final esz = _be32(tag, p);
      if (esz < 6 || p + 4 + esz > tag.length) return null;
      ext = Uint8List.sublistView(tag, p, p + 4 + esz);
      p += 4 + esz;
    }
  }
  final v4 = major == 4;
  final frames = <_Id3Frame>[];
  final end = 10 + size;
  while (p + 10 <= end) {
    // 与读侧 [_id3TagToFrames] 同口径：仅 padding/空终止走，否则一律按帧头
    // 跳过（未知帧也保留，绝不丢帧）。
    if (tag[p] == 0) break; // padding
    final id = String.fromCharCodes(tag.sublist(p, p + 4)).trim();
    if (id.isEmpty || id.codeUnitAt(0) == 0) break;
    final fsize = v4 ? _syncsafeDecode(tag, p + 4) : _be32(tag, p + 4);
    if (fsize < 0 || p + 10 + fsize > end) break;
    frames.add(_Id3Frame(
        id, Uint8List.sublistView(tag, p + 10, p + 10 + fsize)));
    p += 10 + fsize;
  }
  return _Id3Tag(major, flags & 0x10, Uint8List.fromList(ext), frames);
}

Uint8List _usltFrameBody(String lyrics) => Uint8List.fromList([
      0x03, // UTF-8
      ...'eng'.codeUnits, // language
      0x00, // 空描述
      ...utf8.encode(lyrics),
    ]);

Uint8List _apicFrameBody(Uint8List img, String mime) => Uint8List.fromList([
      0x03, // UTF-8
      ...mime.codeUnits, 0x00, // mime
      0x03, // type: front cover
      0x00, // 空描述
      ...img,
    ]);

Uint8List _buildId3Frame(String id, Uint8List body, bool v4) {
  final out = BytesBuilder();
  out.add(id.codeUnits);
  out.add(v4 ? _syncsafeEncode(body.length) : _be32Bytes(body.length));
  out.add([0x00, 0x00]); // flags
  out.add(body);
  return out.takeBytes();
}

Uint8List _be32Bytes(int v) => Uint8List.fromList(
    [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);

/// 组装完整 tag（含 512B padding；footer 位保留时补尾）。
Uint8List _buildId3Tag(
    int major, int flags, Uint8List ext, List<_Id3Frame> frames) {
  final v4 = major == 4;
  final out = BytesBuilder();
  out.add(ext);
  for (final f in frames) {
    out.add(_buildId3Frame(f.id, f.body, v4));
  }
  out.add(Uint8List(512)); // padding
  final body = out.takeBytes();
  final hdr = BytesBuilder();
  hdr.add([0x49, 0x44, 0x33, major, 0x00, flags]);
  hdr.add(_syncsafeEncode(body.length));
  final tag = BytesBuilder()
    ..add(hdr.takeBytes())
    ..add(body);
  if ((flags & 0x10) != 0) {
    tag.add([0x33, 0x44, 0x49, major, 0x00, flags]);
    tag.add(_syncsafeEncode(body.length));
  }
  return tag.takeBytes();
}

// ---------- MP3 ----------

Future<TagEmbedResult> _embedMp3(
    String src, String dst, String? lyrics, Uint8List? cover) async {
  final srcFile = File(src);
  final raf = await srcFile.open();
  int audioStart = 0;
  _Id3Tag? old;
  try {
    final hdr = await raf.read(10);
    if (hdr.length == 10 &&
        hdr[0] == 0x49 &&
        hdr[1] == 0x44 &&
        hdr[2] == 0x33) {
      if (hdr[3] == 2) throw UnsupportedError('ID3v2.2 不支持改写');
      if (hdr[3] != 3 && hdr[3] != 4) {
        throw StateError('未知 ID3 版本 v2.${hdr[3]}，拒绝改写');
      }
      final size = _syncsafeDecode(hdr, 6);
      if (size < 0 || size > kMetaRegionCapBytes) {
        throw StateError('ID3 声明长度异常（$size），拒绝改写');
      }
      await raf.setPosition(0);
      final tagBytes = await raf.read(10 + size);
      if (tagBytes.length < 10 + size) {
        throw StateError('ID3 tag 被截断，拒绝改写');
      }
      old = _parseId3Tag(Uint8List.fromList(tagBytes));
      if (old == null) throw StateError('ID3 解析失败，拒绝改写');
      audioStart = 10 + size;
    }
  } finally {
    await raf.close();
  }
  final major = old?.major ?? 3; // 无 tag 时默认写 v2.3（兼容车机）
  final kept = [
    for (final f in (old?.frames ?? const <_Id3Frame>[]))
      if (f.id != 'USLT' && f.id != 'APIC') f,
  ];
  var lyricOk = false, coverOk = false;
  if (lyrics != null && lyrics.isNotEmpty) {
    kept.add(_Id3Frame('USLT', _usltFrameBody(lyrics)));
    lyricOk = true;
  } else if (old != null) {
    kept.addAll([
      for (final f in old.frames)
        if (f.id == 'USLT') f,
    ]);
  }
  if (cover != null && cover.isNotEmpty) {
    kept.add(_Id3Frame('APIC', _apicFrameBody(cover, _coverMime(cover))));
    coverOk = true;
  } else if (old != null) {
    kept.addAll([
      for (final f in old.frames)
        if (f.id == 'APIC') f,
    ]);
  }
  final tag = _buildId3Tag(major, old?.flags ?? 0, old?.extBytes ?? Uint8List(0), kept);
  final inRaf = await srcFile.open();
  final outSink = File(dst).openWrite();
  try {
    outSink.add(tag);
    await _pipeRange(inRaf, outSink, audioStart, -1);
  } finally {
    await inRaf.close();
    await outSink.close();
  }
  return TagEmbedResult(
      format: 'mp3',
      lyricsEmbedded: lyricOk,
      coverEmbedded: coverOk,
      newSize: tag.length + await srcFile.length() - audioStart);
}

// ---------- FLAC ----------

({Uint8List vendor, List<Uint8List> entries}) _parseVorbisBlock(
    Uint8List body) {
  var p = 0;
  int u32() {
    final v = body[p] |
        (body[p + 1] << 8) |
        (body[p + 2] << 16) |
        (body[p + 3] << 24);
    p += 4;
    return v;
  }

  final vlen = u32();
  if (vlen < 0 || 4 + vlen > body.length) throw StateError('VORBIS vendor 越界');
  final vendor = Uint8List.sublistView(body, 4, 4 + vlen);
  p = 4 + vlen;
  final n = u32();
  if (n < 0 || n > 4096) throw StateError('VORBIS 条目数异常（$n）');
  final entries = <Uint8List>[];
  for (var k = 0; k < n; k++) {
    if (p + 4 > body.length) throw StateError('VORBIS 条目截断');
    final ln = u32();
    if (ln < 0 || p + ln > body.length) throw StateError('VORBIS 条目越界');
    entries.add(Uint8List.sublistView(body, p, p + ln));
    p += ln;
  }
  return (vendor: Uint8List.fromList(vendor), entries: entries);
}

Uint8List _buildVorbisBlock(Uint8List vendor, List<Uint8List> entries) {
  final out = BytesBuilder();
  void u32(int v) => out.add(
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  u32(vendor.length);
  out.add(vendor);
  u32(entries.length);
  for (final e in entries) {
    u32(e.length);
    out.add(e);
  }
  return out.takeBytes();
}

Uint8List _buildFlacPicture(Uint8List img, String mime) {
  final out = BytesBuilder();
  void u32(int v) => out.add(
      [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]);
  u32(3); // front cover
  u32(mime.length);
  out.add(mime.codeUnits);
  u32(0); // 空描述
  out.add([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]); // w/h/depth/colors
  u32(img.length);
  out.add(img);
  return out.takeBytes();
}

/// PICTURE 块类型（解析失败返回 -1，调用方按“非封面”保留）。
int _flacPictureType(Uint8List body) {
  try {
    if (body.length < 8) return -1;
    final type = _be32(body, 0);
    var p = 4;
    final ml = _be32(body, p);
    p += 4 + ml;
    final dl = _be32(body, p);
    p += 4 + dl + 16;
    if (p + 4 > body.length) return -1;
    return type;
  } catch (_) {
    return -1;
  }
}

bool _isLyricKey(Uint8List entry) {
  var key = '';
  try {
    final s = utf8.decode(entry, allowMalformed: true);
    final eq = s.indexOf('=');
    if (eq <= 0) return false;
    key = s.substring(0, eq).trim().toUpperCase();
  } catch (_) {
    return false;
  }
  return key == 'LYRICS' ||
      key == 'UNSYNCEDLYRICS' ||
      key == 'UNSYNCED LYRICS' ||
      key == 'LYRIC';
}

Future<TagEmbedResult> _embedFlac(
    String src, String dst, String? lyrics, Uint8List? cover) async {
  final raf = await File(src).open();
  final magic = await raf.read(4);
  if (magic.length < 4 ||
      magic[0] != 0x66 ||
      magic[1] != 0x4C ||
      magic[2] != 0x61 ||
      magic[3] != 0x43) {
    await raf.close();
    throw StateError('不是 FLAC 文件');
  }
  final types = <int>[];
  final bodies = <Uint8List>[];
  var metaTotal = 4;
  var last = false;
  while (!last) {
    final h = await raf.read(4);
    if (h.length < 4) {
      await raf.close();
      throw StateError('FLAC 元数据块截断');
    }
    last = (h[0] & 0x80) != 0;
    final type = h[0] & 0x7F;
    final len = (h[1] << 16) | (h[2] << 8) | h[3];
    if (len < 0 || metaTotal + 4 + len > kMetaRegionCapBytes) {
      await raf.close();
      throw StateError('FLAC 元数据块过大（$len），拒绝改写');
    }
    final body = await raf.read(len);
    if (body.length < len) {
      await raf.close();
      throw StateError('FLAC 元数据块截断');
    }
    types.add(type);
    bodies.add(Uint8List.fromList(body));
    metaTotal += 4 + len;
  }
  final audioStart = metaTotal;
  await raf.close();
  if (!types.contains(0)) throw StateError('FLAC 缺少 STREAMINFO');

  Uint8List? streaminfo;
  Uint8List vendor = Uint8List.fromList(' PrototypeEmbed'.codeUnits);
  List<Uint8List> vcEntries = [];
  var sawVc = false;
  final keptOthers = <MapEntry<int, Uint8List>>[];
  var lyricOk = false, coverOk = false;
  for (var i = 0; i < types.length; i++) {
    final t = types[i], b = bodies[i];
    if (t == 0) {
      streaminfo = b;
    } else if (t == 4) {
      final vc = _parseVorbisBlock(b);
      vendor = vc.vendor;
      vcEntries = vc.entries;
      sawVc = true;
    } else if (t == 6) {
      final pt = _flacPictureType(b);
      if (cover != null && cover.isNotEmpty && pt == 3) {
        continue; // 旧封面图丢弃（下面重建）
      }
      keptOthers.add(MapEntry(t, b));
    } else if (t == 1) {
      continue; // PADDING 丢弃（重建时补小 padding）
    } else {
      keptOthers.add(MapEntry(t, b));
    }
  }
  final newEntries = <Uint8List>[];
  if (lyrics != null && lyrics.isNotEmpty) {
    for (final e in vcEntries) {
      if (!_isLyricKey(e)) newEntries.add(e);
    }
    newEntries.add(Uint8List.fromList(utf8.encode('LYRICS=$lyrics')));
    lyricOk = true;
  } else {
    newEntries.addAll(vcEntries);
  }
  if (cover != null && cover.isNotEmpty) {
    coverOk = true;
  }
  final seq = <MapEntry<int, Uint8List>>[
    MapEntry(0, streaminfo!),
    if (sawVc || lyricOk)
      MapEntry(4, _buildVorbisBlock(vendor, newEntries)),
    if (cover != null && cover.isNotEmpty)
      MapEntry(6, _buildFlacPicture(cover, _coverMime(cover))),
    ...keptOthers,
    MapEntry(1, Uint8List(1024)),
  ];
  final out = BytesBuilder()..add([0x66, 0x4C, 0x61, 0x43]);
  for (var i = 0; i < seq.length; i++) {
    final t = seq[i].key, b = seq[i].value;
    out.add([(i == seq.length - 1 ? 0x80 : 0) | t,
        (b.length >> 16) & 0xFF, (b.length >> 8) & 0xFF, b.length & 0xFF]);
    out.add(b);
  }
  final meta = out.takeBytes();
  final inRaf = await File(src).open();
  final outSink = File(dst).openWrite();
  var newSize = meta.length;
  try {
    outSink.add(meta);
    await _pipeRange(inRaf, outSink, audioStart, -1);
    newSize += await File(src).length() - audioStart;
  } finally {
    await inRaf.close();
    await outSink.close();
  }
  return TagEmbedResult(
      format: 'flac',
      lyricsEmbedded: lyricOk,
      coverEmbedded: coverOk,
      newSize: newSize);
}

// ---------- WAV / AIFF ----------

class _RiffChunk {
  final Uint8List id;
  final int size;
  final Uint8List? body; // 音频块为 null（流式搬运）
  final int fileOffset;
  _RiffChunk(this.id, this.size, this.body, this.fileOffset);
}

Future<TagEmbedResult> _embedRiff(
    String src, String dst, String? lyrics, Uint8List? cover,
    {required bool be}) async {
  final raf = await File(src).open();
  final fileLen = await raf.length();
  final hdr = await raf.read(12);
  await raf.close();
  if (hdr.length < 12) throw StateError('文件过小');
  final magic = String.fromCharCodes(hdr.sublist(0, 4));
  final kind = String.fromCharCodes(hdr.sublist(8, 12));
  final okMagic = (!be && magic == 'RIFF' && kind == 'WAVE') ||
      (be && magic == 'FORM' && (kind == 'AIFF' || kind == 'AIFC'));
  if (!okMagic) throw StateError('不是 ${be ? 'AIFF' : 'WAV'} 文件');
  int sizeAt(int o, Uint8List b) => be ? _be32(b, o) : _le32u(b, o);

  // 第一遍：走块列表（块体缓冲，音频块只记位置；上限保护）。
  final chunks = <_RiffChunk>[];
  var pos = 12;
  var buffered = 0;
  final inRaf = await File(src).open();
  try {
    while (true) {
      await inRaf.setPosition(pos);
      final h = await inRaf.read(8);
      if (h.length < 8) break; // 文件结束
      final id = Uint8List.fromList(h.sublist(0, 4));
      final idStr = String.fromCharCodes(id);
      final sz = sizeAt(0, Uint8List.fromList(h.sublist(4, 8)));
      if (sz < 0 || pos + 8 + sz > fileLen) break; // 截断：剩余原样保留
      final isAudio =
          (!be && idStr == 'data') || (be && idStr == 'SSND');
      if (isAudio) {
        chunks.add(_RiffChunk(id, sz, null, pos));
      } else {
        if (buffered + sz > kMetaRegionCapBytes) {
          throw StateError('非音频块过大（$idStr $sz），拒绝改写');
        }
        final body = await inRaf.read(sz);
        if (body.length < sz) break;
        buffered += sz;
        chunks.add(_RiffChunk(id, sz, Uint8List.fromList(body), pos));
      }
      pos += 8 + sz + (sz & 1);
    }
    final tailStart = pos; // 已解析末端（截断残留起点）
    // 旧 ID3 块解析（文本帧沿用）
    final kept = <_Id3Frame>[];
    for (final c in chunks) {
      final idStr = String.fromCharCodes(c.id);
      if ((idStr == 'id3 ' || idStr == 'ID3 ') && c.body != null) {
        final tag = _parseId3Tag(c.body!);
        if (tag != null) {
          kept.addAll([
            for (final f in tag.frames)
              if (f.id != 'USLT' && f.id != 'APIC') f,
          ]);
        }
      }
    }
    var lyricOk = false, coverOk = false;
    if (lyrics != null && lyrics.isNotEmpty) {
      kept.add(_Id3Frame('USLT', _usltFrameBody(lyrics)));
      lyricOk = true;
    }
    if (cover != null && cover.isNotEmpty) {
      kept.add(_Id3Frame('APIC', _apicFrameBody(cover, _coverMime(cover))));
      coverOk = true;
    }
    // RIFF/AIFF 块统一写 ID3v2.3（大写 `ID3 ` 块名，与 mutagen AIFF 对齐）。
    final tag = _buildId3Tag(3, 0, Uint8List(0), kept);
    final newId3 = BytesBuilder()
      ..add('ID3 '.codeUnits)
      ..add(be ? _be32Bytes(tag.length) : _le32Bytes(tag.length))
      ..add(tag);
    if (tag.length & 1 != 0) newId3.add([0]);
    final newId3Bytes = newId3.takeBytes();

    // 总长预计算（头部 12 + 各块 + 新块 + 截断残留）
    var total = 12;
    for (final c in chunks) {
      final idStr = String.fromCharCodes(c.id);
      if (idStr == 'id3 ' || idStr == 'ID3 ') continue; // 旧块删除
      total += 8 + c.size + (c.size & 1);
    }
    total += newId3Bytes.length + (fileLen - tailStart);
    final outSink = File(dst).openWrite();
    try {
      outSink.add(hdr.sublist(0, 4));
      final totalBytes = be ? _be32Bytes(total - 8) : _le32Bytes(total - 8);
      outSink.add(totalBytes);
      outSink.add(hdr.sublist(8, 12));
      for (final c in chunks) {
        final idStr = String.fromCharCodes(c.id);
        if (idStr == 'id3 ' || idStr == 'ID3 ') continue;
        outSink.add(c.id);
        outSink.add(be ? _be32Bytes(c.size) : _le32Bytes(c.size));
        if (c.body != null) {
          outSink.add(c.body!);
          if (c.size & 1 != 0) outSink.add([0]);
        } else {
          await _pipeRange(inRaf, outSink, c.fileOffset + 8, c.size);
          if (c.size & 1 != 0) outSink.add([0]);
        }
      }
      outSink.add(newId3Bytes);
      if (tailStart < fileLen) {
        await _pipeRange(inRaf, outSink, tailStart, fileLen - tailStart);
      }
    } finally {
      await outSink.close();
    }
    return TagEmbedResult(
        format: be ? 'aiff' : 'wav',
        lyricsEmbedded: lyricOk,
        coverEmbedded: coverOk,
        newSize: total);
  } finally {
    await inRaf.close();
  }
}

Uint8List _le32Bytes(int v) => Uint8List.fromList(
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

// ---------- M4A ----------

class _Box {
  final String type;
  final int offset;
  final int size;
  final int header;
  _Box(this.type, this.offset, this.size, this.header);
  int get bodyStart => offset + header;
  int get end => offset + size;
}

List<_Box> _mp4Boxes(Uint8List b, int start, int end) {
  final out = <_Box>[];
  var i = start;
  while (i + 8 <= end) {
    var size = _be32(b, i);
    final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
    var header = 8;
    if (size == 1) {
      if (i + 16 > end) break;
      size = (_be32(b, i + 8) << 32) | _be32(b, i + 12);
      header = 16;
    } else if (size == 0) {
      size = end - i;
    }
    if (size < header || i + size > end) break;
    out.add(_Box(type, i, size, header));
    i += size;
  }
  return out;
}

_Box? _findBox(Uint8List b, int start, int end, String type) {
  for (final box in _mp4Boxes(b, start, end)) {
    if (box.type == type) return box;
  }
  return null;
}

Uint8List _mp4DataBox(Uint8List payload, int datatype) {
  final out = BytesBuilder();
  out.add(_be32Bytes(8 + 8 + payload.length));
  out.add('data'.codeUnits);
  out.add(_be32Bytes(datatype));
  out.add(_be32Bytes(0)); // locale
  out.add(payload);
  return out.takeBytes();
}

Uint8List _mp4Item(String type, Uint8List inner) {
  final out = BytesBuilder();
  out.add(_be32Bytes(8 + inner.length));
  out.add(type.codeUnits);
  out.add(inner);
  return out.takeBytes();
}

/// moov 缓冲内递归修 stco（v0）/co64 全体 entry（moov 在前且尺寸变化时）。
int _fixStco(Uint8List moov, int delta) {
  var fixed = 0;
  void walk(int start, int end) {
    for (final box in _mp4Boxes(moov, start, end)) {
      if (box.type == 'stco') {
        if (moov[box.bodyStart] != 0) {
          throw StateError('stco version 非 0，拒绝改写');
        }
        final n = _be32(moov, box.bodyStart + 4);
        var p = box.bodyStart + 8;
        for (var k = 0; k < n; k++) {
          if (p + 4 > box.end) throw StateError('stco 越界');
          _patchBe32(moov, p, _be32(moov, p) + delta);
          p += 4;
        }
        fixed += n;
      } else if (box.type == 'co64') {
        if (moov[box.bodyStart] != 0) {
          throw StateError('co64 version 非 0，拒绝改写');
        }
        final n = _be32(moov, box.bodyStart + 4);
        var p = box.bodyStart + 8;
        for (var k = 0; k < n; k++) {
          if (p + 8 > box.end) throw StateError('co64 越界');
          final v = (_be32(moov, p) << 32) | _be32(moov, p + 4);
          final nv = v + delta;
          _patchBe32(moov, p, (nv >> 32) & 0xFFFFFFFF);
          _patchBe32(moov, p + 4, nv & 0xFFFFFFFF);
          p += 8;
        }
        fixed += n;
      } else if (box.type == 'moov' ||
          box.type == 'trak' ||
          box.type == 'mdia' ||
          box.type == 'minf' ||
          box.type == 'stbl' ||
          box.type == 'udta') {
        walk(box.bodyStart, box.end);
      } else if (box.type == 'meta') {
        walk(box.bodyStart + 4, box.end); // fullbox 头 4B
      }
    }
  }

  walk(0, moov.length);
  return fixed;
}

Future<TagEmbedResult> _embedM4a(
    String src, String dst, String? lyrics, Uint8List? cover) async {
  if (cover != null && cover.isNotEmpty) {
    final m = _coverMime(cover);
    if (m != 'image/jpeg' && m != 'image/png') {
      throw StateError('m4a 封面仅支持 jpeg/png（covr 无此类型）');
    }
  }
  final raf = await File(src).open();
  final fileLen = await raf.length();
  // 顶层走盒：定位 moov（只读头，不缓冲 mdat）。
  var pos = 0;
  int moovStart = -1, moovSize = -1;
  try {
    while (pos + 8 <= fileLen) {
      await raf.setPosition(pos);
      final h = await raf.read(8);
      if (h.length < 8) break;
      var size = _be32(h, 0);
      final type = String.fromCharCodes(h.sublist(4, 8));
      var header = 8;
      if (size == 1) {
        final xh = await raf.read(8);
        if (xh.length < 8) break;
        size = (_be32(xh, 0) << 32) | _be32(xh, 4);
        header = 16;
      } else if (size == 0) {
        size = fileLen - pos;
      }
      if (size < header || pos + size > fileLen) break;
      if (type == 'moov') {
        if (size > kMetaRegionCapBytes) {
          throw StateError('moov 过大（$size），拒绝改写');
        }
        moovStart = pos;
        moovSize = size;
        break;
      }
      pos += size;
    }
    if (moovStart < 0) throw StateError('找不到 moov');
    await raf.setPosition(moovStart);
    final moovRaw = await raf.read(moovSize);
    if (moovRaw.length < moovSize) throw StateError('moov 截断');
    final moov = Uint8List.fromList(moovRaw);
    final udta = _findBox(moov, 8, moov.length, 'udta');
    if (udta == null) throw StateError('moov 无 udta，拒绝改写');
    if (udta.header != 8) throw UnsupportedError('largesize udta 不支持');
    final meta = _findBox(moov, udta.bodyStart, udta.end, 'meta');
    if (meta == null || meta.header != 8) {
      throw StateError('udta 无 meta（或 largesize），拒绝改写');
    }
    final ilst =
        _findBox(moov, meta.bodyStart + 4, meta.end, 'ilst');
    if (ilst == null || ilst.header != 8) {
      throw StateError('meta 无 ilst（或 largesize），拒绝改写');
    }
    final items = _mp4Boxes(moov, ilst.bodyStart, ilst.end);
    final dropLyric = lyrics != null && lyrics.isNotEmpty;
    final dropCover = cover != null && cover.isNotEmpty;
    final kept = <Uint8List>[];
    for (final it in items) {
      if (it.header != 8) throw UnsupportedError('largesize item 不支持');
      if (dropLyric && it.type == '©lyr') continue;
      if (dropCover && it.type == 'covr') continue;
      kept.add(Uint8List.sublistView(moov, it.offset, it.end));
    }
    var lyricOk = false, coverOk = false;
    final lyricText =
        (lyrics != null && lyrics.isNotEmpty) ? lyrics : null;
    final coverImg =
        (cover != null && cover.isNotEmpty) ? cover : null;
    if (lyricText != null) {
      kept.add(Uint8List.fromList(_mp4Item(
          '©lyr', _mp4DataBox(Uint8List.fromList(utf8.encode(lyricText)), 1))));
      lyricOk = true;
    }
    if (coverImg != null) {
      final dt = _coverMime(coverImg) == 'image/png' ? 14 : 13;
      kept.add(Uint8List.fromList(_mp4Item('covr', _mp4DataBox(coverImg, dt))));
      coverOk = true;
    }
    final ilstBodyLen = kept.fold<int>(0, (a, b) => a + b.length);
    final newIlstSize = 8 + ilstBodyLen;
    final delta = newIlstSize - ilst.size;
    // 组装新 moov：原样拷贝 + 替换 ilst 段 + 回填三级 size。
    final out = BytesBuilder();
    out.add(moov.sublist(0, ilst.offset));
    out.add(_be32Bytes(newIlstSize));
    out.add('ilst'.codeUnits);
    for (final k in kept) {
      out.add(k);
    }
    out.add(moov.sublist(ilst.end));
    final newMoov = Uint8List.fromList(out.takeBytes());
    _patchBe32(newMoov, ilst.offset, newIlstSize);
    _patchBe32(newMoov, meta.offset, meta.size + delta);
    _patchBe32(newMoov, udta.offset, udta.size + delta);
    _patchBe32(newMoov, 0, moovSize + delta);
    final tailStart = moovStart + moovSize;
    if (tailStart < fileLen && delta != 0) {
      _fixStco(newMoov, delta); // moov 在前：移位后续数据，修 chunk 偏移
    }
    final outSink = File(dst).openWrite();
    try {
      await _pipeRange(raf, outSink, 0, moovStart);
      outSink.add(newMoov);
      if (tailStart < fileLen) {
        await _pipeRange(raf, outSink, tailStart, fileLen - tailStart);
      }
    } finally {
      await outSink.close();
    }
    return TagEmbedResult(
        format: 'm4a',
        lyricsEmbedded: lyricOk,
        coverEmbedded: coverOk,
        newSize: fileLen + delta);
  } finally {
    await raf.close();
  }
}
