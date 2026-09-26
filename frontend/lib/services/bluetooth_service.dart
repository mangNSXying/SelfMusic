import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

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

/// Android 蓝牙查询通道：已配对设备 + 当前连接的音频设备地址。
///
/// 非 Android 平台全部返回空（设置项在桌面不生效）；
/// Android 12+ 读取前需 BLUETOOTH_CONNECT 运行时权限（[ensurePermission]）。
class BluetoothService {
  static const MethodChannel _ch =
      MethodChannel('com.shamiko.selfmusic/bluetooth');

  /// 申请蓝牙连接权限（Android 12+；低版本自动授予）。返回是否可用。
  Future<bool> ensurePermission() async {
    if (!Platform.isAndroid) return false;
    final status = await Permission.bluetoothConnect.request();
    return status.isGranted;
  }

  /// 当前是否已持有 BLUETOOTH_CONNECT。
  ///
  /// 权限缺失时 [connectedAddresses] 会静默返回空集 → 「限定设备常亮」永远判定
  /// 为未连接。调用方据此提示用户，而不是让门控无解释地失效。
  Future<bool> hasConnectPermission() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('hasConnectPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 已配对设备列表；无权限/蓝牙关闭/非 Android 时为空表。
  Future<List<BtDevice>> bondedDevices() async {
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

  /// 当前已连接的音频设备（A2DP/耳机/助听器）地址集合。
  Future<Set<String>> connectedAddresses() async {
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
