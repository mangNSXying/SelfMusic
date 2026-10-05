import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'off_thread.dart';

/// 列表/卡片用封面缩略图：落盘最长边 768 的 JPEG。
///
/// 原图（`covers/<md5>.jpg`）可能是上千像素的大图，列表每行解码全尺寸是滑动期
/// 的主要 CPU/内存开销来源。缩略图与封面同目录同名再带 `.thumb`
/// （`<md5>.jpg` → `<md5>.thumb.jpg`），播放页等大尺寸场景继续用原图。
const int kCoverThumbMaxEdge = 768;
const int kCoverThumbQuality = 82;

/// 缩略图路径约定：与封面同目录、同名 + `.thumb`。
String coverThumbPathFor(String coverPath) {
  final dir = p.dirname(coverPath);
  final base = p.basenameWithoutExtension(coverPath);
  return p.join(dir, '$base.thumb.jpg');
}

/// 解析结果缓存（原图路径 → 实际可用路径），避免每行 build 做文件存在性检查。
final Map<String, String> _displayPathCache = {};

/// 已确认存在的缩略图（生成完成或首查命中）。
final Set<String> _thumbReady = {};

/// 正在生成的缩略图（去重并发生成同一首）。
final Set<String> _thumbInflight = {};

/// 列表/卡片应显示的封面路径：缩略图已生成/已存在时用它，否则退回原图。
///
/// 每条原图路径只做一次文件存在性检查（结果进内存缓存）。
String coverDisplayPath(String coverPath) {
  final cached = _displayPathCache[coverPath];
  if (cached != null) return cached;
  final thumb = coverThumbPathFor(coverPath);
  final usable = _thumbReady.contains(thumb) || File(thumb).existsSync();
  if (usable) _thumbReady.add(thumb);
  final path = usable ? thumb : coverPath;
  _displayPathCache[coverPath] = path;
  return path;
}

/// 确保 [coverPath] 有对应缩略图；不存在则后台 isolate 生成（幂等、去重）。
///
/// 失败/非图片时静默保留原图：缩略图是纯优化，不向上抛错、不影响补读标已读。
Future<void> ensureCoverThumb(String coverPath) async {
  final thumb = coverThumbPathFor(coverPath);
  if (_thumbReady.contains(thumb) || File(thumb).existsSync()) {
    _thumbReady.add(thumb);
    _displayPathCache[coverPath] = thumb;
    return;
  }
  if (!_thumbInflight.add(thumb)) return;
  try {
    final src = File(coverPath);
    if (!src.existsSync()) return;
    final bytes = await src.readAsBytes();
    final encoded =
        await runOffThread<Uint8List?>(() => encodeCoverThumb(bytes));
    if (encoded == null) return;
    File(thumb).writeAsBytesSync(encoded, flush: true);
    _thumbReady.add(thumb);
    _displayPathCache[coverPath] = thumb;
  } catch (_) {
    // 缩略图失败不抛出：继续用原图。
  } finally {
    _thumbInflight.remove(thumb);
  }
}

/// 删除封面时一并删掉派生缩略图（清理无效封面用），避免孤儿文件。
void deleteCoverThumb(String coverPath) {
  final thumb = coverThumbPathFor(coverPath);
  _thumbReady.remove(thumb);
  _displayPathCache.remove(coverPath);
  try {
    final f = File(thumb);
    if (f.existsSync()) f.deleteSync();
  } catch (_) {
    // 删不掉就留着，下次覆盖写。
  }
}

/// 解码 + 缩放 + 重编码为缩略图 JPEG（纯 Dart，供 [runOffThread] 调用）。
///
/// 解码失败（脏数据/不支持的格式）返回 null，调用方退回原图。
Uint8List? encodeCoverThumb(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  // EXIF 方向先烘焙进像素，否则手机竖拍封面缩略图会躺倒。
  final baked = img.bakeOrientation(decoded);
  final maxEdge = math.max(baked.width, baked.height);
  final resized = maxEdge <= kCoverThumbMaxEdge
      ? baked
      : baked.width >= baked.height
          ? img.copyResize(baked, width: kCoverThumbMaxEdge)
          : img.copyResize(baked, height: kCoverThumbMaxEdge);
  return img.encodeJpg(resized, quality: kCoverThumbQuality);
}
