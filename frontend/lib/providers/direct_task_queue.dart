import 'dart:async';

import 'package:flutter/foundation.dart';

/// 直连补读任务的优先级：声明顺序即执行顺序（越靠前越先跑）。
///
/// 这是用户定的顺序：当前曲音频（阻塞装载，不进队列）→ 当前曲元数据/封面 →
/// 下一首音频（开启预载时）→ 下一首元数据/封面 → 全库后台补读。
enum DirectTaskPriority {
  /// 当前播放歌曲的元数据与同目录封面：界面上正显示着的那一行，最先补。
  currentMeta,

  /// 下一首的完整音频下载（预载）。
  nextAudio,

  /// 下一首的元数据与封面。
  nextMeta,

  /// 全库后台补读。
  background,
}

typedef DirectTaskBody = Future<void> Function();

class _DirectTask {
  _DirectTask(this.priority, this.key, this.body);

  final DirectTaskPriority priority;
  final String key;
  final DirectTaskBody body;
}

/// 直连网络补读的串行优先级队列：一次只跑一个，跑之前重挑最高优先级。
///
/// 为什么必须串行：播放链路的每一跳都是各自独立的 HttpClient 请求
/// （[MusicSource.open] / [MusicSource.cacheSong] / [MusicSource.probe] 都自己建
/// 客户端），并发跑就是同时开 N 条连接抢同一条链路——弱网或后台限流下反而一起变慢，
/// 而且「谁的封面先出现」变成不确定的。串行 + 优先级让顺序可预期，也让后台补读
/// 不会把切歌要用的连接预算吃光。
///
/// 为什么每次重挑而不是先来先到：全库后台补读一次能提交上百个任务，它们先到但不
/// 该先跑；中途切歌插进来的当前曲任务必须立刻压过排在后面的下一首与全库任务。
///
/// 已提交但还没开始的下一首任务在换歌时由 [dropPending] 作废（正在跑的跑完即止：
/// 中途掐掉整首下载既拿不到东西，也会留下半个文件）。
class DirectTaskQueue {
  final List<_DirectTask> _pending = [];
  _DirectTask? _running;
  bool _pumping = false;
  Completer<void>? _idleCompleter;

  @visibleForTesting
  int get pendingCount => _pending.length;

  @visibleForTesting
  bool get isRunning => _running != null;

  @visibleForTesting
  List<String> get debugPendingKeys =>
      [for (final t in _pending) '${t.priority.name}/${t.key}'];

  /// 排队一个任务。同 [key] 已在队列里或正在跑时忽略（幂等：重复提交无副作用）。
  void submit(DirectTaskPriority priority,
      {required String key, required DirectTaskBody body}) {
    if (_running?.key == key) return;
    for (final t in _pending) {
      if (t.key == key) return;
    }
    _pending.add(_DirectTask(priority, key, body));
    unawaited(_pump());
  }

  /// 作废尚未开始的任务（换歌时丢掉过期的「下一首音频/下一首元数据」）。
  void dropPending(bool Function(DirectTaskPriority priority, String key) pred) {
    _pending.removeWhere((t) => pred(t.priority, t.key));
  }

  /// 排空且没有任务在跑时完成。后台补读按批取歌，用它等这一批真正跑完再取下一批
  /// （保持原有游标语义，也避免一次灌进几百个任务把通知频率顶满）。
  Future<void> idle() {
    if (_pending.isEmpty && _running == null) return Future<void>.value();
    return (_idleCompleter ??= Completer<void>()).future;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      // 先让出一轮事件循环再挑任务：切歌那一刻四级任务是同一个同步块里陆续提交
      // 的（当前曲元数据 → 下一首预载 → 下一首元数据 → 全库）。不等这一轮就到
      // 这里开跑，先提交的全库任务会抢到当前曲前面——优先级就白排了。
      await Future<void>.delayed(Duration.zero);
      while (_pending.isNotEmpty) {
        // 同优先级按提交顺序（先进先出），跨优先级取数字最小的那个。
        var best = 0;
        for (var i = 1; i < _pending.length; i++) {
          if (_pending[i].priority.index < _pending[best].priority.index) {
            best = i;
          }
        }
        final task = _pending.removeAt(best);
        _running = task;
        try {
          await task.body();
        } catch (e) {
          // 单个补读失败不拖垮队列（歌曲元数据/封面失败本就该跳过继续）。
          debugPrint('[task] ${task.key} 失败: $e');
        } finally {
          _running = null;
        }
        // 任务之间必须让出事件循环：一串补读不能把播放器的按键响应卡住，
        // 也要给「中途切歌」插队的机会。
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      _pumping = false;
      if (_pending.isEmpty && _running == null) {
        _idleCompleter?.complete();
        _idleCompleter = null;
      }
    }
  }
}