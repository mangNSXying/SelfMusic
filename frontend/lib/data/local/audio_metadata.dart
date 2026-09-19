import 'dart:convert' show utf8;
import 'dart:typed_data';

/// 音频头部元数据（来自扫描时的 Range 头部直读，DESIGN §6.4）。
class AudioMeta {
  String? title;
  String? artist;
  String? album;
  String? genre;
  int? year;
  int? trackNo;
  int? duration; // 秒
  Uint8List? cover; // 嵌入封面原始字节（jpg/png）
}

/// 纯 Dart 头部解析：mp3(ID3v2) 与 flac。m4a 走文件名回退。
///
/// [head] 为文件头部字节（扫描时取 ~256KB），[format] 为扩展名，[fileSize] 为完整大小。
AudioMeta? parseAudioHead(Uint8List head, String format, int fileSize) {
  switch (format) {
    case 'mp3':
      return _parseMp3(head, fileSize);
    case 'flac':
      return _parseFlac(head, fileSize);
    default:
      return null; // m4a/aac/ogg/wav 走文件名回退
  }
}

/// 最小元数据解析：仅 标题/歌手/专辑（DESIGN §6.4 快速扫描）。
///
/// 不解析时长、曲目、年份、流派、封面，因此头部采样可更小、下载量最小；
/// 其余元数据在播放时由 [parseAudioHead] 懒补全（enrich）。
AudioMeta? parseMinimalHead(Uint8List head, String format) {
  switch (format) {
    case 'mp3':
      return _parseMp3Minimal(head);
    case 'flac':
      return _parseFlacMinimal(head);
    default:
      return null; // m4a/aac/ogg/wav 走文件名回退
  }
}

// ---------- MP3 最小解析 ----------

AudioMeta _parseMp3Minimal(Uint8List head) {
  final meta = AudioMeta();
  if (head.length >= 10 && String.fromCharCodes(head.sublist(0, 3)) == 'ID3') {
    final frames = _id3TagToFrames(head, 10);
    meta.title = frames['TIT2'];
    meta.artist = frames['TPE1'];
    meta.album = frames['TALB'];
  }
  return meta;
}

// ---------- FLAC 最小解析 ----------

AudioMeta _parseFlacMinimal(Uint8List head) {
  final meta = AudioMeta();
  if (head.length < 4 || String.fromCharCodes(head.sublist(0, 4)) != 'fLaC') {
    return meta;
  }
  var i = 4;
  bool last = false;
  while (!last && i + 4 <= head.length) {
    final hdr = head[i];
    last = (hdr & 0x80) != 0;
    final blockType = hdr & 0x7F;
    final len = _be24(head, i + 1);
    if (i + 4 + len > head.length) break;
    final body = head.sublist(i + 4, i + 4 + len);
    // 只取 VORBIS_COMMENT（标题/歌手/专辑所在地）；STREAMINFO/PICTURE 跳过。
    if (blockType == 4) _parseVorbisComment(body, meta);
    i += 4 + len;
  }
  return meta;
}

// ---------- MP3 (ID3v2) ----------

AudioMeta _parseMp3(Uint8List head, int fileSize) {
  final meta = AudioMeta();
  int offset = 0;
  if (head.length >= 10 && String.fromCharCodes(head.sublist(0, 3)) == 'ID3') {
    final frames = _id3TagToFrames(head, 10);
    meta.title = frames['TIT2'];
    meta.artist = frames['TPE1'];
    meta.album = frames['TALB'];
    meta.genre = frames['TCON'];
    meta.year = _yearOf(frames['TYER'] ?? frames['TDRC']);
    meta.trackNo = _trackOf(frames['TRCK']);
    meta.cover = _apicOf(head);
    final sz = _syncsafe(head, 6);
    offset = 10 + sz;
  }
  meta.duration = _mp3Duration(head, offset, fileSize);
  return meta;
}

