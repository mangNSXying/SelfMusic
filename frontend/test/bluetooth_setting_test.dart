import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/bluetooth_service.dart';

/// 常亮限定蓝牙设备：多选存储 + 门控（改进.txt 注释：指定设备不生效，要改复选框多选）。
void main() {
  const a = BtDevice(name: 'WH-1000XM', address: 'AA:BB:CC:DD:EE:FF');
  const b = BtDevice(name: 'AirPods Pro', address: '11:22:33:44:55:66');
  const c = BtDevice(name: '音箱', address: '77:88:99:AA:BB:CC');

  group('设置持久化：多选数组', () {
    test('空/空白/坏值 → 不限定（空表）', () {
      expect(btDevicesFromSetting(''), isEmpty);
      expect(btDevicesFromSetting('  '), isEmpty);
      expect(btDevicesFromSetting('not-json'), isEmpty);
      expect(btDevicesFromSetting('{}'), isEmpty);
      expect(btDevicesFromSetting('{"address":""}'), isEmpty);
      expect(btDevicesFromSetting('[{"address":""}]'), isEmpty);
    });

    test('多选数组往返', () {
      final raw = btDevicesToSetting([a, b]);
      final back = btDevicesFromSetting(raw);
      expect(back.length, 2);
      expect(back[0], a);
      expect(back[1], b);
    });

    test('兼容早期单对象格式（旧版本只能选一个）', () {
      final back = btDevicesFromSetting('{"name":"WH-1000XM",'
          '"address":"AA:BB:CC:DD:EE:FF"}');
      expect(back.length, 1);
      expect(back.single, a);
      // 地址缺省时用地址当名字
      expect(btDevicesFromSetting('{"address":"AA:BB"}').single.name, 'AA:BB');
    });

    test('空选择写回空串（=不限定）', () {
      expect(btDevicesToSetting(const []), '[]');
      expect(btDevicesFromSetting('[]'), isEmpty);
    });
  });

  group('常亮门控：任一选中设备连接即可', () {
    test('不限定（空表）→ 恒可常亮', () {
      expect(btWakeGateOpen(const [], const {}), isTrue);
    });

    test('单设备：连上才常亮', () {
      expect(btWakeGateOpen([a], const {}), isFalse);
      expect(btWakeGateOpen([a], {a.address}), isTrue);
      expect(btWakeGateOpen([a], {c.address}), isFalse);
    });

    test('多设备：任一连上即常亮', () {
      final devices = [a, b];
      expect(btWakeGateOpen(devices, const {}), isFalse);
      expect(btWakeGateOpen(devices, {b.address}), isTrue);
      expect(btWakeGateOpen(devices, {a.address, c.address}), isTrue);
      // 别的设备连着不算
      expect(btWakeGateOpen(devices, {c.address}), isFalse);
    });
  });
}
