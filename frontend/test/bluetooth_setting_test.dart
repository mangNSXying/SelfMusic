import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/bluetooth_service.dart';

void main() {
  test('常亮限定蓝牙设备：JSON 往返与坏值容错', () {
    expect(btDeviceFromSetting(''), isNull);
    expect(btDeviceFromSetting('  '), isNull);
    expect(btDeviceFromSetting('not-json'), isNull);
    expect(btDeviceFromSetting('{}'), isNull);
    expect(btDeviceFromSetting('{"address":""}'), isNull);

    const d = BtDevice(name: 'WH-1000XM', address: 'AA:BB:CC:DD:EE:FF');
    final raw = btDeviceToSetting(d);
    final back = btDeviceFromSetting(raw)!;
    expect(back.name, 'WH-1000XM');
    expect(back.address, 'AA:BB:CC:DD:EE:FF');
    expect(back, d);
  });
}
