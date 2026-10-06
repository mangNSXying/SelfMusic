import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 鸿蒙系统能力桥（Dart 侧，`selfmusic/platform` 通道封装）。
///
/// 与 ArkTS 侧 [PlatformBridge]（PlatformBridge.ets）配对，承载三项
/// 系统能力的通道调用（2026-10-06 ohos-permissions feature，契约以
/// plan.md「Contracts & Interfaces」为准）：
/// - 常亮：[keepScreenOn] → window.setWindowKeepScreenOn；
/// - 本地文件：[pickDirectory]（选择器 + 持久化授权）→ [activateDirectory]
///   （重启后激活）→ [listDirectory]（递归枚举）→ [readRange]（范围读）；
/// - 蓝牙：[requestBluetoothPermission] / [hasBluetoothPermission] /
///   [listBondedDevices] / [connectedDevices]。
///
/// 仅被 `isOhos` 分支调用（Android/桌面走各自实现，零回归）。
///
/// 异常处理约定：
/// - [pickDirectory]：用户取消/任何异常返回 null（调用方保持表单不动）；
/// - [activateDirectory] / [listDirectory]：异常向上抛，由调用方转译为
///   用户可见错误（「目录授权已失效，请编辑该源重新选择目录」）；
/// - [readRange]：异常向上抛，播放侧按打开失败处理；
/// - 蓝牙查询：异常返回空集合/false 并 debugPrint 诊断日志（对齐 Android
///   「按未连接判定」的静默降级语义）。
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
