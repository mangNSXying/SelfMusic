/// 性能基线记录工具（华为 Flutter 鸿蒙 DFX 官方口径）。
///
/// 目的：为「滑动过渡档」的过渡/滚动动画建立**可量化、可回归**的测量口径——
/// 丢帧率、最坏单帧耗时与官方丢帧事件（`OTHER_JANK` / `OTHER_JANK_STAT` /
/// `OTHER_JANK_SCROLL`），供优化前/后对比与回归。
///
/// 口径（见 spec.md 背景）：
/// - 帧目标：60Hz 每帧 16.6ms、120Hz 每帧 8.3ms；超时即丢帧（JANK）。
/// - 验收：丢帧率 < 5%，最坏单帧 < 50ms（低于官方「严重卡顿」阈值）。
///
/// 本类为**纯 Dart 记录结构**：不主动采样引擎，由真机侧工具链（HiAppEvent /
/// HiTrace / DevTools）或测试把观测值喂入本结构，保证记录格式统一、可对比。
library;

/// 一次场景测量的性能基线记录。
class FrameBaseline {
  const FrameBaseline({
    required this.scenario,
    this.missedFrames = 0,
    this.totalFrames = 0,
    this.maxFrameTime = Duration.zero,
    this.eventCounts = const <String, int>{},
    this.notes = '',
  });

  /// 测量场景标记（如「滑动档 / 分组横滑 + 列表滚动」）。
  final String scenario;

  /// 超过目标帧时间（丢帧）的帧数。
  final int missedFrames;

  /// 测量窗口内的总帧数。
  final int totalFrames;

  /// 最坏单帧耗时。
  final Duration maxFrameTime;

  /// 官方丢帧事件计数（键为事件名，如 `OTHER_JANK`）。
  final Map<String, int> eventCounts;

  /// 备注（机型、刷新率、复现步骤等自由文本）。
  final String notes;

  /// 丢帧率（0..1；无样本时为 0）。
  double get missedRate => totalFrames <= 0 ? 0 : missedFrames / totalFrames;

  /// 是否满足验收阈值（默认丢帧率 < 5%、最坏单帧 < 50ms）。
  bool meetsTarget({
    double missedRateTarget = 0.05,
    Duration worstFrameTarget = const Duration(milliseconds: 50),
  }) =>
      missedRate < missedRateTarget && maxFrameTime < worstFrameTarget;

  /// 累计一帧观测：按 [targetFrameTime] 判定是否丢帧并更新最坏帧。
  ///
  /// 幂等、无副作用（返回新实例），便于测量工具逐帧累加。
  FrameBaseline recordFrame({
    required Duration frameTime,
    Duration targetFrameTime = const Duration(milliseconds: 16, microseconds: 600),
  }) {
    final missed = frameTime > targetFrameTime;
    return FrameBaseline(
      scenario: scenario,
      missedFrames: missedFrames + (missed ? 1 : 0),
      totalFrames: totalFrames + 1,
      maxFrameTime: frameTime > maxFrameTime ? frameTime : maxFrameTime,
      eventCounts: eventCounts,
      notes: notes,
    );
  }

  /// 累加一次官方丢帧事件计数（如 [event] = `OTHER_JANK`）。
  FrameBaseline recordEvent(String event) {
    final next = Map<String, int>.of(eventCounts);
    next[event] = (next[event] ?? 0) + 1;
    return FrameBaseline(
      scenario: scenario,
      missedFrames: missedFrames,
      totalFrames: totalFrames,
      maxFrameTime: maxFrameTime,
      eventCounts: next,
      notes: notes,
    );
  }

  /// 序列化为可落盘/对比的 JSON（基线归档用）。
  Map<String, dynamic> toJson() => {
        'scenario': scenario,
        'missedFrames': missedFrames,
        'totalFrames': totalFrames,
        'maxFrameTimeMs': maxFrameTime.inMicroseconds / 1000,
        'missedRate': double.parse(missedRate.toStringAsFixed(4)),
        'meetsTarget': meetsTarget(),
        'eventCounts': eventCounts,
        if (notes.isNotEmpty) 'notes': notes,
      };

  /// baseline.md 表格行（场景 / 丢帧率 / 最坏单帧 / 事件 / 达标）。
  String toMarkdownRow() {
    final events = eventCounts.entries
        .map((e) => '${e.key}=${e.value}')
        .join(', ');
    final ms = (maxFrameTime.inMicroseconds / 1000).toStringAsFixed(1);
    final rate = (missedRate * 100).toStringAsFixed(2);
    return '| $scenario | $rate% ($missedFrames/$totalFrames) | ${ms}ms '
        '| ${events.isEmpty ? '—' : events} | ${meetsTarget() ? '是' : '否'} |';
  }
}