/// 解析整个 ID3 tag 里的所有帧（含 APIC 从 [head] 中提取）。
Map<String, String> _id3TagToFrames(Uint8List head, int tagStart) {
  final out = <String, String>{};
  var i = tagStart;
  // 头部采样可能短于 ID3 tag 声明长度（如内嵌封面很大），以实际字节数为界，
  // 避免 sublist 越界抛 RangeError。
  final declared = tagStart + _syncsafe(head, 6);
  final limit = declared < head.length ? declared : head.length;
  while (i + 10 <= limit) {
    final id = String.fromCharCodes(head.sublist(i, i + 4)).trim();
    if (id.isEmpty || id.codeUnitAt(0) == 0) break;
    final size = _syncsafe(head, i + 4);
    if (size < 0 || i + 10 + size > head.length || i + 10 + size > limit) break;
    if (id == 'APIC') {
      // 交由 _apicOf 处理；这里跳过
    } else if (!out.containsKey(id)) {
      final v = _decodeText(head.sublist(i + 10, i + 10 + size));
      if (v.isNotEmpty) out[id] = v;
    }
    i += 10 + size;
  }
  return out;
}

Uint8List? _apicOf(Uint8List head) {
  var i = 10;
  final limit = 10 + _syncsafe(head, 6);
  while (i + 10 <= limit && i + 10 + 4 <= head.length) {
    final id = String.fromCharCodes(head.sublist(i, i + 4)).trim();
    if (id.isEmpty || id.codeUnitAt(0) == 0) break;
    final size = _syncsafe(head, i + 4);
    if (size < 0 || i + 10 + size > head.length) break;
    if (id == 'APIC' && size > 8) {
      final img = _apicImage(head.sublist(i + 10, i + 10 + size));
      if (img != null) return img;
    }
    i += 10 + size;
  }
  return null;
}

/// 从 APIC 帧体提取图片字节：
/// - mime `-->` 是 URL 引用而非图片数据，跳过；
/// - 描述终止符按编码处理（UTF-16 为对齐的 00 00，单字节编码为 00）；
/// - 只有通过图片签名校验才返回，避免把描述残留/URL 写进封面缓存
///   （否则 Android ImageDecoder 会报「Failed to decode image」）。
Uint8List? _apicImage(List<int> data) {
  if (data.length < 6) return null;
  final enc = data[0];
  var p = 1;
  final mimeEnd = data.indexOf(0, p);
  if (mimeEnd < 0) return null;
  final mime = String.fromCharCodes(data.sublist(p, mimeEnd));
  if (mime == '-->') return null;
  p = mimeEnd + 1;
  if (p >= data.length) return null;
  p += 1; // 图片类型
  if (enc == 1 || enc == 2) {
    // UTF-16：描述终止符为双字节 00 00（按 2 字节对齐扫描）。
    var q = p;
    var terminated = false;
    while (q + 1 < data.length) {
      if (data[q] == 0 && data[q + 1] == 0) {
        q += 2;
        terminated = true;
        break;
      }
      q += 2;
    }
    if (!terminated) return null;
    p = q;
  } else {
    final descEnd = data.indexOf(0, p);
    if (descEnd < 0) return null;
    p = descEnd + 1;
  }
  if (p >= data.length) return null;
  final img = Uint8List.fromList(data.sublist(p));
  return looksLikeImageBytes(img) ? img : null;
}

/// 图片字节签名校验（JPEG/PNG/GIF/BMP/WEBP/HEIF-AVIF）。
///
/// 封面写入缓存前必须通过校验：解析出的字节可能是描述残留、URL 文本等，
/// 直接落盘会让图片解码器报错刷日志。
bool looksLikeImageBytes(List<int> b) {
  if (b.length < 12) return false;
  if (b[0] == 0xFF && b[1] == 0xD8) return true; // JPEG
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    return true; // PNG
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return true; // GIF
  if (b[0] == 0x42 && b[1] == 0x4D) return true; // BMP
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
      b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
    return true; // WEBP (RIFF....WEBP)
  }
  if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) {
    return true; // ftyp (HEIF/AVIF)
  }
  return false;
}

