import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 鸿蒙系统能力桥（Dart 侧，`selfmusic/platform` 通道封装）。
///
/// 与 ArkTS 侧 [PlatformBridge]（PlatformBridge.ets）配对，承载四项
/// 系统能力的通道调用（2026-10-06 ohos-permissions feature；
/// 2026-10-06 ohos-thumb-native-decode feature 扩封面缩略图管线，契约以
/// plan.md「Contracts & Interfaces」为准）：
/// - 常亮：[keepScreenOn] → window.setWindowKeepScreenOn；
/// - 本地文件：[pickDirectory]（选择器 + 持久化授权）→ [listDirectory]
///   （递归枚举；失败时 [activateDirectory] 激活后重试，重启后首次扫描
///   走重试分支）→ [readRange]（范围读）；
/// - 蓝牙：[requestBluetoothPermission] / [hasBluetoothPermission] /
///   [listBondedDevices] / [connectedDevices]；
/// - 封面缩略图：[makeCoverThumb]（@ohos.multimedia.image 原生管线——fork
///   引擎无子 isolate、`runOffThread` 在 ohos 内联，纯 Dart 编码会阻塞 UI
///   isolate，解码/缩放/编码/写盘全部下沉 ArkTS 侧）。
///
/// 仅被 `isOhos` 分支调用（Android/桌面走各自实现，零回归）。
///
/// 异常处理约定：
/// - [pickDirectory]：用户取消/任何异常返回 null（调用方保持表单不动）；
/// - [activateDirectory] / [listDirectory]：异常向上抛，由调用方转译为
///   用户可见错误（「目录授权已失效，请编辑该源重新选择目录」）；
/// - [readRange]：异常向上抛，播放侧按打开失败处理；
/// - 蓝牙查询：异常返回空集合/false 并 debugPrint 诊断日志（对齐 Android
///   「按未连接判定」的静默降级语义）；
/// - [makeCoverThumb]：任何异常/超时/失败返回 false 并 debugPrint（缩略图
///   是纯优化，调用方静默回原图显示；绝不回退内联 Dart 编码）。
class OhosPlatformBridge {
  static const MethodChannel _channel = MethodChannel('selfmusic/platform');

  OhosPlatformBridge._();

