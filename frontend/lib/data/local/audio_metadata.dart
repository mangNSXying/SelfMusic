import 'dart:convert' show base64Decode, utf8;
import 'dart:typed_data';

/// 音频头部元数据（来自扫描时的 Range 头部直读，DESIGN §6.4）。
class AudioMeta {
  String? title;
  String? artist;

  /// 专辑歌手（mp3 TPE2 / flac ALBUMARTIST / m4a aART / ogg ALBUMARTIST，可空；为空时展示回退到 [artist]）。
  String? albumArtist;
  String? album;
  String? genre;
  int? year;
  int? trackNo;
  int? duration; // 秒
  Uint8List? cover; // 嵌入封面原始字节（jpg/png）

  /// 内嵌歌词原文（mp3 USLT / flac·ogg LYRICS|UNSYNCEDLYRICS；可能是带时间轴的 LRC）。
  String? lyrics;

  /// 采样率（ogg/opus 尾部 granule 换算时长用；不落库）。
  int? sampleRate;

  /// 是否为「已识别的容器但头部采样不完整」（如 m4a moov 在文件尾）：
  /// 提示调用方做尾部补读，而不是判定为无标签。
  bool truncatedContainer = false;
}

/// 纯 Dart 头部解析：mp3(ID3v2) / flac / m4a(mp4) / ogg·opus / wav / aac(ADTS)。
/// 未识别容器返回 null（调用方做文件名回退）。
///
/// [head] 为文件头部字节（扫描时取 ~256KB），[format] 为扩展名，[fileSize] 为完整大小。
AudioMeta? parseAudioHead(Uint8List head, String format, int fileSize) {
  switch (format) {
    case 'mp3':
      return _parseMp3(head, fileSize);
    case 'flac':
      return _parseFlac(head, fileSize);
    case 'm4a':
    case 'mp4':
      return _parseMp4(head, fileSize);
    case 'ogg':
    case 'oga':
    case 'opus':
      return _parseOgg(head);
    case 'wav':
      return _parseWav(head);
    case 'aac':
      return _parseAac(head, fileSize);
    default:
      return null;
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
    case 'm4a':
    case 'mp4':
      return _parseMp4Minimal(head);
    case 'ogg':
    case 'oga':
    case 'opus':
      return _parseOggMinimal(head);
    case 'wav':
      return _parseWavMinimal(head);
    case 'aac':
      return _parseMp3Minimal(head); // aac 通常带 ID3v2 头
    default:
      return null;
  }
}

/// 封面深度读取上限（防止恶意/异常文件把标签声明撑到 GB 级）。
const int kCoverReadCapBytes = 8 * 1024 * 1024;

/// 封面读取提示（播放补读 / 扫描的「两段读」用）：
///
/// 首次采样解析缺少封面时，返回「需要多少头部字节才能读到完整的封面块」
/// （即封面块被采样截断）；null 表示无需更多字节——标签已在采样内完整
/// （封面要么已解析，要么确实没有）。
int? coverReadHint(Uint8List head, String format) {
  switch (format) {
    case 'mp3':
      return _mp3CoverReadHint(head);
    case 'flac':
      return _flacCoverReadHint(head);
    case 'ogg':
    case 'oga':
    case 'opus':
      return _oggCoverReadHint(head);
    default:
      return null;
  }
}

/// ogg/opus：comment 包（第二逻辑包）未在采样内结束 → 需按上限补读；
/// 完整读到即无需补读（有封面会已解析，无封面则是真的没有）。
int? _oggCoverReadHint(Uint8List head) {
  var i = 0;
  var packets = 0;
  while (i + 27 <= head.length) {
    if (head[i] != 0x4F || head[i + 1] != 0x67 || head[i + 2] != 0x67 ||
        head[i + 3] != 0x53) {
      return null;
    }
    final segCount = head[i + 26];
    final tableStart = i + 27;
    if (tableStart + segCount > head.length) return kCoverReadCapBytes;
    var payload = tableStart + segCount;
    for (var s = 0; s < segCount; s++) {
      final seg = head[tableStart + s];
      if (payload + seg > head.length) return kCoverReadCapBytes;
      payload += seg;
      if (seg < 255) {
        packets++;
        if (packets >= 2) return null; // comment 包已完整
      }
    }
    i = payload;
  }
  return kCoverReadCapBytes;
}

