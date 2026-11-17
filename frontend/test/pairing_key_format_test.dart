import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/utils/pairing_key_format.dart';

void main() {
  test('配对密钥遮罩：短串整串遮罩', () {
    expect(maskPairingKey(''), '••••••••');
    expect(maskPairingKey('abc'), '••••••••');
    expect(maskPairingKey('12345678'), '••••••••');
  });

  test('配对密钥遮罩：长串保留首尾 4 位', () {
    expect(maskPairingKey('123456789'), '1234••••••6789');
    expect(maskPairingKey('tok-abcdefgh-1234'), 'tok-••••••1234');
  });
}