  /// 目录选择结果：[uri] 为授权目录 URI（`file://docs/...` 形态，直接
  /// 存入源配置 path 字段）；[persisted] 为持久化是否成功（false 时本次
  /// 会话临时授权仍可用，重启后需重选）。
  static Future<OhosPickedDirectory?> pickDirectory() async {
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'pickDirectory');
      if (raw == null) return null; // 用户取消。
      final uri = raw['uri'] as String?;
      if (uri == null || uri.isEmpty) return null;
      return OhosPickedDirectory(
          uri: uri, persisted: raw['persisted'] == true);
    } on PlatformException catch (e) {
      debugPrint('[ohos] pickDirectory 失败: $e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] pickDirectory 桥未装配: $e');
      return null;
    }
  }

  /// 重启后激活已持久化的目录授权；失败（授权被撤销/目录删除）抛
  /// [PlatformException]，由调用方转译为引导文案。
  static Future<void> activateDirectory(String uri) async {
    await _channel.invokeMethod<void>(
        'activateDirectory', <String, Object?>{'uri': uri});
  }

  /// 递归枚举授权目录（快照：rel/size/mtime），供扫描 diff 使用。
  static Future<List<OhosDirEntry>> listDirectory(String uri) async {
    final raw = await _channel.invokeMethod<List<dynamic>>('listDirectory',
        <String, Object?>{'uri': uri});
    final out = <OhosDirEntry>[];
    for (final e in raw ?? const <dynamic>[]) {
      if (e is! Map) continue;
      final rel = e['rel'] as String?;
      final size = e['size'] as int?;
      final mtime = e['mtime'] as int?;
      if (rel == null || size == null || mtime == null) continue;
      out.add(OhosDirEntry(rel: rel, size: size, mtime: mtime));
    }
    return out;
  }

  /// 范围读授权目录内文件（单次上限 2 MiB，由 ArkTS 侧防御）。
  ///
  /// [rel] 为库内 song ref（无头相对路径）；ArkTS 侧按 `uri + rel` 拼接且
  /// fs.listFile 返回的相对路径以 `/` 开头，这里补回头部斜杠（幂等）。
  static Future<Uint8List> readRange(
      String uri, String rel, int offset, int length) async {
    final fullRel = rel.startsWith('/') ? rel : '/$rel';
    final data = await _channel.invokeMethod<Uint8List>('readRange',
        <String, Object?>{
          'uri': uri,
          'rel': fullRel,
          'offset': offset,
          'length': length
        });
    return data ?? Uint8List(0);
  }

  /// 解析授权目录内文件的沙箱真路径（openSync(uri).path），供本地源
  /// [MusicSource.cachedFilePath] 的 ohos 分支使用：播放走 setFilePath
  /// 直连（mdk 原生 file://），绕开 just_audio 本地代理。
  ///
  /// 2026-10-07 播放管线修复：此前 ohos 一律回 null 走字节流分支
  /// （DirectAudioSource → just_audio 本地代理），真机取证发现代理对
  /// 死锁后 socket 事件通知以 ~305µs 周期空转（~2.9k HandleMessage/s，
  /// ~1.5 核 CPU），启动断点恢复即触发。失败/桥未装配返回 null，调用方
  /// 回退字节流分支（行为同修复前）。
  static Future<String?> resolvePath(String uri, String rel) async {
    final fullRel = rel.startsWith('/') ? rel : '/$rel';
    try {
      return await _channel.invokeMethod<String>('resolvePath',
          <String, Object?>{'uri': uri, 'rel': fullRel});
    } on PlatformException catch (e) {
      debugPrint('[ohos] resolvePath 失败（回退字节流分支）: $e');
      return null;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] resolvePath 桥未装配: $e');
      return null;
    }
  }

  /// 窗口常亮开关（无需权限，仅前台生效）。失败仅记日志不中断——常亮
  /// 属体验增强，不应影响播放。
  static Future<void> keepScreenOn(bool enable) async {
    try {
      await _channel.invokeMethod<void>(
          'keepScreenOn', <String, Object?>{'enable': enable});
    } on PlatformException catch (e) {
      debugPrint('[ohos] keepScreenOn($enable) 失败: $e');
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] keepScreenOn 桥未装配: $e');
    }
  }

  /// 蓝牙权限三段式申请（checkAccessToken 短路 → 首弹窗 → 设置弹框），
  /// 结果只表达「当前是否可用」；任何阶段异常均返回 false。
  static Future<bool> requestBluetoothPermission() async {
    try {
      final raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('requestBluetoothPermission');
      return raw != null && raw['granted'] == true;
    } on PlatformException catch (e) {
      debugPrint('[ohos] requestBluetoothPermission 失败: $e');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] requestBluetoothPermission 桥未装配: $e');
      return false;
    }
  }

  /// 当前是否持有 ACCESS_BLUETOOTH；异常按 false（门控据此判定未连接）。
  static Future<bool> hasBluetoothPermission() async {
    try {
      return await _channel.invokeMethod<bool>('hasBluetoothPermission') ??
          false;
    } on PlatformException catch (e) {
      debugPrint('[ohos] hasBluetoothPermission 失败: $e');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] hasBluetoothPermission 桥未装配: $e');
      return false;
    }
  }

  /// 已配对蓝牙设备（name 空回退 address）；权限缺失/蓝牙关闭/能力不
  /// 支持一律降级空数组（对齐 Android 静默降级 + 诊断日志）。
  static Future<List<(String, String)>> listBondedDevices() async {
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('listBondedDevices');
      final out = <(String, String)>[];
      for (final e in raw ?? const <dynamic>[]) {
        if (e is! Map) continue;
        final name = e['name'] as String?;
        final address = e['address'] as String?;
        if (name == null || address == null) continue;
        out.add((name, address));
      }
      return out;
    } on PlatformException catch (e) {
      debugPrint('[ohos] listBondedDevices 失败（按空处理）: $e');
      return const [];
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] listBondedDevices 桥未装配: $e');
      return const [];
    }
  }

  /// 当前已连接蓝牙音频设备地址集合；异常降级空集合（门控按未连接判定）。
  static Future<Set<String>> connectedDevices() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('connectedDevices');
      return {for (final e in raw ?? const <dynamic>[]) '$e'};
    } on PlatformException catch (e) {
      debugPrint('[ohos] connectedDevices 失败（按空处理）: $e');
      return const {};
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] connectedDevices 桥未装配: $e');
      return const {};
    }
  }

  /// 封面缩略图原生生成（第 10 个通道方法，ohos-thumb-native-decode
  /// feature）：解码 → EXIF 方向烘焙 → 最长边 [maxEdge] 降采样 → JPEG
  /// [quality] 重编码 → `<thumbPath>.tmp` 写盘后 rename——全链在 ArkTS 侧
  /// @ohos.multimedia.image 系统原生线程完成，缩略图字节不过通道。
  ///
  /// [srcPath] 为封面原图沙箱路径，[thumbPath] 为目标缩略图路径（沿用
  /// `cover_thumb.dart` 的 `<md5>.thumb.jpg` 约定）；[maxEdge]/[quality]
  /// 缺省 768/82（与 kCoverThumbMaxEdge / kCoverThumbQuality 对齐）。
  ///
  /// 失败兜底（plan.md R-5）：[PlatformException] / [MissingPluginException] /
  /// [TimeoutException] 与 false 返回一律 debugPrint 诊断日志后返回 false，
  /// **绝不抛出、绝不回退内联 Dart 编码**（fork 引擎上等于把数百 ms UI 块
  /// 请回来）——调用方按「缩略图是纯优化」静默回原图显示。15s 超时上限覆盖
  /// 原生解码大图的合法秒级耗时，超时后本轮放弃、下次触发重试；[timeout]
  /// 仅供测试注入。
  static Future<bool> makeCoverThumb(String srcPath, String thumbPath,
      {int maxEdge = 768,
      int quality = 82,
      Duration timeout = const Duration(seconds: 15)}) async {
    try {
      final ok = await _channel.invokeMethod<bool>('makeCoverThumb',
          <String, Object?>{
            'srcPath': srcPath,
            'thumbPath': thumbPath,
            'maxEdge': maxEdge,
            'quality': quality
          }).timeout(timeout);
      return ok ?? false;
    } on TimeoutException catch (e) {
      debugPrint('[ohos] makeCoverThumb 超时（放弃本轮，下次触发重试）: $e');
      return false;
    } on PlatformException catch (e) {
      debugPrint('[ohos] makeCoverThumb 失败: $e');
      return false;
    } on MissingPluginException catch (e) {
      debugPrint('[ohos] makeCoverThumb 桥未装配: $e');
      return false;
    }
  }
}

/// pickDirectory 结果：授权目录 URI + 是否已持久化。
class OhosPickedDirectory {
  final String uri;
  final bool persisted;
  const OhosPickedDirectory({required this.uri, required this.persisted});
}

/// listDirectory 单项：目录内相对路径（`/` 开头）+ 文件大小 + mtime（秒）。
class OhosDirEntry {
  final String rel;
  final int size;
  final int mtime;
  const OhosDirEntry({required this.rel, required this.size, required this.mtime});
}
