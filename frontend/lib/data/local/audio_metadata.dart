import 'dart:convert' show base64Decode, utf8;
import 'dart:typed_data';

import '../../utils/chunked_scheduler.dart' show ChunkYield;
import '../../utils/main_thread_probe.dart'; // TEMP-PROBE

/// 音频头部元数据（来自扫描时的 Range 头部直读，DEVELOPER.md「客户端扫描与元数据」）。
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

  /// 待解码的内嵌封面 base64（ogg/flac VorbisComment 的 METADATA_BLOCK_PICTURE /
  /// COVERART）：解析阶段只登记字符串，解码（CPU 重活，可达数 MB）从解析热路径
  /// 挪到末尾——由 [readAudioMeta]（可让出）或 [parseAudioHead]（同步一步到位）
  /// 统一收口，保证单次同步块 < 50ms（主线程长同步块治理 R-1）。
  String? pendingCoverB64;

  /// [pendingCoverB64] 是否为 FLAC PICTURE 块结构（true）还是裸图片字节（false）。
  bool pendingCoverIsFlacPicture = false;
}

/// 纯 Dart 头部解析：
/// mp3(ID3v2) / flac / m4a(mp4) / ogg·opus / wav(RIFF) / aiff·aifc(FORM) / aac(ADTS)。
/// 未识别容器返回 null（调用方做文件名回退）。
///
/// [head] 为文件头部字节（扫描时取 ~256KB），[format] 为扩展名，[fileSize] 为完整大小。
AudioMeta? parseAudioHead(Uint8List head, String format, int fileSize,
    {bool deferCoverDecode = false}) {
  final meta = _parseAudioHeadInner(head, format, fileSize);
  // 默认（同步调用方：扫描 / 单测 / readAudioMeta 未传 yieldTo）一步到位解码待定
  // 封面，逐字节与旧实现一致；[deferCoverDecode] 由可让出的 [readAudioMeta] 置位，
  // 交由它分片解码（避免大内嵌封面 base64 解码整块占用主线程）。
  if (meta != null && !deferCoverDecode) _finalizePendingCoverSync(meta);
  return meta;
}

AudioMeta? _parseAudioHeadInner(Uint8List head, String format, int fileSize) {
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
    case 'aiff':
    case 'aif':
    case 'aifc':
      return _parseAiff(head);
    case 'aac':
      return _parseAac(head, fileSize);
    default:
      return null;
  }
}

/// 最小元数据解析：仅 标题/歌手/专辑（DEVELOPER.md「客户端扫描与元数据」 快速扫描）。
///
/// 不解析时长、曲目、年份、流派、封面，因此头部采样可更小、下载量最小；
/// 其余元数据在播放时由 [parseAudioHead] 懒补全（enrich）。
AudioMeta? parseMinimalHead(Uint8List head, String format) {
  final meta = _parseMinimalHeadInner(head, format);
  // 最小解析同步收口待定封面（逐字节与旧实现一致）。
  if (meta != null) _finalizePendingCoverSync(meta);
  return meta;
}

AudioMeta? _parseMinimalHeadInner(Uint8List head, String format) {
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
    case 'aiff':
    case 'aif':
    case 'aifc':
      return _parseAiffMinimal(head);
    case 'aac':
      return _parseMp3Minimal(head); // aac 通常带 ID3v2 头
    default:
      return null;
  }
}

/// 单个音频文件里「元数据区」的读取上限（字节）。
///
/// 这不是封面块大小的估计，而是**声明值的合理性边界**：补读要跳到多远，是文件
/// 自己说的（mp3 的 ID3v2 synchsafe 总长、flac 元数据块的 24 位长度、m4a 的 moov
/// 原子大小），正常文件报出来的都是几 KB 到几 MB。但损坏或构造的文件可以声明
/// 任意大，没有边界就会一路读到 GB 级并把整段塞进内存（`_readRange` 用
/// BytesBuilder 累积）。16MB 足以容下 24MP 无损内嵌封面这种真实上限，同时挡住
/// 声明异常值。
const int kMetaRegionCapBytes = 16 * 1024 * 1024;

/// 同目录图片的单次读取上限（字节）。与 [kMetaRegionCapBytes] 分开：图片是按
/// 「先读一段看签名」探测的，不需要完整内容，超限只是拿不到图，不影响标签。
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

/// ogg/opus：comment 包（第二逻辑包）未在采样内结束 → 需要更多字节。
/// 完整读到即无需更多（有封面会已解析，无封面则是真的没有）。
///
/// 与 mp3/flac 不同，ogg 的段表在**读完段表之后**才知道 payload 落在哪，所以
/// 采样被截断时**无法算出**还需要多少字节。这里返回「按 4 倍放大」这一个档位，
/// 由 [readAudioMeta] 的阶梯循环反复重算——而不是像原先那样直接返回上限：
/// 直接跳上限会让每个头被截断的 ogg 一次性请求上限那么大的区间，于是 8–16MB
/// 的普通 ogg 全被整首下完（服务端按 min(请求长度, 文件大小) 返回）。放大阶梯
/// 从 64KB 起步，够用即止。
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
    if (tableStart + segCount > head.length) return head.length * 4;
    var payload = tableStart + segCount;
    for (var s = 0; s < segCount; s++) {
      final seg = head[tableStart + s];
      if (payload + seg > head.length) return head.length * 4;
      payload += seg;
      if (seg < 255) {
        packets++;
        if (packets >= 2) return null; // comment 包已完整
      }
    }
    i = payload;
  }
  return head.length * 4;
}

