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
  final limit = tagStart + _syncsafe(head, 6);
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
      final data = head.sublist(i + 10, i + 10 + size);
      // encoding byte, mime (null-terminated), pic type, description (null-terminated)
      var p = 1;
      final mimeEnd = data.indexOf(0, p);
      if (mimeEnd < 0) return null;
      p = mimeEnd + 1;
      p += 1; // pic type
      final descEnd = data.indexOf(0, p);
      if (descEnd < 0) return null;
      p = descEnd + 1;
      if (p < data.length) return data.sublist(p);
    }
    i += 10 + size;
  }
  return null;
}

String _decodeText(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final enc = bytes[0];
  var body = bytes.sublist(1);
  if (enc == 3) return String.fromCharCodes(body); // UTF-8 (rare enc==3 still UTF-8)
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
  return String.fromCharCodes(body).trim(); // ISO-8859-1 / latin1
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
    final entry = String.fromCharCodes(body.sublist(p, p + len));
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
  p += 4 + mimeLen;
  if (p + 4 > body.length) return null;
  final descLen = readU32b(body, p);
  p += 4 + descLen;
  p += 16; // width, height, depth, colors
  if (p + 4 > body.length) return null;
  final dataLen = readU32b(body, p);
  p += 4;
  if (p + dataLen > body.length) return null;
  return Uint8List.fromList(body.sublist(p, p + dataLen));
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
