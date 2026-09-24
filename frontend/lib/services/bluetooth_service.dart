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

/// 设置持久化：设备 JSON（{name,address}）；'' 表示不限定。
BtDevice? btDeviceFromSetting(String raw) {
  if (raw.trim().isEmpty) return null;
  try {
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final address = m['address'] as String?;
    if (address == null || address.isEmpty) return null;
    return BtDevice(name: (m['name'] as String?) ?? address, address: address);
  } catch (_) {
    return null;
  }
}

String btDeviceToSetting(BtDevice d) =>
    jsonEncode({'name': d.name, 'address': d.address});

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