int? _mp3CoverReadHint(Uint8List head) {
  if (head.length < 10) return null;
  if (head[0] != 0x49 || head[1] != 0x44 || head[2] != 0x33) return null; // 'ID3'
  final tagEnd = 10 + _syncsafe(head, 6);
  return tagEnd > head.length ? tagEnd : null;
}

/// flac：沿 STREAMINFO → PICTURE → VORBIS_COMMENT 的块列表往下走，返回「需要读到
/// 哪里才能把块列表走完」。
///
/// 三种结局，区别很重要（决定了 [readAudioMeta] 的阶梯还该不该继续）：
/// - 某个块被采样截断 → 返回该块**声明的**结束位置；
/// - 走到带 last 位的块（块列表完整）→ null，元数据区到此为止，没有更多可读；
/// - 块列表中途、下一个块的块头都还没读到 → 无法算位置，返回按 4 倍放大的档位。
///
/// 早期实现在读到完整 PICTURE 块时就 return null，于是「PICTURE 排在
/// VORBIS_COMMENT 之前」这种合法块序下会误判成已到头：封面拿到了，**排在它后面
/// 的标题/歌手永远读不到**（这正是旧实现必须靠整读兜底的原因之一）。
int? _flacCoverReadHint(Uint8List head) {
  final start = _flacMagicOffset(head);
  if (start < 0) {
    // 前置 ID3v2 标签本身超出头部采样：先补到标签尾（再多 4 字节拿到魔数），
    // 下一轮再按块列表继续。
    final id3Len = _leadingId3v2Len(head);
    if (id3Len > 0) return id3Len + 4;
    return null;
  }
  var i = start + 4;
  var last = false;
  while (!last && i + 4 <= head.length) {
    final hdr = head[i];
    last = (hdr & 0x80) != 0;
    final len = _be24(head, i + 1);
    if (i + 4 + len > head.length) {
      // 该块被采样截断：后续块（可能是 VORBIS_COMMENT）还没读到，提示补到本块尾。
      return i + 4 + len;
    }
    i += 4 + len;
  }
  if (last) return null; // 块列表完整：标签与封面该有的都在采样内了
  return head.length * 4; // 还在块列表中途：下一个块头都没读到，放大一档
}

/// 字节范围读取器（起址 + 长度）→ 字节；读不满允许返回实际长度。
typedef AudioRangeReader = Future<Uint8List> Function(int start, int length);

/// 尾部补读提示（字节数，自文件末尾起）：
/// - m4a：moov 不在头部采样内（常见 moov-at-end）→ 先试 256KB，调用方逐级增大；
/// - ogg/opus：头部无法得时长，读末尾页取 granule → 64KB；
/// - wav/aiff：`data`/`SSND` 音频块之后可能还有 `id3 ` 块（ID3v2 标签与内嵌
///   封面，ffmpeg `-write_id3v2 1` 等工具就是这么写的）。这类容器的块头里写着
///   音频块的**声明长度**，所以能算出音频块之后的元数据区有多长，一次读准，
///   不必盲扫整个尾部；
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
    case 'wav':
      return _afterAudioChunkLen(head, fileSize, le: true);
    case 'aiff':
    case 'aif':
    case 'aifc':
      return _afterAudioChunkLen(head, fileSize, le: false);
    default:
      return null;
  }
}

/// wav（RIFF，小端块长）与 aiff（FORM，大端块长）的音频块之后还有多少字节。
///
/// 两种容器都是「块列表」：块头 4 字节 id + 4 字节声明长度 + 块体，音频块是
/// `data`（wav）/ `SSND`（aiff），工具追加的 ID3v2 标签一般在它**后面**。块头自带
/// 长度，所以按声明长度跳过音频块就能精确算出后面元数据区的起点与长度——不需要
/// 读音频数据，也不需要盲扫尾部。
///
/// 返回 null 表示「头部没给出足够信息算准」或「音频块之后没有别的块」。
int? _afterAudioChunkLen(Uint8List head, int fileSize, {required bool le}) {
  final audioId = le ? 'data' : 'SSND';
  var i = le ? 12 : 12; // RIFF/FORM 头都是 12 字节
  while (i + 8 <= head.length) {
    final id = String.fromCharCodes(head.sublist(i, i + 4));
    final size = le ? _le32(head, i + 4) : _be32(head, i + 4);
    if (size < 0) return null; // 声明长度异常（>2GB 的有符号溢出等），不猜
    final body = i + 8;
    if (id == audioId) {
      // 音频块之后（含 pad 字节）的长度；声明长度可疑时只信文件大小。
      final declaredEnd = body + size + (size.isOdd ? 1 : 0);
      if (declaredEnd <= body || declaredEnd >= fileSize) return null;
      final len = fileSize - declaredEnd;
      return len > kMetaRegionCapBytes ? kMetaRegionCapBytes : len;
    }
    // fmt / COMM 等其他块：头部采样内的按声明长度跳过，采样外的算不出来。
    if (body + size > head.length) return null;
    i = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
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
    case 'wav':
      return _parseRiffTail(tail, le: true);
    case 'aiff':
    case 'aif':
    case 'aifc':
      return _parseRiffTail(tail, le: false);
  }
  return null;
}

