import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/services/sse_parser.dart';

Stream<List<int>> _bytes(List<String> chunks) async* {
  for (final c in chunks) {
    yield utf8.encode(c);
  }
}

void main() {
  test('解析 ready 事件与多行 data', () async {
    final events = await parseSse(_bytes([
      'event: ready\n',
      'data: {"push_protocol":1,\n',
      'data: "cursor":7}\n',
      '\n',
    ])).toList();

    expect(events, hasLength(1));
    expect(events.single.event, 'ready');
    expect(events.single.data, '{"push_protocol":1,\n"cursor":7}');
  });

  test('跨 chunk 的字段与 CRLF 也能正确拼接', () async {
    final events = await parseSse(_bytes([
      'event: break',
      'point\r\n',
      'data: {"playlist_uuid":"p-1"}\r\n',
      '\r\n',
    ])).toList();

    expect(events, hasLength(1));
    expect(events.single.event, 'breakpoint');
    expect(events.single.data, '{"playlist_uuid":"p-1"}');
  });

  test('注释心跳派发为 comment 事件（用于重置空闲判定）', () async {
    final events = await parseSse(_bytes([
      ': ping\n\n',
      'event: heartbeat\n',
      'data: {}\n',
      '\n',
    ])).toList();

    expect(events, hasLength(2));
    expect(events[0].event, 'comment');
    expect(events[0].data, 'ping');
    expect(events[1].event, 'heartbeat');
  });

  test('默认事件名为 message，流结束时派发残留 data', () async {
    final events = await parseSse(_bytes([
      'data: tail-without-blank-line',
    ])).toList();

    expect(events, hasLength(1));
    expect(events.single.event, 'message');
    expect(events.single.data, 'tail-without-blank-line');
  });

  test('空行之间没有 data 不派发空事件', () async {
    final events = await parseSse(_bytes([
      '\n\n',
      'event: ready\n',
      'data: {}\n',
      '\n',
    ])).toList();

    expect(events, hasLength(1));
    expect(events.single.event, 'ready');
  });

  test('取消订阅会向上游传播（关闭 HTTP 连接的前提）', () async {
    final controller = StreamController<List<int>>();
    var cancelled = false;
    controller.onCancel = () {
      cancelled = true;
    };
    final sub = parseSse(controller.stream).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(cancelled, isTrue);
  });
}
