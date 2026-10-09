import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/db_writer.dart';

void main() {
  test('chunkedSublists：空表 / 不足一片 / 恰好整除 / 余数 / 非法片长', () {
    expect(chunkedSublists<int>([], 3), isEmpty);
    expect(chunkedSublists([1, 2, 3], 5), [
      [1, 2, 3]
    ]);
    expect(chunkedSublists([1, 2, 3, 4], 2), [
      [1, 2],
      [3, 4]
    ]);
    expect(chunkedSublists([1, 2, 3, 4, 5], 2), [
      [1, 2],
      [3, 4],
      [5]
    ]);
    // 片长 < 1 归一为 1（防御性：调用方不应传 0/负数）
    expect(chunkedSublists([1], 0), [
      [1]
    ]);
  });
}