/// 解析尾读窗口内的 RIFF(wav, 小端)/FORM(aiff, 大端) 块列表。
///
/// 调用方读的窗口是 `[fileSize - tail.length, fileSize)`，也就是（按
/// [tailReadHint] 算出的）音频块之后的元数据区。取 `id3 `/`ID3 ` 块里的
/// ID3v2 标签（标题/歌手/专辑/年份/曲目/歌词/APIC 封面）；wav 的 `LIST INFO`
/// 块也一并解析（与头部同一套 [_parseWavInfo]）。
///
/// 两条路：
/// 1. **按块列表走**（正常情况）。窗口起点可能正好是容器头（窗口放大到覆盖
///    整个文件时），这时跳过 12 字节 RIFF/FORM 头再走。
/// 2. **兜底扫签名**：老设备的 RIFF 总长与 `data` 声明长度经常不准（写 0、
///    写 0xFFFFFFFF），块列表一旦对不上就再也走不下去。这时在窗口内找 `id3 `
///    标记，按 ID3v2 头里**自己声明的**长度校验（必须完整落在窗口内、至少能
///    解析出帧）才认，避免把音频数据里碰巧出现的 `id3 ` 误当标签。
///
/// 返回 null 表示窗口里没有可识别的标签——调用方据此放大窗口再试（见
/// [readAudioMeta] 的尾部阶梯）。
AudioMeta? _parseRiffTail(Uint8List tail, {required bool le}) {
  var i = 0;
  // 窗口起点可能是容器头本身（放大到覆盖整个文件时）。
  if (tail.length >= 12) {
    final magic = String.fromCharCodes(tail.sublist(0, 4));
    final kind = String.fromCharCodes(tail.sublist(8, 12));
    if ((magic == 'RIFF' && (kind == 'WAVE')) ||
        (magic == 'FORM' && (kind == 'AIFF' || kind == 'AIFC'))) {
      i = 12;
    }
  }
  var found = false;
  final meta = AudioMeta();
  while (i + 8 <= tail.length) {
    final id = String.fromCharCodes(tail.sublist(i, i + 4));
    final size = le ? _le32(tail, i + 4) : _be32(tail, i + 4);
    if (size < 0) break;
    final body = i + 8;
    if (body + size > tail.length) break; // 块体被窗口截断：窗口不够，交给上层放大
    if (id == 'id3 ' || id == 'ID3 ') {
      if (_applyId3Chunk(tail, body, body + size, meta)) found = true;
    } else if (le && id == 'LIST' && size >= 4 &&
        String.fromCharCodes(tail.sublist(body, body + 4)) == 'INFO') {
      _parseWavInfo(tail, body + 4, body + size, meta);
      found = true;
    }
    i = body + size + (size.isOdd ? 1 : 0);
  }
  if (found) return meta;
  return _scanId3ChunkInRiff(tail, meta);
}

/// 兜底：在 RIFF/FORM 尾部窗口内找 `id3 ` 块（块列表已对不上时用）。
///
/// 命中后按 ID3v2 头自己声明的长度校验：长度必须为正、完整落在窗口内，且至少
/// 解析出一个文本帧或封面——否则视为音频数据里的巧合字节。
AudioMeta? _scanId3ChunkInRiff(Uint8List tail, AudioMeta meta) {
  for (var i = 0; i + 10 <= tail.length; i++) {
    if (tail[i] != 0x69 && tail[i] != 0x49) continue; // 'i' / 'I'
    // 第二字节 'd' / 'D' 都认：小写 `id3 ` 与大写 `ID3 ` 块都常见
    //（写入器统一写大写 `ID3 `，与 mutagen AIFF 口径对齐；此前只认小写，
    // 大写块在窗口起点不对齐时会被漏检）。
    final d = tail[i + 1];
    if ((d != 0x64 && d != 0x44) || tail[i + 2] != 0x33) continue; // 'd'/'D' '3'
    if (tail[i + 3] != 0x20) continue; // ' '
    // i 是块 id 起点，块头 8 字节之后才是 ID3v2 头。
    final body = i + 8;
    final declared = 10 + _syncsafe(tail, body + 6);
    if (declared < 10 || body + declared > tail.length) continue; // 声明长度越界，不认
    if (_applyId3Chunk(tail, body, body + declared, meta)) {
      if (meta.title != null || meta.cover != null) return meta;
    }
  }
  return null;
}

