import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/sources/smb_init_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SmbInitBroker 串行化并发建连', () async {
    await SmbInitBroker.ensureStarted();
    expect(SmbInitBroker.port, isNotNull);

    var active = 0;
    var peak = 0;
    final order = <String>[];
    Future<void> job(int i) => SmbInitBroker.run(() async {
          active++;
          if (active > peak) peak = active;
          order.add('start$i');
          await Future<void>.delayed(const Duration(milliseconds: 30));
          order.add('end$i');
          active--;
        });

    await Future.wait([job(1), job(2), job(3)]);
    expect(peak, 1, reason: 'libsmb2 初始化必须全局串行');
    expect(order.length, 6);
  });
}