int? _mp3CoverReadHint(Uint8List head) {
  if (head.length < 10) return null;
  if (head[0] != 0x49 || head[1] != 0x44 || head[2] != 0x33) return null; // 'ID3'
  final tagEnd = 10 + _syncsafe(head, 6);
  return tagEnd > head.length ? tagEnd : null;
}

int? _flacCoverReadHint(Uint8List head) {
  if (head.length < 8 || String.fromCharCodes(head.sublist(0, 4)) != 'fLaC') {
    return null;
  }
  var i = 4;
  var last = false;
  while (!last && i + 4 <= head.length) {
    final hdr = head[i];
    last = (hdr & 0x80) != 0;
    final blockType = hdr & 0x7F;
    final len = _be24(head, i + 1);
    if (i + 4 + len > head.length) {
      // 该块被采样截断：PICTURE 可能在后续块，提示补到本块结束再继续解析。
      return i + 4 + len;
    }
    if (blockType == 6) return null; // PICTURE 已完整读入；缺封面说明块内无有效图
    i += 4 + len;
  }
  return null;
}

/// 字节范围读取器（起址 + 长度）→ 字节；读不满允许返回实际长度。
typedef AudioRangeReader = Future<Uint8List> Function(int start, int length);

/// 尾部补读提示（字节数，自文件末尾起）：
/// - m4a：moov 不在头部采样内（常见 moov-at-end）→ 先试 256KB，调用方逐级增大；
/// - ogg/opus：头部无法得时长，读末尾页取 granule → 64KB；
/// - 其余 null（无需尾读）。
int? tailReadHint(Uint8List head, String format, int fileSize) {
  switch (format) {
    case 'm4a':
    case 'mp4':
      return _mp4NeedsMoovTail(head)
          ? (fileSize < 256 * 1024 ? fileSize : 256 * 1024)
          : null;
    case 'ogg':
    case 'oga':
    case 'opus':
      return fileSize < 64 * 1024 ? fileSize : 64 * 1024;
    case 'mp3':
      // 无 ID3v2 的老文件可能有文件尾 128 字节 ID3v1（标题/歌手/专辑/年份/曲目）。
      if (head.length >= 3 &&
          head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
        return null;
      }
      return fileSize >= 128 ? 128 : null;
    default:
      return null;
  }
}

/// 解析文件尾部（m4a moov-at-end 的标签/封面/时长；ogg 末页 granule 时长；
/// mp3 ID3v1 兜底标签）。
/// m4a：仅当 moov 盒完整落在 [tail] 内才返回（否则调用方增大尾读长度）；
/// 其余：无有效信息返回 null。
AudioMeta? parseAudioTail(Uint8List tail, String format, int fileSize,
    {AudioMeta? headMeta}) {
  switch (format) {
    case 'm4a':
    case 'mp4':
      return _parseMp4Tail(tail, fileSize);
    case 'ogg':
    case 'oga':
    case 'opus':
      final d = _oggTailDuration(tail, headMeta?.sampleRate);
      if (d == null) return null;
      final meta = AudioMeta();
      meta.duration = d;
      return meta;
    case 'mp3':
      return _parseId3v1(tail);
  }
  return null;
}

/// ID3v1（文件尾 128 字节，'TAG' 开头）：老 mp3 的兜底标签。
AudioMeta? _parseId3v1(Uint8List tail) {
  if (tail.length < 128) return null;
  final p = tail.length - 128;
  if (tail[p] != 0x54 || tail[p + 1] != 0x41 || tail[p + 2] != 0x47) {
    return null;
  }
  String field(int offset, int len) {
    final end = offset + len;
    var stop = offset;
    while (stop < end && tail[p + stop] != 0) {
      stop++;
    }
    if (stop <= offset) return '';
    // ID3v1 多为 Latin-1；尝试 UTF-8 失败再回退。
    final raw = tail.sublist(p + offset, p + stop);
    try {
      return utf8.decode(raw, allowMalformed: false).trim();
    } catch (_) {
      return String.fromCharCodes(raw).trim();
    }
  }

  final meta = AudioMeta();
  final title = field(3, 30);
  final artist = field(33, 30);
  final album = field(63, 30);
  final year = field(93, 4);
  if (title.isNotEmpty) meta.title = title;
  if (artist.isNotEmpty) meta.artist = artist;
  if (album.isNotEmpty) meta.album = album;
  meta.year = _yearOf(year);
  // 曲目：ID3v1.1 在 comment 末两字节（comment 长 30，倒数第二字节 0 时次字节为 track）。
  if (tail[p + 125] == 0 && tail[p + 126] != 0) {
    meta.trackNo = tail[p + 126];
  }
  return meta;
}

