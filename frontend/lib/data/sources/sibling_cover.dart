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

/// 只接受通过图片签名校验的字节（与嵌入封面同一防线）。
bool isImageBytes(List<int> bytes) =>
    bytes.length >= 12 && looksLikeImageBytes(bytes);

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
    await for (final chunk in opened.stream) {
      bytes.addAll(chunk);
      if (bytes.length >= kCoverReadCapBytes) break;
    }
    if (!isImageBytes(bytes)) {
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
