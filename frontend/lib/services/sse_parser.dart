import 'dart:async';
import 'dart:convert';

/// 一条 SSE 事件（本项目只用到 event / data）。
class SseEvent {
  final String event;
  final String data;

  const SseEvent({required this.event, required this.data});
}

/// 解析 `text/event-stream` 字节流。
///
/// 只实现本项目需要的子集：`event:` / `data:` / 注释心跳 / 空行派发；
/// `id:` / `retry:` 忽略。多行 `data` 按 SSE 规范用 `\n` 拼接。
///
/// 用显式 [StreamController] 而不是 `async*`：取消订阅时必须把 cancel 传播
/// 到上游 HTTP 流，`async*` 的 `await for` 在长连接上取消会挂起（真机表现为
/// 退后台后连接迟迟不释放）。
Stream<SseEvent> parseSse(Stream<List<int>> bytes) {
  late StreamController<SseEvent> controller;
  StreamSubscription<String>? sub;
  var event = 'message';
  final data = <String>[];

  void dispatch() {
    if (data.isEmpty) return;
    controller.add(SseEvent(event: event, data: data.join('\n')));
    event = 'message';
    data.clear();
  }

  void onLine(String line) {
    if (controller.isClosed) return;
    if (line.isEmpty) {
      dispatch();
      return;
    }
    // 注释帧（含服务端 15s 心跳 `: ping`）：派发成 comment 事件，消费者
    // 用它重置空闲判定；不参与业务事件处理。
    if (line.startsWith(':')) {
      controller.add(SseEvent(event: 'comment', data: line.substring(1).trimLeft()));
      return;
    }

    final idx = line.indexOf(':');
    final field = idx == -1 ? line : line.substring(0, idx);
    var value = idx == -1 ? '' : line.substring(idx + 1);
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'event':
        event = value;
      case 'data':
        data.add(value);
      default:
        break;
    }
  }

  controller = StreamController<SseEvent>(
    onListen: () {
      sub = bytes
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        onLine,
        onError: (Object e, StackTrace st) {
          if (!controller.isClosed) {
            controller.addError(e, st);
            controller.close();
          }
        },
        onDone: () {
          if (controller.isClosed) return;
          // 流结束前没有空行：把残留 data 派发一次，避免丢最后一个事件。
          dispatch();
          controller.close();
        },
        cancelOnError: true,
      );
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () async {
      await sub?.cancel();
      sub = null;
    },
  );
  return controller.stream;
}