/// [fullRead] 的整首完整读取上限（字节）。超过就只加大采样，剩下交给
/// 「按封面提示补读 + 尾部补读」。
///
/// 原实现对 fullRead 一律从 0 读到 fileSize、不截断，是为拿到大内嵌封面、
/// FLAC 里 PICTURE 排在 VORBIS_COMMENT 之前这类块序异常。但这条链路是
/// **后台补读**（meta_enrich 逐首跑），采样稍微不够就整首下几十 MB 甚至
/// 上百 MB，既烧流量又长时间占着直连源的连接；而命中的恰恰是「大文件」，
/// 于是代价与收益正好倒挂。绝大多数曲目远小于本上限，行为不变。
const int kFullReadCapBytes = 16 * 1024 * 1024;

/// 整首超过 [kFullReadCapBytes] 时的加大采样量：多读一点是为了跨过大封面块
/// 够到后面的 VORBIS_COMMENT，再由下面的按提示补读接手封面本身。
const int kBigFileHeadBytes = 1024 * 1024;

/// 头部 + 头部补读 + 尾部补读的统一直读流程（播放补读 / 扫描共用）。
///
/// [readRange] 由调用方实现（本地文件 / WebDAV Range GET）。
/// [fullRead]（播放/后台补读链路）：先做 [headBytes] 采样；采样不足以拿到
/// 完整元数据时，从文件头完整读取整个文件（`0..fileSize`），不做长度
/// 推算与上限截断——大内嵌封面、块序异常（如 FLAC 的 PICTURE 在
/// VORBIS_COMMENT 之前）等都能完整解析；所有格式统一。但整读以
/// [kFullReadCapBytes] 为上限：超过则改为加大采样到 [kBigFileHeadBytes]
/// 后走按提示补读，避免后台为几十 MB 的曲子整首下网。扫描等批量路径保持
/// 默认的「按封面提示补读 + [kCoverReadCapBytes] 上限」，以控制带宽与内存。
Future<AudioMeta?> readAudioMeta({
  required AudioRangeReader readRange,
  required String format,
  required int fileSize,
  int headBytes = 256 * 1024,
  bool fullRead = false,
}) async {
  var head = await readRange(0, headBytes);
  if (head.isEmpty) return null;
  var meta = parseAudioHead(head, format, fileSize);
  if (fullRead && fileSize > 0 && meta != null) {
    // 整首在 [kFullReadCapBytes] 以内才真读整个文件（不截断、不做补读长度推算）。
    final wholeFileFits = fileSize <= kFullReadCapBytes;
    if (wholeFileFits && _needsFullRead(head, meta, format, fileSize)) {
      final all = await readRange(0, fileSize);
      if (all.length > head.length) {
        final full = parseAudioHead(all, format, fileSize);
        if (full != null) meta = _mergeMeta(full, meta);
        head = all;
      }
      // 尾部信息（m4a moov-at-end / ogg granule 时长 / ID3v1）在完整数据上补全。
      final t = parseAudioTail(head, format, fileSize, headMeta: meta);
      return t == null ? meta : _mergeMeta(meta, t);
    }
    if (!wholeFileFits && fileSize > kBigFileHeadBytes) {
      // 整首太大：不整读，只把采样加大到 [kBigFileHeadBytes] 重新解析，
      // 然后走下面的「按封面提示补读 + 尾部补读」（封面读不满就放弃封面，
      // 换标签/时长）。
      final more = await readRange(0, kBigFileHeadBytes);
      if (more.length > head.length) {
        final deeper = parseAudioHead(more, format, fileSize);
        if (deeper != null) meta = deeper;
        head = more;
      }
    }
  }
  // 大内嵌封面/标签：按提示补读头部一次。
  if (meta != null && meta.cover == null) {
    final hint = coverReadHint(head, format);
    if (hint != null && hint > head.length && hint <= kCoverReadCapBytes) {
      final deeper = await readRange(0, hint);
      if (deeper.length > head.length) {
        final deeperMeta = parseAudioHead(deeper, format, fileSize);
        if (deeperMeta != null) {
          meta = deeperMeta;
          head = deeper;
        }
      }
    }
  }
  // moov-at-end / ogg 时长：尾部补读（m4a 按 256KB→1MB→4MB→8MB 逐级增大）。
  if (meta == null || meta.cover == null || meta.duration == null) {
    final first = tailReadHint(head, format, fileSize);
    if (first != null && first > 0) {
      var tailLen = first;
      while (true) {
        final len = tailLen > fileSize ? fileSize : tailLen;
        final start = fileSize - len;
        if (start < 0 || len <= 0) break;
        final tail = await readRange(start, len);
        final t = parseAudioTail(tail, format, fileSize, headMeta: meta);
        if (t != null) {
          meta = _mergeMeta(meta, t);
          break;
        }
        if (format != 'm4a' && format != 'mp4') break;
        final next = len * 4;
        if (next <= len || next > kCoverReadCapBytes || len >= fileSize) break;
        tailLen = next;
      }
    }
  }
  return meta;
}

