import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../platform/harmonyos/ohos_bootstrap.dart';
import '../platform/harmonyos/ohos_platform_bridge.dart';

/// 蓝牙音频设备（已配对列表/连接判定用）。
class BtDevice {
  final String name;
  final String address;
  const BtDevice({required this.name, required this.address});

  @override
  bool operator ==(Object other) => other is BtDevice && other.address == address;

  @override
  int get hashCode => address.hashCode;
}

/// 设置持久化：设备 JSON **数组**（`[{"name":…,"address":…}]`）；空=不限定。
/// 兼容早期版本的单对象格式（`{"name":…,"address":…}`，当时只能选一个）。
List<BtDevice> btDevicesFromSetting(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return const [];
  try {
    final decoded = jsonDecode(t);
    if (decoded is Map) {
      final d = _deviceOf(decoded);
      return d == null ? const [] : [d];
    }
    if (decoded is List) {
      final out = <BtDevice>[];
      for (final e in decoded) {
        if (e is! Map) continue;
        final d = _deviceOf(e);
        if (d != null) out.add(d);
      }
      return out;
    }
  } catch (_) {
    // 坏值按「不限定」处理。
  }
  return const [];
}

BtDevice? _deviceOf(Map<dynamic, dynamic> m) {
  final address = m['address'] as String?;
  if (address == null || address.isEmpty) return null;
  return BtDevice(name: (m['name'] as String?) ?? address, address: address);
}

String btDevicesToSetting(List<BtDevice> devices) => jsonEncode([
      for (final d in devices) {'name': d.name, 'address': d.address},
    ]);

/// 常亮门控纯函数：未限定设备（空表）→ 恒可常亮；
/// 否则所选设备**任一**处于连接状态即可（多选语义）。
bool btWakeGateOpen(List<BtDevice> devices, Set<String> connected) =>
    devices.isEmpty || devices.any((d) => connected.contains(d.address));

/// 蓝牙音频设备查询：已配对设备列表 + 当前连接的音频设备地址。
///
/// 平台分叉：
/// - Android：专有通道 `com.shamiko.selfmusic/bluetooth`，Android 12+
///   读取前需 BLUETOOTH_CONNECT 运行时权限（[ensurePermission]）；
/// - ohos：`selfmusic/platform` 平台桥（ACCESS_BLUETOOTH 三段式申请，
///   FR-009 仅「常亮限定设备」设置页触发，启动期零权限）；
/// - 桌面/其它：全部返回空（设置项不生效）。
///
/// 全平台异常一律静默降级（空集合/false），门控按「未连接」处理。
class BluetoothService {
  static const MethodChannel _ch =
      MethodChannel('com.shamiko.selfmusic/bluetooth');

  /// 申请蓝牙权限，返回是否可用。
  ///
  /// Android 12+ BLUETOOTH_CONNECT（低版本自动授予）；ohos 为
  /// ACCESS_BLUETOOTH 三段式（已授权短路 → 授权弹窗 → 设置弹框兜底）。
  Future<bool> ensurePermission() async {
    if (isOhos) return OhosPlatformBridge.requestBluetoothPermission();
    if (!Platform.isAndroid) return false;
    final status = await Permission.bluetoothConnect.request();
    return status.isGranted;
  }

  /// 当前是否已持有蓝牙权限（Android：BLUETOOTH_CONNECT；ohos：
  /// ACCESS_BLUETOOTH）。
  ///
  /// 权限缺失时 [connectedAddresses] 会静默返回空集 → 「限定设备常亮」永远判定
  /// 为未连接。调用方据此提示用户，而不是让门控无解释地失效。
  Future<bool> hasConnectPermission() async {
    if (isOhos) return OhosPlatformBridge.hasBluetoothPermission();
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('hasConnectPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 已配对设备列表；无权限/蓝牙关闭/不支持的平台时为空表。
  Future<List<BtDevice>> bondedDevices() async {
    if (isOhos) {
      final raw = await OhosPlatformBridge.listBondedDevices();
      return [
        // (name, address)：系统返回的 name 可能为空（设备未广播名称），
        // 回退展示 address，与 Android 路径的非空保证一致。
        for (final (name, address) in raw)
          BtDevice(name: name.isEmpty ? address : name, address: address)
      ];
    }
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('listBondedDevices');
      final out = <BtDevice>[];
      for (final e in raw ?? const []) {
        if (e is! Map) continue;
        final name = e['name'] as String?;
        final address = e['address'] as String?;
        if (name == null || address == null) continue;
        out.add(BtDevice(name: name, address: address));
      }
      return out;
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// 当前已连接的音频设备地址集合（A2DP/耳机/助听器）。
  Future<Set<String>> connectedAddresses() async {
    if (isOhos) return OhosPlatformBridge.connectedDevices();
    if (!Platform.isAndroid) return const {};
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('connectedDevices');
      return {for (final e in raw ?? const []) '$e'};
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }
}
