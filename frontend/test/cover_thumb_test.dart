import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:selfmusic/utils/cover_thumb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('原生分支（测试开关 + mock 通道，ohos-thumb-native-decode）', () {
    const channel = MethodChannel('selfmusic/platform');

    /// mock 侧收到的调用记录。
    final calls = <MethodCall>[];

    /// 注册 mock：统一记录调用后交 [responder] 应答（覆盖前一次注册）。
    void mockThumb(Future<Object?>? Function(MethodCall call) responder) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return await responder(call);
      });
    }

    setUp(() {
      // 宿主（Windows）的 operatingSystem 恒非 'ohos'：必须置测试开关才能
      // 覆盖原生分支（plan.md R-7 flag 注入策略）。
      forceNativeThumbInTests = true;
      calls.clear();
    });

    tearDown(() {
      forceNativeThumbInTests = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('桥成功 → 缓存/展示路径切到缩略图，且不读原图字节', () async {
      mockThumb((call) async => true);
      final dir =
          await Directory.systemTemp.createTemp('selfmusic_thumb_nat_ok_');
      addTearDown(() => dir.deleteSync(recursive: true));
      // 原图写成脏数据：若误走纯 Dart 路径，decodeImage 必然失败、缓存不会
      // 切换——以此锁定「原生分支不读原图字节、不跑 encodeCoverThumb」。
      final cover = File('${dir.path}/abc.jpg')..writeAsBytesSync([1, 2, 3, 4]);

      expect(coverDisplayPath(cover.path), cover.path);

      await ensureCoverThumb(cover.path);

      final thumb = coverThumbPathFor(cover.path);
      expect(coverDisplayPath(cover.path), thumb);
      // 通道只传路径四参数（字节不过通道，plan.md R-2）。
      expect(calls, hasLength(1));
      expect(calls.single.method, 'makeCoverThumb');
      expect(calls.single.arguments, <String, Object?>{
        'srcPath': cover.path,
        'thumbPath': thumb,
        'maxEdge': kCoverThumbMaxEdge,
        'quality': kCoverThumbQuality,
      });
      // Dart 侧不落盘：产物由原生侧写（mock 不写文件），也不残留内联编码。
      expect(File(thumb).existsSync(), isFalse);
    });

    test('桥返回 false（不可解码/写盘失败）→ 静默保持原图路径', () async {
      mockThumb((call) async => false);
      final dir =
          await Directory.systemTemp.createTemp('selfmusic_thumb_nat_no_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cover = File('${dir.path}/fail.jpg')
        ..writeAsBytesSync([1, 2, 3, 4]);

      await ensureCoverThumb(cover.path);

      expect(coverDisplayPath(cover.path), cover.path);
      expect(File(coverThumbPathFor(cover.path)).existsSync(), isFalse);
      expect(calls, hasLength(1));
    });

    test('通道抛异常 → 静默不抛，保持原图路径', () async {
      mockThumb((call) async {
        throw PlatformException(code: '500', message: '图像解码服务异常');
      });
      final dir =
          await Directory.systemTemp.createTemp('selfmusic_thumb_nat_err_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cover = File('${dir.path}/boom.jpg')
        ..writeAsBytesSync([1, 2, 3, 4]);

      // 不抛出即通过：缩略图是纯优化，任何失败静默回原图（R-5）。
      await ensureCoverThumb(cover.path);

      expect(coverDisplayPath(cover.path), cover.path);
      expect(calls, hasLength(1));
    });

    test('并发两次 ensureCoverThumb → in-flight 去重仅走一次桥', () async {
      final release = Completer<Object?>();
      mockThumb((call) => release.future);
      final dir =
          await Directory.systemTemp.createTemp('selfmusic_thumb_nat_dup_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cover = File('${dir.path}/dup.jpg')..writeAsBytesSync([1, 2, 3, 4]);

      final f1 = ensureCoverThumb(cover.path);
      final f2 = ensureCoverThumb(cover.path);
      // 第二次调用同步段命中 _thumbInflight 去重：桥只被 invoke 一次。
      expect(calls, hasLength(1));

      release.complete(true);
      await Future.wait([f1, f2]);

      expect(coverDisplayPath(cover.path), coverThumbPathFor(cover.path));
      expect(calls, hasLength(1));
    });

    test('原生生成 → deleteCoverThumb：展示回原图，磁盘与缓存一并失效；再 ensure 重新走桥', () async {
      // 模拟原生侧真实行为：应答 true 的同时把缩略图写盘。
      mockThumb((call) async {
        final args = call.arguments as Map<dynamic, dynamic>;
        File(args['thumbPath'] as String).writeAsBytesSync([9, 9, 9]);
        return true;
      });
      final dir =
          await Directory.systemTemp.createTemp('selfmusic_thumb_nat_del_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cover = File('${dir.path}/del.jpg')..writeAsBytesSync([1, 2, 3, 4]);

      await ensureCoverThumb(cover.path);
      final thumb = coverThumbPathFor(cover.path);
      expect(coverDisplayPath(cover.path), thumb);
      expect(File(thumb).existsSync(), isTrue);

      deleteCoverThumb(cover.path);
      // 删除后：展示回原图（内存缓存失效），缩略图文件一并清除。
      expect(coverDisplayPath(cover.path), cover.path);
      expect(File(thumb).existsSync(), isFalse);

      // 再次 ensure：ready 集合与磁盘都没有 → 重新走桥生成。
      await ensureCoverThumb(cover.path);
      expect(calls, hasLength(2));
      expect(coverDisplayPath(cover.path), thumb);
    });

    test('仅内存就绪（原生未落盘）时 deleteCoverThumb：缓存同样失效回原图', () async {
      // mock 只回 true 不写文件：_thumbReady 有记录但磁盘无产物。
      mockThumb((call) async => true);
      final dir =
          await Directory.systemTemp.createTemp('selfmusic_thumb_nat_mem_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final cover = File('${dir.path}/mem.jpg')..writeAsBytesSync([1, 2, 3, 4]);

      await ensureCoverThumb(cover.path);
      expect(coverDisplayPath(cover.path), coverThumbPathFor(cover.path));

      deleteCoverThumb(cover.path);
      // 内存缓存失效后 coverDisplayPath 不再命中旧记录：回原图。
      expect(coverDisplayPath(cover.path), cover.path);

      // 再 ensure：磁盘无文件 → 重新走桥。
      await ensureCoverThumb(cover.path);
      expect(calls, hasLength(2));
      expect(coverDisplayPath(cover.path), coverThumbPathFor(cover.path));
    });
  });
}