String _decodeText(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final enc = bytes[0];
  var body = bytes.sublist(1);
  if (enc == 3) return utf8.decode(body, allowMalformed: true).trim();
  if (enc == 2) {
    // UTF-16BE without BOM
    final list = <int>[];
    for (var i = 0; i + 1 < body.length; i += 2) {
      list.add((body[i] << 8) | body[i + 1]);
    }
    return String.fromCharCodes(list).trim();
  }
  if (enc == 1) {
    // UTF-16 with BOM
    if (body.length >= 2 && body[0] == 0xFF && body[1] == 0xFE) {
      body = body.sublist(2);
    }
    final list = <int>[];
    for (var i = 0; i + 1 < body.length; i += 2) {
      final c = (body[i + 1] << 8) | body[i];
      list.add(c);
    }
    return String.fromCharCodes(list).trim();
  }
  // enc == 0: ISO-8859-1 declared, but many files are actually UTF-8
  try {
    return utf8.decode(body, allowMalformed: false).trim();
  } catch (_) {
    return String.fromCharCodes(body).trim();
  }
}

/// 估算 mp3 时长：优先 Xing/Info 帧头；否则按首个 MPEG 帧码率 + 文件大小。
int? _mp3Duration(Uint8List head, int offset, int fileSize) {
  var i = offset;
  // 找 Xing/Info 帧
  for (var scan = i; scan < head.length - 4; scan++) {
    if (head[scan] == 0x58 && head[scan + 1] == 0x69 &&
        (head[scan + 2] == 0x6E || head[scan + 2] == 0x67) &&
        head[scan + 3] == 0x67) {
      // 0x78 69 6E 67 = Xing ; 49 6E 66 6F = Info
      if (scan + 8 + 4 <= head.length) {
        final frames = _be32(head, scan + 8);
        if (frames > 0) {
          final kbps = _bitrateFromFrame(head, i);
          if (kbps != null && frames > 0) {
            return ((frames * 1152) / (kbps * 125)).round();
          }
        }
      }
      break;
    }
  }
  final kbps = _bitrateFromFrame(head, i);
  if (kbps != null && kbps > 0) {
    return ((fileSize * 8) / (kbps * 1000)).round();
  }
  return null;
}

int? _bitrateFromFrame(Uint8List head, int offset) {
  for (var i = offset; i + 4 <= head.length; i++) {
    if (head[i] != 0xFF) continue;
    if ((head[i + 1] & 0xE0) != 0xE0) continue;
    final version = (head[i + 1] >> 3) & 0x3;
    final layer = (head[i + 1] >> 1) & 0x3;
    if (layer == 0) continue; // reserved
    final brIdx = (head[i + 2] >> 4) & 0xF;
    if (brIdx == 15 || brIdx == 0) continue;
    final srIdx = (head[i + 2] >> 2) & 0x3;
    if (srIdx == 3) continue;
    const v1l1 = [0,32,64,96,128,160,192,224,256,288,320,352,384,416,448];
    const v1l2 = [0,32,48,56,64,80,96,112,128,160,192,224,256,320,384];
    const v1l3 = [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320];
    const v2l1 = [0,32,48,56,64,80,96,112,128,144,160,176,192,224,256];
    const v2l23 = [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160];
    List<int> tbl;
    if (layer == 3) {
      tbl = version == 3 ? v1l1 : v2l1;
    } else if (layer == 2) {
      tbl = version == 3 ? v1l2 : v2l23;
    } else {
      tbl = version == 3 ? v1l3 : v2l23;
    }
    if (brIdx < tbl.length) return tbl[brIdx];
    return null;
  }
  return null;
}

// ---------- FLAC ----------

AudioMeta _parseFlac(Uint8List head, int fileSize) {
  final meta = AudioMeta();
  if (head.length < 4 || String.fromCharCodes(head.sublist(0, 4)) != 'fLaC') return meta;
  var i = 4;
  bool last = false;
  int? sampleRate;
  int? totalSamples;
  while (!last && i + 4 <= head.length) {
    final hdr = head[i];
    last = (hdr & 0x80) != 0;
    final blockType = hdr & 0x7F;
    final len = _be24(head, i + 1);
    // 元数据块可能超出头部采样长度（如大内嵌封面），此时无法继续解析后续块。
    if (i + 4 + len > head.length) break;
    final body = head.sublist(i + 4, i + 4 + len);
    if (blockType == 0 && body.length >= 18) {
      // STREAMINFO：sample_rate(20)|channels(3)|bps(5)|total_samples(36)，位于 body[10..17]
      final sr = ((body[10] << 12) | (body[11] << 4) | (body[12] >> 4)) & 0xFFFFF;
      final samples = ((body[13] & 0x0F) << 32) |
          (body[14] << 24) |
          (body[15] << 16) |
          (body[16] << 8) |
          body[17];
      sampleRate = sr;
      totalSamples = samples;
      if (sr > 0 && samples > 0) {
        meta.duration = (samples / sr).round();
      }
    } else if (blockType == 4) {
      // VORBIS_COMMENT
      _parseVorbisComment(body, meta);
    } else if (blockType == 6) {
      // PICTURE
      meta.cover ??= _parseFlacPicture(body);
    }
    i += 4 + len;
  }
  if (meta.duration == null &&
      sampleRate != null &&
      totalSamples != null &&
      totalSamples > 0) {
    meta.duration = (totalSamples / sampleRate).round();
  }
  return meta;
}