/// 把位于 [start, end) 的 ID3v2 标签并入 [meta]（已有字段不覆盖）。
///
/// 复用 mp3 那套帧解析：切出以 'ID3' 开头的视图后，帧偏移与长度字段的
/// 相对位置就和 mp3 完全一致（版本/扩展头口径见 [_id3TagToFrames]）。
bool _applyId3Chunk(Uint8List b, int start, int end, AudioMeta meta) {
  if (end - start < 10) return false;
  if (b[start] != 0x49 || b[start + 1] != 0x44 || b[start + 2] != 0x33) {
    return false; // 不是 ID3v2（无 v1 支持：RIFF 容器里不写 ID3v1）
  }
  // 标签总长以块内 ID3 头声明为准，但不越过本块末尾。
  final declared = start + 10 + _syncsafe(b, start + 6);
  final tagEnd = declared > end ? end : declared;
  if (tagEnd <= start + 10) return false;
  final tag = Uint8List.sublistView(b, start, tagEnd);
  final frames = _id3TagToFrames(tag, 10);
  meta.title ??= frames['TIT2'];
  meta.artist ??= frames['TPE1'];
  meta.albumArtist ??= frames['TPE2'];
  meta.album ??= frames['TALB'];
  meta.genre ??= frames['TCON'];
  meta.year ??= _yearOf(frames['TYER'] ?? frames['TDRC']);
  meta.trackNo ??= _trackOf(frames['TRCK']);
  meta.lyrics ??= frames['USLT'];
  meta.cover ??= _apicOf(tag);
  return true;
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

/// 按结构定位元数据、**绝不整读**的统一读取流程（播放补读 / 后台补读共用）。
///
/// 策略来自「各格式的标签与封面都待在文件头尾附近的定长结构里」这一事实：
/// mp3 的 ID3v2 头里写着整个标签多长、flac 每个元数据块头里写着块多长、m4a 的
/// moov 原子头里写着原子多大。所以只要先读一小段做魔数识别，再顺着文件自己声明
/// 的长度去取，就足够拿全标签与封面，不需要碰音频数据本身。
///
/// 头部阶梯由 [coverReadHint] 单线驱动，反复重算直到「结构上到头」或触到
/// [kMetaRegionCapBytes]：
/// - **结构跳**：封面/标签块被采样截断时给出**文件自己声明的**结束位置，直接跳过去
///   （mp3 的 ID3v2 总长、flac 的块长）；
/// - **几何放大**：块列表/包表中途结束、算不出确切位置时按 4 倍放大一档。例如 FLAC
///   的 PICTURE 排在 VORBIS_COMMENT 之前——读完封面块后标题还在更后面，而下一块的
///   块头尚未读到，只能放大再解析一次。ogg 的 comment 包同理。
///
/// hint 返回 null 即「结构上到头」，此时不再放大（详见阶梯循环内的说明）。全程用
/// [kMetaRegionCapBytes] 封顶：声明值异常大的文件不会把读取撑到 GB 级。
///
/// **不存在**「采样不足就整读整个文件」这条退路——原实现有（`fullRead`），它会在
/// 后台补读链路上为拿几个标签把几十上百 MB 整首下下来，且命中的恰恰是大文件，
/// 代价与收益倒挂。
///
/// [readRange] 由调用方实现（本地文件 / WebDAV Range GET），读不满允许返回实际
/// 长度（阶梯据此停止，不会死循环）。
Future<AudioMeta?> readAudioMeta({
  required AudioRangeReader readRange,
  required String format,
  required int fileSize,
  int headBytes = 256 * 1024,
  ChunkYield? yieldTo,
}) async {
  // 片间让出（可选）：传 [yieldTo] 时每个解析阶段/阶梯轮次之间让出事件循环，
  // 配合「零拷贝封面视图 + base64 分片解码」，保证单次同步块 < 50ms（R-1/FR-001）。
  // 未传时行为与旧实现逐字节一致（扫描 / 单测路径）。
  Future<void> pump() async {
    if (yieldTo != null) await yieldTo();
  }

  var head = await readRange(0, headBytes);
  if (head.isEmpty) return null;
  perfPhase('meta.rm.headParse'); // TEMP-PROBE
  var meta = parseAudioHead(head, format, fileSize,
      deferCoverDecode: yieldTo != null);
  if (meta != null && yieldTo != null) {
    perfPhase('meta.rm.headCoverDecode'); // TEMP-PROBE
    await _finalizePendingCoverChunked(meta, yieldTo);
  }

  // ---- 头部阶梯 ----
  // 循环条件同时盯封面与标题：封面块读完了不等于元数据区读完了（PICTURE 可能
  // 排在 VORBIS_COMMENT 之前，这时标题在封面**后面**）。
  // 每一轮的目标一律由 [coverReadHint] 给出，不再另开「放大分支」：hint 为 null
  // 就表示结构上已到头（mp3 标签读完 / flac 块列表走完 / ogg comment 包完整 /
  // 无结构可循的格式），此时继续放大纯属白读——m4a 的 moov 在文件尾，走的是
  // 下面的尾部阶梯，不该在头部一路放大到上限。
  while (meta != null && (meta.cover == null || !_hasTitle(meta))) {
    final len = head.length;
    if (len >= kMetaRegionCapBytes) break;
    final hint = coverReadHint(head, format);
    if (hint == null) break; // 结构上到头：再读也拿不到更多头部元数据
    var target = hint;
    if (target > kMetaRegionCapBytes) target = kMetaRegionCapBytes;
    if (target <= len) break;
    await pump(); // 让出：补读更大头部窗口之前
    // 增量拼接：只读 [len, target) 新增段再拼上已读头部。旧实现每级都
    // `readRange(0, target)` 从头重下——多级阶梯（如 2.1MB→11MB→16MB）会
    // 把大封面区重复下载近一倍；SFTP 上每字节都要主线程纯 Dart 解密，代价
    // 直接放大成卡顿（真机 2026-10-11 取证）。
    final more = await readRange(len, target - len);
    if (more.isEmpty) break; // 文件已到底：停，避免死循环
    final deeper = Uint8List(len + more.length)
      ..setRange(0, len, head)
      ..setRange(len, len + more.length, more);
    perfPhase('meta.rm.ladderParse'); // TEMP-PROBE
    final parsed = parseAudioHead(deeper, format, fileSize,
        deferCoverDecode: yieldTo != null);
    if (parsed != null) {
      meta = parsed;
      if (yieldTo != null) {
        perfPhase('meta.rm.ladderCoverDecode'); // TEMP-PROBE
        await _finalizePendingCoverChunked(meta, yieldTo);
      }
    }
    head = deeper;
  }

  // ---- 尾部阶梯：moov-at-end / ogg·opus 时长 / mp3 ID3v1 兜底 ----
  // 入口条件与原先一致：还缺封面或缺时长才需要尾读（标签与封面在头部拿全时
  // 不必为确认时长再多读一次——那是一次覆盖尾部的 Range 请求）。
  if (meta == null || meta.cover == null || meta.duration == null) {
    final first = tailReadHint(head, format, fileSize);
    if (first != null && first > 0) {
      var tailLen = first;
      while (true) {
        final len = tailLen > fileSize ? fileSize : tailLen;
        final start = fileSize - len;
        if (start < 0 || len <= 0) break;
        await pump(); // 让出：尾部补读之前
        final tail = await readRange(start, len);
        perfPhase('meta.rm.tailParse'); // TEMP-PROBE
        final t = parseAudioTail(tail, format, fileSize, headMeta: meta);
        if (t != null) {
          meta = _mergeMeta(meta, t);
          break;
        }
        if (!_tailEscalates(format)) break;
        // 尾读窗口不够：moov 可能整个落在采样之外，或 wav/aiff 的元数据块在
        // 音频块之后且第一个窗口没覆盖住；逐级放大尾读窗口，上限与头部同一套
        // 声明值边界。
        final next = len * 4;
        if (next <= len || next > kMetaRegionCapBytes || len >= fileSize) break;
        tailLen = next;
      }
    }
  }
  return meta;
}

/// 同步一步到位解码待定封面（默认路径，逐字节与旧实现一致）。
void _finalizePendingCoverSync(AudioMeta meta) {
  final b64 = meta.pendingCoverB64;
  meta.pendingCoverB64 = null;
  if (b64 == null || b64.isEmpty || meta.cover != null) return;
  try {
    _applyDecodedCover(meta, base64Decode(b64));
  } catch (_) {
    // 解码失败 = 该内嵌封面不可用（与旧实现一致：静默放弃，不影响其它标签）。
  }
}

/// 分片解码待定封面（让出版）：base64 按 4 字符对齐切段逐段解码，段间让出
/// 事件循环——大内嵌封面（可达数 MB）不再整块同步解码占用主线程。
Future<void> _finalizePendingCoverChunked(AudioMeta meta, ChunkYield yieldTo) async {
  final b64 = meta.pendingCoverB64;
  meta.pendingCoverB64 = null;
  if (b64 == null || b64.isEmpty || meta.cover != null) return;
  try {
    _applyDecodedCover(meta, await _decodeBase64Chunked(b64, yieldTo));
  } catch (_) {
    // 同 [_finalizePendingCoverSync]：静默放弃。
  }
}

/// 把解码出的字节按原键口径落到 [AudioMeta.cover]（PICTURE 结构 / 裸图片）。
void _applyDecodedCover(AudioMeta meta, Uint8List img) {
  if (meta.pendingCoverIsFlacPicture) {
    meta.cover = _parseFlacPicture(img);
  } else if (isCompleteImageBytes(img)) {
    meta.cover = img;
  }
}

/// base64 分片解码：按 4 字符（= 3 字节）对齐切片，每片可独立解码（非末段不含
/// 填充，末段含可能的 `=` 填充），段间 [yieldTo] 让出。长度不足一片时一步解码。
Future<Uint8List> _decodeBase64Chunked(String s, ChunkYield yieldTo) async {
  const segChars = 4096 * 4; // 4 的倍数：base64 以 4 字符为一个可独立解码单元
  if (s.length <= segChars) return base64Decode(s);
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < s.length) {
    final end = (i + segChars) < s.length ? i + segChars : s.length;
    out.add(base64Decode(s.substring(i, end)));
    i = end;
    if (i < s.length) await yieldTo();
  }
  return out.takeBytes();
}

