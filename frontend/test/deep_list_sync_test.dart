import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/deep_list_sync.dart';

List<DeepEntry> entries(List<String> refs) => [
      for (final ref in refs)
        <String, dynamic>{'source': 'webdav', 'source_ref': ref},
    ];

List<String> refsOf(List<DeepEntry> list) => [
      for (final e in list) e['source_ref'] as String,
    ];

void main() {
  test('base 前缀判定：只在尾部追加时返回后缀', () {
    final base = entries(['/a', '/b']);
    final full = entries(['/a', '/b', '/c']);
    expect(deepListStartsWith(base, full), isTrue);
    expect(refsOf(full.sublist(base.length)), ['/c']);
    expect(deepListStartsWith(entries(['/a', '/x']), full), isFalse);
    expect(
        deepListStartsWith(entries(['/a', '/b', '/c', '/d']), full), isFalse);
  });

  test('三向合并：服务端分支在前、设备分支为末尾', () {
    final merged = mergeDeepLists(
      base: entries(['/a', '/b']),
      server: entries(['/a', '/b', '/s']),
      device: entries(['/a', '/b', '/d']),
      capacity: 10,
    );
    expect(refsOf(merged), ['/a', '/b', '/s', '/d']);
  });

  test('非追加操作自动裁决：pop/clear 且服务端未变时设备分支胜出', () {
    expect(
      refsOf(mergeDeepLists(
        base: entries(['/a', '/b']),
        server: entries(['/a', '/b']),
        device: entries(['/a']),
        capacity: 10,
      )),
      ['/a'],
    );
    expect(
      mergeDeepLists(
        base: entries(['/a', '/b']),
        server: entries(['/a', '/b']),
        device: const [],
        capacity: 10,
      ),
      isEmpty,
    );
  });

  test('纯追加去重保留最后，容量溢出只裁最旧端', () {
    final merged = appendDeepAdded(
      entries(['/a', '/b', '/c']),
      entries(['/b', '/d']),
      4,
    );
    expect(refsOf(merged), ['/a', '/c', '/b', '/d']);
    expect(
      refsOf(appendDeepAdded(entries(['/a', '/b', '/c']), entries(['/d']), 3)),
      ['/b', '/c', '/d'],
    );
  });

  test('base 解析容错：坏行/缺 ref/坏 JSON 跳过', () {
    expect(parseDeepEntries('not json'), isEmpty);
    expect(
      refsOf(parseDeepEntries(
          '[{"source":"webdav","source_ref":"/a"},{"source_ref":""},{"x":1}]')),
      ['/a'],
    );
  });
}
