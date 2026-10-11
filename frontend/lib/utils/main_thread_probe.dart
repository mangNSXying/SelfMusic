// 临时诊断埋点（主线程停滞定位，用完即删）：在 app 主 isolate 上跑一个
// `Timer.periodic(100ms)` 心跳，测量两次 tick 之间的真实间隔；当间隔
// >= 250ms 时说明事件循环被同步代码阻塞，打印当时的阶段标签。
//
// 为什么不直接读 `currentPhase`：同步长块跑完后代码往往已经推进到下一个
// `perfPhase(...)`，探针回调在解阻后才执行，直接读会报「阻塞之后」的阶段。
// 故这里记录阶段切换时间线，报「停滞窗口开始时」所处的那一阶段（owner）。
//
// 纯 Dart，不依赖 foundation；与 perf_log 一样便于整体删除。

import 'dart:async';

import 'perf_log.dart';

/// 当前阶段标签（最近一次 [perfPhase] 的名字）。
String currentPhase = 'idle';

class _PhaseMark {
  final String name;
  final int atMs;
  const _PhaseMark(this.name, this.atMs);
}

int _phaseAtMs = DateTime.now().millisecondsSinceEpoch;
final List<_PhaseMark> _phaseMarks = <_PhaseMark>[
  _PhaseMark('idle', _phaseAtMs),
];

/// 标记「接下来这段同步代码属于哪个阶段」，供停滞探针归因。
void perfPhase(String name) {
  final now = DateTime.now().millisecondsSinceEpoch;
  currentPhase = name;
  _phaseAtMs = now;
  _phaseMarks.add(_PhaseMark(name, now));
  if (_phaseMarks.length > 256) _phaseMarks.removeAt(0);
}

Timer? _stallTimer;

/// 启动停滞探针（幂等）。应在 `main()` 最前面调用。
void startMainThreadStallProbe() {
  if (_stallTimer != null) return;
  var last = DateTime.now().millisecondsSinceEpoch;
  _stallTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final gap = now - last;
    last = now;
    if (gap < 250) return;
    // 停滞窗口起点：找到当时生效的阶段（最后一条 atMs <= stallStart）。
    final stallStart = now - gap;
    var owner = _phaseMarks.first.name;
    for (final m in _phaseMarks) {
      if (m.atMs <= stallStart) {
        owner = m.name;
      } else {
        break;
      }
    }
    perfLog('stall', 'gap=${gap}ms phase=$owner (now=$currentPhase)');
  });
}