/// fullRead 采样是否不足（触发从头完整读取）：
/// - 标签/封面被采样截断（[coverReadHint] 给出补读提示）；
/// - 未解析出标题（如 m4a moov-at-end、PICTURE 在 VORBIS_COMMENT 之前的
///   FLAC——采样在封面块处中断，后续 VORBIS_COMMENT 未读到）；
/// - m4a/mp4 的 moov 在尾部（标签/封面可能在尾部元数据区）。
bool _needsFullRead(
    Uint8List head, AudioMeta meta, String format, int fileSize) {
  if (coverReadHint(head, format) != null) return true;
  if (meta.title == null && format != 'wav') return true;
  if ((format == 'm4a' || format == 'mp4') &&
      tailReadHint(head, format, fileSize) != null) {
    return true;
  }
  return false;
}

/// [extra] 非空字段覆盖 [base]；base 为 null 时直接返回 extra。
AudioMeta _mergeMeta(AudioMeta? base, AudioMeta extra) {
  if (base == null) return extra;
  base.title ??= extra.title;
  base.artist ??= extra.artist;
  base.albumArtist ??= extra.albumArtist;
  base.album ??= extra.album;
  base.genre ??= extra.genre;
  base.year ??= extra.year;
  base.trackNo ??= extra.trackNo;
  base.duration ??= extra.duration;
  base.cover ??= extra.cover;
  base.lyrics ??= extra.lyrics;
  base.sampleRate ??= extra.sampleRate;
  return base;
}

// ---------- MP3 最小解析 ----------