/// 是否已从头部拿到可用标题（几何放大的停止条件）。
bool _hasTitle(AudioMeta meta) =>
    meta.title != null && meta.title!.isNotEmpty;

/// 尾读窗口不够时是否值得放大重试。
///
/// 只有「尾部元数据可能整体落在首个窗口之外」的格式才放大：
/// - m4a/mp4：moov-at-end 时 moov 可能整个在采样之外；
/// - wav/aiff：`id3 ` 块在音频块之后，声明长度可疑（如 RIFF 总长写 0）时
///   [tailReadHint] 只能给一个保守窗口，块体更大就得放大才能读全。
/// mp3（ID3v1 固定 128B）、ogg（末页 granule 在 64KB 内）不需要。
bool _tailEscalates(String format) => switch (format) {
      'm4a' || 'mp4' || 'wav' || 'aiff' || 'aif' || 'aifc' => true,
      _ => false,
    };

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
  final flacStart = _flacMagicOffset(head);
  if (flacStart < 0) return meta;
  var i = flacStart + 4;
  bool last = false;
  while (!last && i + 4 <= head.length) {
    final hdr = head[i];
    last = (hdr & 0x80) != 0;
    final blockType = hdr & 0x7F;
    final len = _be24(head, i + 1);
    if (i + 4 + len > head.length) break;
    final body = Uint8List.sublistView(head, i + 4, i + 4 + len); // 零拷贝
    // 只取 VORBIS_COMMENT（标题/歌手/专辑所在地）；STREAMINFO/PICTURE 跳过。
    if (blockType == 4) _parseVorbisComment(body, meta);
    i += 4 + len;
  }
  // 前置 ID3v2 兜底（MusicPlayer2/TagLib 的 union 读口径：Xiph 优先、ID3 补缺）。
  _applyFlacId3Fallback(head, meta, allowLyrics: false);
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
///
/// 版本口径（ID3v2.3 vs v2.4）：
/// - 标签头总长永远 syncsafe（两版本一致）；
/// - 帧体长度 v2.4 为 syncsafe，v2.3 为普通 BE32（本文件此前统一按 syncsafe
///   解，大 APIC 如 `BE=53178/syncsafe=10170` 会被截断成半图丢弃，其后帧也对不上）。
/// - v2.2（3 字节 ID + BE24，帧头 6B）明确不支持：直接回空，上层走文件名回退。
/// - 起始帧按版本跳过扩展头（见 [_id3FramesStart]），越界一律回退 base+10、不抛。
Map<String, String> _id3TagToFrames(Uint8List head, int tagStart) {
  final out = <String, String>{};
  final base = tagStart - 10;
  final version = _id3VersionAt(head, base);
  if (version == 2) return out;
  final framesStart = _id3FramesStart(head, base);
  var i = framesStart < tagStart ? tagStart : framesStart;
  // 头部采样可能短于 ID3 tag 声明长度（如内嵌封面很大），以实际字节数为界，
  // 避免 sublist 越界抛 RangeError。
  final declared = base + 10 + _syncsafe(head, base + 6);
  final limit = declared < head.length ? declared : head.length;
  if (i < base + 10) i = base + 10;
  while (i + 10 <= limit) {
    final id = String.fromCharCodes(head.sublist(i, i + 4)).trim();
    if (id.isEmpty || id.codeUnitAt(0) == 0) break;
    final size = _id3FrameSize(head, i + 4, version);
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
  const base = 0;
  final version = _id3VersionAt(head, base);
  if (version == 2) return null;
  var i = _id3FramesStart(head, base);
  if (i < base + 10) i = base + 10;
  final limit = base + 10 + _syncsafe(head, base + 6);
  while (i + 10 <= limit && i + 10 + 4 <= head.length) {
    final id = String.fromCharCodes(head.sublist(i, i + 4)).trim();
    if (id.isEmpty || id.codeUnitAt(0) == 0) break;
    final size = _id3FrameSize(head, i + 4, version);
    if (size < 0 || i + 10 + size > head.length) break;
    if (id == 'APIC' && size > 8) {
      // 零拷贝视图：封面可达数 MB，避免 fromList/sublist 的整块复制占用主线程
      //（主线程长同步块治理 R-1，解析阶段的字节区间切片）。
      final img = _apicImage(Uint8List.sublistView(head, i + 10, i + 10 + size));
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
Uint8List? _apicImage(Uint8List data) {
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
  final img = Uint8List.sublistView(data, p); // 零拷贝：图片字节直接切视图
  // 轻量完整性：断流导致的半图只有头签名、尾缺失，必须拒收（否则落盘半图）。
  return isCompleteImageBytes(img) ? img : null;
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

/// 轻量完整性校验（问题1修复：只验头会导致半图落盘）。
///
/// 在 [looksLikeImageBytes] 通过的基础上再验“尾”：
/// - JPEG：尾 2 字节须为 EOI `FF D9`；
/// - PNG：尾 4 字节须为 IEND CRC `AE 42 60 82`；
/// - GIF：尾字节须为 `3B`；
/// - BMP：头声明大小须等于实际长度（声明为 0 时无法校验，按通过）；
/// - WEBP：RIFF 声明大小 +8 须等于实际长度（声明为 0 时按通过）；
/// - ftyp（HEIF/AVIF）：无廉价尾判，按头通过。
///
/// 故意不做全图解码（CPU 开销大）：断流/截断的半图尾必然缺失，轻量尾判即可
/// 拦截；误杀（尾部带填充的罕见合法图）宁可当“读不全”重试，也不写坏缓存。
bool isCompleteImageBytes(List<int> b) {
  if (!looksLikeImageBytes(b)) return false;
  if (b[0] == 0xFF && b[1] == 0xD8) {
    // JPEG：EOI 收尾。
    return b.length >= 2 &&
        b[b.length - 2] == 0xFF &&
        b[b.length - 1] == 0xD9;
  }
  if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
    // PNG：IEND 块尾。
    final n = b.length;
    return n >= 12 &&
        b[n - 4] == 0xAE &&
        b[n - 3] == 0x42 &&
        b[n - 2] == 0x60 &&
        b[n - 1] == 0x82;
  }
  if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    // GIF：trailer 0x3B 收尾。
    return b[b.length - 1] == 0x3B;
  }
  if (b[0] == 0x42 && b[1] == 0x4D) {
    // BMP：头 2..5 为小端文件大小。
    if (b.length < 6) return false;
    final declared =
        b[2] | (b[3] << 8) | (b[4] << 16) | (b[5] << 24);
    if (declared == 0) return true;
    return declared == b.length;
  }
  if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) {
    // WEBP：RIFF 大小 +8 == 文件长。
    if (b.length < 12) return false;
    final riff = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24);
    if (riff == 0) return true;
    return riff + 8 == b.length;
  }
  return true; // ftyp：无廉价尾判
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
  final flacStart = _flacMagicOffset(head);
  if (flacStart < 0) return meta;
  var i = flacStart + 4;
  bool last = false;
  int? sampleRate;
  int? totalSamples;
  var sawVorbisEntries = false;
  while (!last && i + 4 <= head.length) {
    final hdr = head[i];
    last = (hdr & 0x80) != 0;
    final blockType = hdr & 0x7F;
    final len = _be24(head, i + 1);
    // 元数据块可能超出头部采样长度（如大内嵌封面），此时无法继续解析后续块。
    if (i + 4 + len > head.length) break;
    // 零拷贝视图：块体（可含大 PICTURE）不复制，解析只读前段结构。
    final body = Uint8List.sublistView(head, i + 4, i + 4 + len);
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
      if (_vorbisCommentEntryCount(body) > 0) sawVorbisEntries = true;
      _parseVorbisComment(body, meta);
    } else if (blockType == 6) {
      // PICTURE（MusicPlayer2/TagLib 口径：FLAC 封面只认块列表里的 PICTURE，
      // 前置 ID3v2 的 APIC 不读）
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
  // 前置 ID3v2 兜底：歌词只在 FLAC 完全没有 Vorbis 条目时取 USLT——对应
  // MusicPlayer2/TagLib 的 `properties()` 只取“第一个非空标签”的规则。
  _applyFlacId3Fallback(head, meta, allowLyrics: !sawVorbisEntries);
  return meta;
}

/// 前置 ID3v2 标签总长（无标签/头不完整返回 0）。
///
/// FLAC 规范不允许 ID3v2 前置，但部分老工具会这么写；MusicPlayer2 使用的
/// TagLib 明确支持（`read()` 先找 ID3v2，再从标签末尾找 `fLaC`），读侧照此
/// 口径容忍。
int _leadingId3v2Len(Uint8List head) {
  if (head.length < 10 ||
      head[0] != 0x49 ||
      head[1] != 0x44 ||
      head[2] != 0x33) {
    return 0;
  }
  final len = 10 + _syncsafe(head, 6) + ((head[5] & 0x10) != 0 ? 10 : 0);
  return len > 0 ? len : 0;
}

/// FLAC 魔数偏移：标准文件为 0；前置 ID3v2 时从其声明长度之后找 `fLaC`
/// （TagLib 的 `find("fLaC", ID3v2Location + ID3v2OriginalSize)` 同口径）。
/// 找不到返回 -1。
int _flacMagicOffset(Uint8List head) {
  if (head.length >= 4 && _startsWith(head, 'fLaC'.codeUnits)) return 0;
  final id3Len = _leadingId3v2Len(head);
  if (id3Len <= 0) return -1;
  for (var i = id3Len; i + 4 <= head.length; i++) {
    if (head[i] == 0x66 &&
        head[i + 1] == 0x4C &&
        head[i + 2] == 0x61 &&
        head[i + 3] == 0x43) {
      return i;
    }
  }
  return -1;
}

/// Vorbis comment 条目数（vendor 之后 u32；越界/伪造 count 按 0）。
int _vorbisCommentEntryCount(List<int> b) {
  if (b.length < 8) return 0;
  final vendorLen = _le32(b, 0);
  final p = 4 + vendorLen;
  if (vendorLen < 0 || p + 4 > b.length) return 0;
  final n = _le32(b, p);
  if (n <= 0) return 0;
  // 至少有一个完整条目才算「非空」：声明 count 但条目截断时不能屏蔽 ID3 兜底。
  final q = p + 4;
  if (q + 4 > b.length) return 0;
  final len = _le32(b, q);
  if (len < 0 || q + 4 + len > b.length) return 0;
  return n;
}

/// 把前置 ID3v2 的文本帧按“Xiph 优先、ID3 补缺”并入 [meta]。
///
/// 对应 MusicPlayer2 `GetFlacTagInfo` 的 union 取值与 `GetFlacPropertyMap`
/// 的键级兜底；封面不在此处处理（TagLib 的 `pictureList()` 不读 APIC）。
void _applyFlacId3Fallback(Uint8List head, AudioMeta meta,
    {required bool allowLyrics}) {
  if (_leadingId3v2Len(head) <= 0) return;
  final frames = _id3TagToFrames(head, 10);
  if (frames.isEmpty) return;
  meta.title ??= frames['TIT2'];
  meta.artist ??= frames['TPE1'];
  meta.albumArtist ??= frames['TPE2'];
  meta.album ??= frames['TALB'];
  meta.genre ??= frames['TCON'];
  meta.year ??= _yearOf(frames['TYER'] ?? frames['TDRC']);
  meta.trackNo ??= _trackOf(frames['TRCK']);
  if (allowLyrics && meta.lyrics == null) {
    final lyrics = frames['USLT'];
    if (lyrics != null && lyrics.trim().isNotEmpty) meta.lyrics = lyrics;
  }
}

void _parseVorbisComment(List<int> body, AudioMeta meta) {
  _parseVorbisComments(body, meta, includePicture: true);
}

Uint8List? _parseFlacPicture(Uint8List body) {
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
  final img = Uint8List.sublistView(body, p, p + dataLen); // 零拷贝
  return isCompleteImageBytes(img) ? img : null;
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
            final img = Uint8List.sublistView(b, payloadStart, payloadEnd); // 零拷贝
            if (isCompleteImageBytes(img)) meta.cover = img;
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
  meta.pendingCoverB64 = null; // 最小解析不用封面：丢弃待定 base64（保持旧行为）
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
  Uint8List body;
  if (isVorbis && _startsWith(tags, [0x03, ...'vorbis'.codeUnits])) {
    body = Uint8List.sublistView(tags, 7); // 零拷贝
  } else if (isOpus && _startsWith(tags, 'OpusTags'.codeUnits)) {
    body = Uint8List.sublistView(tags, 8); // 零拷贝
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
        if (includePicture && meta.cover == null && meta.pendingCoverB64 == null) {
          // 只登记 base64，解码挪到解析末尾（同步或分片），不占用解析热路径。
          meta.pendingCoverB64 = val.trim();
          meta.pendingCoverIsFlacPicture = true;
        }
        break;
      case 'COVERART':
        if (includePicture && meta.cover == null && meta.pendingCoverB64 == null) {
          meta.pendingCoverB64 = val.trim();
          meta.pendingCoverIsFlacPicture = false;
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
    } else if (id == 'id3 ' || id == 'ID3 ') {
      // 也有工具把 ID3v2 放在音频块**之前**（wav 标签位置不固定）。
      if (body + size <= head.length) _applyId3Chunk(head, body, body + size, meta);
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

// ---------- AIFF / AIFC（FORM 容器，大端块长）----------

/// AIFF / AIFC：`FORM....AIFF|AIFC` 块列表，**大端**块长。
///
/// 与 WAV 同源但字节序相反，且没有 `LIST INFO` 那套 RIFF 文本标签——文本信息
/// 全靠尾部（或头部）的 `ID3 ` 块里的 ID3v2，所以本函数只负责：
/// - `COMM` 块 → 时长（采样帧数 ÷ 采样率，采样率是 80 位扩展浮点）；
/// - `NAME`/`AUTH`（`AIFC` 是 `ANNO`）块 → 名称/作者，兜底标题；
/// - 头部采样内的 `ID3 ` 块 → 标签与封面（与 mp3 共用 ID3v2 规范）。
/// 音频块 `SSND` 之后的标签由尾部阶梯负责（见 [tailReadHint]）。
AudioMeta _parseAiff(Uint8List head) {
  final meta = AudioMeta();
  if (head.length < 12 || !_startsWith(head, 'FORM'.codeUnits)) return meta;
  final kind = String.fromCharCodes(head.sublist(8, 12));
  if (kind != 'AIFF' && kind != 'AIFC') return meta;
  var i = 12;
  while (i + 8 <= head.length) {
    final id = String.fromCharCodes(head.sublist(i, i + 4));
    final size = _be32(head, i + 4);
    if (size < 0) break;
    final body = i + 8;
    if (body + size > head.length) break;
    if (id == 'COMM' && size >= 18) {
      // COMM: numChannels(2) numSampleFrames(4) sampleSize(2) sampleRate(10 扩展浮点)
      final frames = _be32(head, body + 2);
      final rate = _ieee80ToDouble(head, body + 8);
      if (rate > 0) meta.sampleRate = rate.round();
      if (rate > 0 && frames > 0) meta.duration = (frames / rate).round();
    } else if (id == 'ID3 ' || id == 'id3 ') {
      _applyId3Chunk(head, body, body + size, meta);
    } else if (id == 'NAME' || id == 'AUTH' || id == 'ANNO') {
      final v = utf8
          .decode(head.sublist(body, body + size), allowMalformed: true)
          .replaceAll('\u0000', '')
          .trim();
      if (v.isNotEmpty) {
        if (id == 'NAME') {
          meta.title ??= v;
        } else {
          meta.artist ??= v;
        }
      }
    }
    i = body + size + (size.isOdd ? 1 : 0);
  }
  return meta;
}

AudioMeta _parseAiffMinimal(Uint8List head) {
  final meta = _parseAiff(head);
  meta.duration = null;
  return meta;
}

/// 80 位 IEEE 扩展精度浮点（AIFF 的采样率用这种编码）→ double。
///
/// 格式：1 位符号 + 15 位指数（偏移 16383）+ 64 位尾数（隐含最高位 1），
/// 指数 0 且尾数 0 表示 0，指数 0 而尾数非 0 是非规格化数。
double _ieee80ToDouble(Uint8List b, int o) {
  if (o + 10 > b.length) return 0;
  final exp = ((b[o] & 0x7F) << 8) | b[o + 1];
  var mant = 0.0;
  for (var i = 0; i < 8; i++) {
    mant = mant * 256 + b[o + 2 + i];
  }
  if (exp == 0 && mant == 0) return 0;
  final sign = (b[o] & 0x80) != 0 ? -1.0 : 1.0;
  // 尾数隐含最高位 1（即 64 位当作 [1,2) 区间）→ 指数再减 63。
  final e = exp == 0 ? -16382 - 63 : exp - 16383 - 63;
  return sign * mant * _pow2(e);
}

double _pow2(int n) {
  var r = 1.0;
  if (n >= 0) {
    for (var i = 0; i < n; i++) {
      r *= 2;
    }
  } else {
    for (var i = 0; i < -n; i++) {
      r /= 2;
    }
  }
  return r;
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

/// ID3v2 主版本号（`base` 为 `ID3` 头起点，正常 0，RIFF 尾块为块内偏移）。
/// 越界/无头时按 4 回退（保持旧行为，避免误伤存量 v2.4 单测）。
int _id3VersionAt(List<int> b, int base) {
  if (base < 0 || base + 4 > b.length) return 4;
  return b[base + 3];
}

/// 帧体长度按版本分派：v2.4 syncsafe，v2.3（含其它未知版本）普通 BE32。
/// 小帧两者相等，大 APIC 才分叉（如 `BE=53178/syncsafe=10170`）。
int _id3FrameSize(List<int> b, int o, int version) =>
    version == 4 ? _syncsafe(b, o) : _be32(b, o);

/// 首帧起点：按版本跳过扩展头，越界/声明异常一律回退 `base+10`、不抛。
///
/// - 无扩展头（`flags bit6==0`）→ `base+10`；
/// - v2.3：扩展头大小为 BE32 且**不含自身 4B**（正常 6/10），起点 `base+10+4+s`；
/// - v2.4：扩展头大小为 syncsafe 且**为整个扩展头长**（最小 6），起点 `base+10+s`。
int _id3FramesStart(List<int> b, int base) {
  const fallback = 10;
  if (base < 0 || base + 10 > b.length) return base + fallback;
  final version = _id3VersionAt(b, base);
  final flags = b[base + 5];
  if ((flags & 0x40) == 0) return base + fallback;
  if (base + 14 > b.length) return base + fallback;
  if (version == 3) {
    final s = _be32(b, base + 10);
    if (s < 6 || s > kMetaRegionCapBytes) return base + fallback;
    return base + 10 + 4 + s;
  } else if (version == 4) {
    final s = _syncsafe(b, base + 10);
    if (s < 6 || s > kMetaRegionCapBytes) return base + fallback;
    return base + 10 + s;
  }
  return base + fallback;
}

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
