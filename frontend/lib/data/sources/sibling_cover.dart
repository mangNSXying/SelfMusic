import 'dart:typed_data';

import '../../models/song.dart';
import '../local/audio_metadata.dart';
import 'music_source.dart';

/// 同目录图片候选（顺序即优先级）：同名图片 → 常见封面名。
///
/// 例：`Music/Album/01 song.flac` →
/// `01 song.png` … → `Music/Album/cover.jpg` → `folder.jpg` → …
List<String> siblingImageCandidates(String ref) {
  final slash = ref.lastIndexOf('/');
  final dir = slash >= 0 ? ref.substring(0, slash + 1) : '';
  final name = slash >= 0 ? ref.substring(slash + 1) : ref;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  return [
    if (stem.isNotEmpty)
      for (final ext in const [
        '.png', '.jpg', '.jpeg', '.webp', '.PNG', '.JPG',
      ])
        '$dir$stem$ext',
    for (final n in const [
      'cover.jpg', 'cover.png', 'folder.jpg', 'folder.png',
      'front.jpg', 'album.jpg',
    ])
      '$dir$n',
  ];
}

/// 只接受**完整**的图片字节。
///
/// [totalLength] 是资源的真实总长度（[OpenedStream.totalLength]，未知传 null）。
/// 返回 false 的三种情况：
/// - 读到的字节连图片签名都不像（不是图片，或被截断在签名之前）；
/// - 读到的字节**少于真实总长度**（服务端/上限把图截断了）；
/// - 图片尾缺失（轻量完整性 [isCompleteImageBytes] 不通过）：流提前断开时
///   `totalLength` 可能为 null（WebDAV 无 Content-Range），此时靠尾判拦截半图。
///
/// 第三条是关键：只看前 12 字节签名的话，一张 20MB 的图被 8MB 上限截断后照样
/// 通过校验并落盘，Android `ImageDecoder` 解码失败 → 界面上一张封面都没有，而且
/// 这行已被标成「已读」，再也不会重试。宁可判定「这张图太大/读不全」也不要写坏
/// 缓存。
bool isImageBytes(List<int> bytes, {int? totalLength}) {
  if (bytes.length < 12 || !looksLikeImageBytes(bytes)) return false;
  if (totalLength != null && totalLength > bytes.length) return false;
  if (!isCompleteImageBytes(bytes)) return false;
  return true;
}

/// 会话级缓存：候选 ref → 字节/null（否定缓存避免反复探测）。
final Map<String, Uint8List?> _siblingCache = {};

/// 同目录图片回退（播放补读用）：按候选顺序尝试读取，命中即返回。
///
/// 每首歌/每个候选都按 `sourceKey|ref` 缓存（含否定结果），整库补读时
/// 同目录的 `cover.jpg` 只探测一次；同名图片各自独立缓存。
Future<Uint8List?> fetchSiblingImage(MusicSource src, Song song) async {
  final key = '${src.key}\u0000${song.sourceRef}';
  if (_siblingCache.containsKey(key)) return _siblingCache[key];
  for (final cand in siblingImageCandidates(song.sourceRef)) {
    final bytes = await _tryReadImage(src, song, cand);
    if (bytes != null) {
      _siblingCache[key] = bytes;
      return bytes;
    }
  }
  _siblingCache[key] = null;
  return null;
}

Future<Uint8List?> _tryReadImage(
    MusicSource src, Song song, String candRef) async {
  final key = '${src.key}\u0000$candRef';
  if (_siblingCache.containsKey(key)) return _siblingCache[key];
  try {
    final probe = Song.direct(
      id: song.id,
      sourceKey: song.sourceKey,
      title: song.title,
      source: song.source,
      sourceRef: candRef,
      fileSize: 0,
      format: 'img',
    );
    final opened =
        await src.open(probe, range: const IntRange(0, kCoverReadCapBytes));
    final bytes = <int>[];
    var hitCap = false;
    await for (final chunk in opened.stream) {
      bytes.addAll(chunk);
      if (bytes.length >= kCoverReadCapBytes) {
        hitCap = true;
        break;
      }
    }
    // 截断判定：拿到上限说明可能只读到片段；流自然结束但短于资源真实大小，说明
    // 服务端提前断了。两种情况都当「这张图读不全」，不落盘（详见 [isImageBytes]）。
    final total = opened.totalLength;
    final maybeTruncated = hitCap || (total != null && total > bytes.length);
    if (maybeTruncated || !isImageBytes(bytes, totalLength: total)) {
      _siblingCache[key] = null;
      return null;
    }
    final img = Uint8List.fromList(bytes.sublist(0, bytes.length));
    _siblingCache[key] = img;
    return img;
  } catch (_) {
    // 不存在/无权限：否定缓存，避免同会话反复请求。
    _siblingCache[key] = null;
    return null;
  }
}

/// 测试/换源后清理会话缓存。
void clearSiblingImageCache() => _siblingCache.clear();