AudioMeta _parseMp3Minimal(Uint8List head) {
  final meta = AudioMeta();
  if (head.length >= 10 && String.fromCharCodes(head.sublist(0, 3)) == 'ID3') {
    final frames = _id3TagToFrames(head, 10);
    meta.title = frames['TIT2'];
    meta.artist = frames['TPE1'];
    meta.albumArtist = frames['TPE2'];
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
    meta.albumArtist = frames['TPE2'];
    meta.album = frames['TALB'];
    meta.genre = frames['TCON'];
    meta.year = _yearOf(frames['TYER'] ?? frames['TDRC']);
    meta.trackNo = _trackOf(frames['TRCK']);
    meta.cover = _apicOf(head);
    meta.lyrics = frames['USLT'];
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
    } else if (id == 'USLT') {
      // 歌词帧结构特殊（encoding + language + descriptor + text），不能按普通文本帧解码。
      if (!out.containsKey(id)) {
        final v = _decodeUslt(head.sublist(i + 10, i + 10 + size));
        if (v.isNotEmpty) out[id] = v;
      }
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

/// 解码 USLT（非同步歌词）帧体：encoding(1) + language(3) + descriptor + text。
/// 描述段终止符按编码对齐：UTF-16 为双字节 00 00，单字节编码为 00。
String _decodeUslt(List<int> data) {
  if (data.length < 5) return '';
  final enc = data[0];
  var p = 4; // 跳过 encoding + 3 字节 language
  if (enc == 1 || enc == 2) {
    while (p + 1 < data.length && !(data[p] == 0 && data[p + 1] == 0)) {
      p += 2;
    }
    p += 2;
  } else {
    final z = data.indexOf(0, p);
    if (z >= 0) p = z + 1;
  }
  if (p >= data.length) return '';
  return _decodeText([enc, ...data.sublist(p)]);
}

/// 估算 mp3 时长：优先 Xing/Info 帧头；否则按首个 MPEG 帧码率 + 文件大小。
int? _mp3Duration(Uint8List head, int offset, int fileSize) {
  var i = offset;
  // 找 Xing/Info 帧
  for (var scan = i; scan < head.length - 4; scan++) {
    if (head[scan] == 0x58 &&
        head[scan + 1] == 0x69 &&
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
  _parseVorbisComments(body, meta, includePicture: true);
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

// ---------- MP4 / M4A ----------

class _Mp4Box {
  final String type;
  final int offset; // 盒起始（含 size/type 头）
  final int size; // 整盒长度
  final int header; // 头长度（8 或 16）
  const _Mp4Box(this.type, this.offset, this.size, this.header);
  int get bodyStart => offset + header;
  int get end => offset + size;
}

/// 遍历 [start, end) 内的同级盒；遇到越界/不完整即停止（不抛异常）。
Iterable<_Mp4Box> _mp4Boxes(Uint8List b, int start, int end) sync* {
  var i = start;
  while (i + 8 <= end) {
    var size = _be32(b, i);
    final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
    var header = 8;
    if (size == 1) {
      if (i + 16 > end) return;
      size = _be64(b, i + 8);
      header = 16;
    } else if (size == 0) {
      size = end - i;
    }
    if (size < header || i + size > end) return;
    yield _Mp4Box(type, i, size, header);
    i += size;
  }
}

bool _mp4NeedsMoovTail(Uint8List head) {
  var i = 0;
  while (i + 8 <= head.length) {
    var size = _be32(head, i);
    final type = String.fromCharCodes(head.sublist(i + 4, i + 8));
    var header = 8;
    if (size == 1) {
      if (i + 16 > head.length) return true;
      size = _be64(head, i + 8);
      header = 16;
    } else if (size == 0) {
      size = head.length - i;
    }
    if (size < header) return true;
    if (type == 'moov') return i + size > head.length;
    if (i + size > head.length) return true; // 后续盒越界：moov 可能在文件尾
    i += size;
  }
  return true; // 采样内未见 moov：按 moov-at-end 处理
}

AudioMeta _parseMp4(Uint8List head, int fileSize) {
  final meta = AudioMeta();
  for (final box in _mp4Boxes(head, 0, head.length)) {
    if (box.type == 'moov') {
      _parseMp4Moov(head, box.bodyStart, box.end, meta);
      return meta;
    }
  }
  meta.truncatedContainer = true; // moov 不在头部：调用方做尾部补读
  return meta;
}

AudioMeta _parseMp4Minimal(Uint8List head) {
  final meta = AudioMeta();
  final full = _parseMp4(head, head.length);
  meta.title = full.title;
  meta.artist = full.artist;
  meta.albumArtist = full.albumArtist;
  meta.album = full.album;
  return meta;
}

AudioMeta? _parseMp4Tail(Uint8List tail, int fileSize) {
  // 自尾向前找完整落在 tail 内的 moov 盒（moov-at-end 常见）。
  for (var p = tail.length - 8; p >= 4; p--) {
    if (tail[p] == 0x6D && tail[p + 1] == 0x6F && tail[p + 2] == 0x6F &&
        tail[p + 3] == 0x76) {
      final size = _be32(tail, p - 4);
      final start = p - 4;
      if (size < 8 || start + size > tail.length) continue;
      final meta = AudioMeta();
      final box = _Mp4Box('moov', start, size, 8);
      _parseMp4Moov(tail, box.bodyStart, box.end, meta);
      return meta;
    }
  }
  return null;
}

void _parseMp4Moov(Uint8List b, int start, int end, AudioMeta meta) {
  for (final box in _mp4Boxes(b, start, end)) {
    switch (box.type) {
      case 'mvhd':
        _parseMp4Mvhd(b, box.bodyStart, box.end, meta);
      case 'udta':
        _parseMp4Moov(b, box.bodyStart, box.end, meta);
      case 'meta':
        // fullbox：version/flags 4 字节后再遍历（hdlr + ilst）。
        _parseMp4Moov(b, box.bodyStart + 4, box.end, meta);
      case 'ilst':
        _parseMp4Ilst(b, box.bodyStart, box.end, meta);
    }
  }
}

void _parseMp4Mvhd(Uint8List b, int start, int end, AudioMeta meta) {
  if (start + 4 > end) return;
  final version = b[start];
  int timescale;
  int duration;
  if (version == 1) {
    if (start + 32 > end) return;
    timescale = _be32(b, start + 20);
    duration = _be64(b, start + 24);
  } else {
    if (start + 20 > end) return;
    timescale = _be32(b, start + 12);
    duration = _be32(b, start + 16);
  }
  if (timescale > 0 && duration > 0) {
    meta.duration = (duration / timescale).round();
  }
}

void _parseMp4Ilst(Uint8List b, int start, int end, AudioMeta meta) {
  for (final item in _mp4Boxes(b, start, end)) {
    for (final data in _mp4Boxes(b, item.bodyStart, item.end)) {
      if (data.type != 'data' || data.bodyStart + 8 > data.end) continue;
      final dataType = _be32(b, data.bodyStart);
      final payloadStart = data.bodyStart + 8; // type(4) + locale(4)
      final payloadEnd = data.end;
      switch (item.type) {
        case '©nam':
          meta.title ??= _mp4Text(b, payloadStart, payloadEnd);
        case '©ART':
          meta.artist ??= _mp4Text(b, payloadStart, payloadEnd);
        case 'aART':
          meta.albumArtist ??= _mp4Text(b, payloadStart, payloadEnd);
        case '©alb':
          meta.album ??= _mp4Text(b, payloadStart, payloadEnd);
        case '©gen':
          meta.genre ??= _mp4Text(b, payloadStart, payloadEnd);
        case '©day':
          meta.year ??= _yearOf(_mp4Text(b, payloadStart, payloadEnd));
        case '©lyr':
          final t = _mp4Text(b, payloadStart, payloadEnd);
          if (t != null && t.trim().isNotEmpty) meta.lyrics ??= t;
        case 'trkn':
          if (payloadStart + 4 <= payloadEnd) {
            meta.trackNo ??= (b[payloadStart + 2] << 8) | b[payloadStart + 3];
          }
        case 'covr':
          if (meta.cover == null && (dataType == 13 || dataType == 14)) {
            final img = Uint8List.fromList(
                b.sublist(payloadStart, payloadEnd));
            if (looksLikeImageBytes(img)) meta.cover = img;
          }
      }
    }
  }
}

String? _mp4Text(Uint8List b, int start, int end) {
  if (start >= end) return null;
  final s = utf8.decode(b.sublist(start, end), allowMalformed: true).trim();
  return s.isEmpty ? null : s;
}

// ---------- OGG / OPUS ----------

/// 组装头部采样内的前 [maxPackets] 个逻辑包（跨页 lacing 拼接）。
List<Uint8List> _oggFirstPackets(Uint8List b, {int maxPackets = 2}) {
  final packets = <Uint8List>[];
  var current = BytesBuilder();
  var i = 0;
  while (i + 27 <= b.length && packets.length < maxPackets) {
    if (b[i] != 0x4F || b[i + 1] != 0x67 || b[i + 2] != 0x67 || b[i + 3] != 0x53) {
      break; // 非 OggS
    }
    final segCount = b[i + 26];
    final tableStart = i + 27;
    if (tableStart + segCount > b.length) break;
    var payload = tableStart + segCount;
    for (var s = 0; s < segCount; s++) {
      final seg = b[tableStart + s];
      if (payload + seg > b.length) return packets; // 采样截断
      current.add(b.sublist(payload, payload + seg));
      payload += seg;
      if (seg < 255) {
        packets.add(current.takeBytes());
        current = BytesBuilder();
        if (packets.length >= maxPackets) break;
      }
    }
    i = payload;
  }
  return packets;
}

AudioMeta _parseOgg(Uint8List head) => _oggParse(head, includePicture: true);

AudioMeta _parseOggMinimal(Uint8List head) {
  final meta = _parseOgg(head);
  meta.cover = null;
  meta.lyrics = null;
  return meta;
}

AudioMeta _oggParse(Uint8List head, {required bool includePicture}) {
  final meta = AudioMeta();
  final packets = _oggFirstPackets(head);
  if (packets.isEmpty) return meta;
  final id = packets[0];
  final isVorbis = _startsWith(id, [0x01, ...'vorbis'.codeUnits]);
  final isOpus = _startsWith(id, 'OpusHead'.codeUnits);
  if (isVorbis) {
    if (id.length >= 16) meta.sampleRate = _le32(id, 12);
  } else if (isOpus) {
    if (id.length >= 16) meta.sampleRate = _le32(id, 12);
  } else {
    return meta;
  }
  if (packets.length < 2) return meta;
  final tags = packets[1];
  List<int> body;
  if (isVorbis && _startsWith(tags, [0x03, ...'vorbis'.codeUnits])) {
    body = tags.sublist(7);
  } else if (isOpus && _startsWith(tags, 'OpusTags'.codeUnits)) {
    body = tags.sublist(8);
  } else {
    return meta;
  }
  _parseVorbisComments(body, meta, includePicture: includePicture);
  return meta;
}

/// 解析 Vorbis comment 正文（vendor + 条目），ogg/opus 与 flac 共用条目规则。
void _parseVorbisComments(List<int> b, AudioMeta meta,
    {bool includePicture = true}) {
  if (b.length < 4) return;
  var p = 0;
  final vendorLen = _le32(b, 0);
  p = 4 + vendorLen;
  if (p + 4 > b.length) return;
  final count = _le32(b, p);
  p += 4;
  for (var n = 0; n < count && p + 4 <= b.length; n++) {
    final len = _le32(b, p);
    p += 4;
    if (len < 0 || p + len > b.length) break;
    final raw = b.sublist(p, p + len);
    p += len;
    String entry;
    try {
      entry = utf8.decode(raw, allowMalformed: false);
    } catch (_) {
      entry = String.fromCharCodes(raw);
    }
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
      case 'ALBUMARTIST':
      case 'ALBUM ARTIST':
      case 'ALBUM_ARTIST':
        meta.albumArtist ??= val;
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
        meta.trackNo ??= _trackOf(val);
        break;
      case 'LYRICS':
      case 'UNSYNCEDLYRICS':
      case 'UNSYNCED LYRICS':
      case 'LYRIC':
        if (val.trim().isNotEmpty) meta.lyrics ??= val;
        break;
      case 'METADATA_BLOCK_PICTURE':
        if (includePicture && meta.cover == null) {
          try {
            meta.cover = _parseFlacPicture(base64Decode(val.trim()));
          } catch (_) {}
        }
        break;
      case 'COVERART':
        if (includePicture && meta.cover == null) {
          try {
            final img = base64Decode(val.trim());
            if (looksLikeImageBytes(img)) meta.cover = img;
          } catch (_) {}
        }
        break;
    }
  }
}

/// 末页 granule → 时长（秒）；[sampleRate] 缺省按 Opus 48000。
int? _oggTailDuration(Uint8List tail, int? sampleRate) {
  for (var p = tail.length - 27; p >= 0; p--) {
    if (tail[p] != 0x4F || tail[p + 1] != 0x67 || tail[p + 2] != 0x67 ||
        tail[p + 3] != 0x53) {
      continue;
    }
    final granule = _le64(tail, p + 6);
    if (granule <= 0 || granule == 0x7FFFFFFFFFFFFFFF) continue;
    final rate = (sampleRate == null || sampleRate <= 0) ? 48000 : sampleRate;
    final d = (granule / rate).round();
    return d > 0 ? d : null;
  }
  return null;
}

// ---------- WAV ----------

AudioMeta _parseWav(Uint8List head) {
  final meta = AudioMeta();
  if (!_startsWith(head, 'RIFF'.codeUnits) ||
      head.length < 12 ||
      !_startsWith(head.sublist(8), 'WAVE'.codeUnits)) {
    return meta;
  }
  var byteRate = 0;
  var i = 12;
  while (i + 8 <= head.length) {
    final id = String.fromCharCodes(head.sublist(i, i + 4));
    final size = _le32(head, i + 4);
    final body = i + 8;
    if (size < 0) break;
    if (id == 'fmt ' && size >= 12 && body + size <= head.length) {
      byteRate = _le32(head, body + 8);
    } else if (id == 'data') {
      // data 体在头部采样中通常被截断：按时长 = 声明大小 / 字节率计算。
      if (byteRate > 0 && size > 0) meta.duration = (size / byteRate).round();
      break;
    } else if (id == 'LIST' && size >= 4 && body + size <= head.length &&
        _startsWith(head.sublist(body), 'INFO'.codeUnits)) {
      _parseWavInfo(head, body + 4, body + size, meta);
    }
    if (body + size > head.length) break;
    i = body + size + (size.isOdd ? 1 : 0);
  }
  return meta;
}

AudioMeta _parseWavMinimal(Uint8List head) {
  final meta = _parseWav(head);
  meta.duration = null;
  return meta;
}

void _parseWavInfo(Uint8List b, int start, int end, AudioMeta meta) {
  var i = start;
  while (i + 8 <= end) {
    final id = String.fromCharCodes(b.sublist(i, i + 4));
    final size = _le32(b, i + 4);
    if (size < 0 || i + 8 + size > end) break;
    final val = utf8
        .decode(b.sublist(i + 8, i + 8 + size), allowMalformed: true)
        .replaceAll('\u0000', '')
        .trim();
    if (val.isNotEmpty) {
      switch (id) {
        case 'INAM':
          meta.title ??= val;
          break;
        case 'IART':
          meta.artist ??= val;
          break;
        case 'IPRD':
          meta.album ??= val;
          break;
        case 'IGNR':
          meta.genre ??= val;
          break;
        case 'ICRD':
          meta.year ??= _yearOf(val);
          break;
        case 'ITRK':
          meta.trackNo ??= _trackOf(val);
          break;
      }
    }
    i += 8 + size + (size.isOdd ? 1 : 0);
  }
}

// ---------- AAC (ADTS，常带 ID3v2 头) ----------

AudioMeta _parseAac(Uint8List head, int fileSize) {
  final meta = AudioMeta();
  var offset = 0;
  if (head.length >= 10 && _startsWith(head, 'ID3'.codeUnits)) {
    final frames = _id3TagToFrames(head, 10);
    meta.title = frames['TIT2'];
    meta.artist = frames['TPE1'];
    meta.albumArtist = frames['TPE2'];
    meta.album = frames['TALB'];
    meta.genre = frames['TCON'];
    meta.year = _yearOf(frames['TYER'] ?? frames['TDRC']);
    meta.trackNo = _trackOf(frames['TRCK']);
    meta.cover = _apicOf(head);
    meta.lyrics = frames['USLT'];
    offset = 10 + _syncsafe(head, 6);
  }
  // ADTS 时长估算：首帧帧长 / 采样率 → 码率 → 文件大小 / 码率。
  for (var i = offset; i + 7 <= head.length; i++) {
    if (head[i] != 0xFF || (head[i + 1] & 0xF6) != 0xF0) continue;
    final srIndex = (head[i + 2] >> 2) & 0x0F;
    const rates = [
      96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
      16000, 12000, 11025, 8000, 7350, 0, 0, 0
    ];
    final rate = rates[srIndex];
    if (rate <= 0) break;
    final frameLen = ((head[i + 3] & 0x03) << 11) |
        (head[i + 4] << 3) |
        ((head[i + 5] >> 5) & 0x07);
    if (frameLen <= 7) break;
    final bitrate = frameLen * 8 * rate / 1024; // 每帧 1024 采样
    if (bitrate > 0) meta.duration = (fileSize / bitrate).round();
    break;
  }
  return meta;
}

// ---------- helpers ----------

bool _startsWith(Uint8List b, List<int> prefix) {
  if (b.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (b[i] != prefix[i]) return false;
  }
  return true;
}

int _le32(List<int> b, int o) =>
    b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _le64(List<int> b, int o) =>
    _le32(b, o) | (_le32(b, o + 4) << 32);

int _be64(List<int> b, int o) =>
    (_be32(b, o) << 32) | _be32(b, o + 4);

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
