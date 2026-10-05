import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:selfmusic/utils/cover_thumb.dart';

void main() {
  test('缩略图落盘：大图缩到 768 长边并进入展示路径', () async {
    final dir = await Directory.systemTemp.createTemp('selfmusic_thumb_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cover = File('${dir.path}/abc.jpg');
    // 1600×800 的纯色 JPEG：应被缩到 768×384。
    final big = img.Image(width: 1600, height: 800);
    img.fill(big, color: img.ColorRgb8(30, 120, 200));
    cover.writeAsBytesSync(img.encodeJpg(big, quality: 90));

    expect(coverDisplayPath(cover.path), cover.path);

    await ensureCoverThumb(cover.path);

    final thumb = File(coverThumbPathFor(cover.path));
    expect(thumb.existsSync(), isTrue);
    final decoded = img.decodeImage(thumb.readAsBytesSync())!;
    expect(decoded.width, kCoverThumbMaxEdge);
    expect(decoded.height, kCoverThumbMaxEdge ~/ 2);
    expect(coverDisplayPath(cover.path), thumb.path);
  });

  test('小图也归一为 JPEG 缩略图（PNG 原图不再按原格式解码）', () async {
    final dir = await Directory.systemTemp.createTemp('selfmusic_thumb_small_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cover = File('${dir.path}/small.jpg');
    final small = img.Image(width: 200, height: 200);
    img.fill(small, color: img.ColorRgb8(10, 200, 60));
    cover.writeAsBytesSync(img.encodePng(small));

    await ensureCoverThumb(cover.path);

    final thumb = File(coverThumbPathFor(cover.path));
    expect(thumb.existsSync(), isTrue);
    final decoded = img.decodeImage(thumb.readAsBytesSync())!;
    expect(decoded.width, 200);
    expect(decoded.height, 200);
  });

  test('非图片 / 不存在的封面：不生成缩略图且不抛错', () async {
    final dir = await Directory.systemTemp.createTemp('selfmusic_thumb_bad_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bad = File('${dir.path}/bad.jpg')..writeAsBytesSync([1, 2, 3, 4]);

    await ensureCoverThumb(bad.path);
    await ensureCoverThumb('${dir.path}/missing.jpg');

    expect(File(coverThumbPathFor(bad.path)).existsSync(), isFalse);
    expect(coverDisplayPath(bad.path), bad.path);
  });
}