void _parseVorbisComment(List<int> body, AudioMeta meta) {
  // vorbis comment: after framing, vendor (LE uint32 len), vendor string, then count (LE u32), entries
  var p = 0;
  int readU32(List<int> b, int o) =>
      (b[o]) | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
  if (body.length < 4) return;
  final vendorLen = readU32(body, 0);
  p = 4 + vendorLen;
  if (p + 4 > body.length) return;
  final count = readU32(body, p);
  p += 4;
  for (var n = 0; n < count && p + 4 <= body.length; n++) {
    final len = readU32(body, p);
    p += 4;
    if (p + len > body.length) break;
    final raw = body.sublist(p, p + len);
    String entry;
    try {
      entry = utf8.decode(raw, allowMalformed: false);
    } catch (_) {
      entry = String.fromCharCodes(raw);
    }
    p += len;
    final eq = entry.indexOf('=');
    if (eq <= 0) continue;
    final key = entry.substring(0, eq).toUpperCase();
    final val = entry.substring(eq + 1);
    switch (key) {
      case 'TITLE':
        meta.title ??= val;
        break;
      case 'ARTIST':
        meta.artist ??= val;
        break;
      case 'ALBUM':
        meta.album ??= val;
        break;
      case 'GENRE':
        meta.genre ??= val;
        break;
      case 'DATE':
        meta.year ??= _yearOf(val);
        break;
      case 'TRACKNUMBER':
        meta.trackNo ??= int.tryParse(val);
        break;
    }
  }
}

Uint8List? _parseFlacPicture(List<int> body) {
  // picture block: type(u32), mime len(u32), mime, desc len(u32), desc, w/h/depth/colors (4*u32),
  // data len(u32), data
  int readU32b(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  var p = 4;
  if (p + 4 > body.length) return null;
  final mimeLen = readU32b(body, p);
  p += 4;
  if (mimeLen < 0 || p + mimeLen > body.length) return null;
  final mime = String.fromCharCodes(body.sublist(p, p + mimeLen));
  if (mime == '-->') return null; // URL 引用而非图片数据
  p += mimeLen;
  if (p + 4 > body.length) return null;
  final descLen = readU32b(body, p);
  p += 4 + descLen;
  p += 16; // width, height, depth, colors
  if (p + 4 > body.length) return null;
  final dataLen = readU32b(body, p);
  p += 4;
  if (dataLen < 0 || p + dataLen > body.length) return null;
  final img = Uint8List.fromList(body.sublist(p, p + dataLen));
  return looksLikeImageBytes(img) ? img : null;
}

// ---------- helpers ----------

int _syncsafe(List<int> b, int o) => (b[o] & 0x7F) << 21 |
    (b[o + 1] & 0x7F) << 14 |
    (b[o + 2] & 0x7F) << 7 |
    (b[o + 3] & 0x7F);

int _be32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _be24(List<int> b, int o) => (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];

int? _yearOf(String? v) {
  if (v == null) return null;
  final m = RegExp(r'(19|20)\d{2}').firstMatch(v);
  return m == null ? null : int.tryParse(m.group(0)!);
}

int? _trackOf(String? v) {
  if (v == null) return null;
  final m = RegExp(r'\d+').firstMatch(v);
  return m == null ? null : int.tryParse(m.group(0)!);
}

String fallbackTitle(String ref) {
  final name = ref.substring(ref.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}
