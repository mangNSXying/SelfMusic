import 'dart:convert';

import 'frame_baseline.dart';

/// 缩略图生成量化埋点（FR-007 / plan.md R-7）。
///
/// 记录每次生成的「单张往返耗时、成功/失败/超时、在飞峰值、批次」并可整体关闭；
/// 提供聚合快照与文本/JSON 导出，供优化前/后对比与长期诊断（判定「缩略图生成
/// 是否仍占用 UI 主线程」）。默认开启，不新增用户可见设置项、不改变功能行为。
///
/// 与 [FrameBaseline] 以同一 [scenario] 关联导出（[exportScenario]），保证口径统一。
///
/// 用法（生成链路，见 `cover_thumb.dart`）：
/// ```dart
/// ThumbGenStats.markStart();
/// try {
///   final r = await OhosPlatformBridge.makeCoverThumbDetailed(...);
///   ThumbGenStats.markEnd(ok: r.ok, cost: sw.elapsed, nativeCostMs: r.costMs,
///       degraded: r.degraded);
/// } finally { ... }
/// ```
class ThumbGenStats {
  ThumbGenStats._();

  /// 总开关（默认开启）。置 false 时所有记录与计数短路，零额外开销。
  static bool enabled = true;

  /// 场景标记（与 [FrameBaseline.scenario] 同口径，供关联导出）。
  static String scenario = 'thumb-gen';

  // ---------- 计数 ----------
  static int _attempted = 0;
  static int _ok = 0;
  static int _failed = 0;
  static int _timeout = 0;

  // ---------- 往返耗时（ms）----------
  static int _costCount = 0;
  static int _totalCostMs = 0;
  static int _minCostMs = 0;
  static int _maxCostMs = 0;

  // ---------- 原生自报耗时（可选）----------
  static int _nativeCostCount = 0;
  static int _totalNativeCostMs = 0;

  // ---------- 并发 / 批次 ----------
  static int _inflight = 0;
  static int _inflightPeak = 0;
  static int _batches = 0;

  static int get attempted => _attempted;
  static int get okCount => _ok;
  static int get failedCount => _failed;
  static int get timeoutCount => _timeout;
  static int get inflight => _inflight;
  static int get inflightPeak => _inflightPeak;
  static int get batches => _batches;

  /// 回合开始（派发前调用）：在飞 +1 并刷新峰值。
  static void markStart() {
    if (!enabled) return;
    _inflight++;
    if (_inflight > _inflightPeak) _inflightPeak = _inflight;
  }

  /// 回合结束：登记结果与耗时，在飞 -1。
  ///
  /// [timeout] 为 true 时计入超时（不再计入失败），[nativeCostMs] 为原生侧自报
  /// 单张耗时（可选），[degraded] 为降级标记（如走 Worker，可选）。
  static void markEnd({
    required bool ok,
    required Duration cost,
    bool timeout = false,
    int? nativeCostMs,
    String? degraded,
  }) {
    if (!enabled) return;
    if (_inflight > 0) _inflight--;
    _attempted++;
    if (timeout) {
      _timeout++;
    } else if (ok) {
      _ok++;
    } else {
      _failed++;
    }
    final ms =
        cost.inMicroseconds <= 0 ? 0 : (cost.inMicroseconds / 1000).round();
    _costCount++;
    _totalCostMs += ms;
    if (_costCount == 1 || ms < _minCostMs) _minCostMs = ms;
    if (ms > _maxCostMs) _maxCostMs = ms;
    if (nativeCostMs != null && nativeCostMs >= 0) {
      _nativeCostCount++;
      _totalNativeCostMs += nativeCostMs;
    }
  }

  /// 回合异常丢失（派发前抛错等）时回收在飞计数，不影响成败统计。
  static void markAborted() {
    if (!enabled) return;
    if (_inflight > 0) _inflight--;
  }

  /// 批次开始（如回填一轮）；批次计数 +1。
  static void startBatch() {
    if (!enabled) return;
    _batches++;
  }

  /// 聚合快照（供导出与断言）。
  static ThumbGenStatsSnapshot snapshot() => ThumbGenStatsSnapshot(
        scenario: scenario,
        attempted: _attempted,
        ok: _ok,
        failed: _failed,
        timeout: _timeout,
        minCostMs: _costCount == 0 ? 0 : _minCostMs,
        maxCostMs: _maxCostMs,
        avgCostMs: _costCount == 0 ? 0 : _totalCostMs / _costCount,
        inflightPeak: _inflightPeak,
        batches: _batches,
        samples: _costCount,
        avgNativeCostMs:
            _nativeCostCount == 0 ? 0 : _totalNativeCostMs / _nativeCostCount,
        nativeSamples: _nativeCostCount,
      );

  /// 聚合 JSON（可落盘/对比）。
  static Map<String, dynamic> toJson() => snapshot().toJson();

  /// JSON 文本导出。
  static String exportJson() => jsonEncode(toJson());

  /// 与 [frame] 以同一 [scenario] 关联导出（T015）：一次拿到缩略图生成埋点与
  /// 丢帧基线，便于「生成耗时/并发」与「主线程丢帧」对照判定。
  static Map<String, dynamic> exportScenario({FrameBaseline? frame}) {
    final out = <String, dynamic>{
      'scenario': scenario,
      'thumbGen': toJson(),
      if (frame != null) 'frame': frame.toJson(),
    };
    return out;
  }

  /// 清零（测试与新一轮采集用）。
  static void reset() {
    _attempted = 0;
    _ok = 0;
    _failed = 0;
    _timeout = 0;
    _costCount = 0;
    _totalCostMs = 0;
    _minCostMs = 0;
    _maxCostMs = 0;
    _nativeCostCount = 0;
    _totalNativeCostMs = 0;
    _inflight = 0;
    _inflightPeak = 0;
    _batches = 0;
  }
}

/// [ThumbGenStats] 的一次聚合快照（不可变）。
class ThumbGenStatsSnapshot {
  const ThumbGenStatsSnapshot({
    required this.scenario,
    required this.attempted,
    required this.ok,
    required this.failed,
    required this.timeout,
    required this.minCostMs,
    required this.maxCostMs,
    required this.avgCostMs,
    required this.inflightPeak,
    required this.batches,
    required this.samples,
    required this.avgNativeCostMs,
    required this.nativeSamples,
  });

  final String scenario;
  final int attempted;
  final int ok;
  final int failed;
  final int timeout;

  /// 单张往返耗时统计（ms）。
  final int minCostMs;
  final int maxCostMs;
  final double avgCostMs;

  /// 在飞峰值与批次数。
  final int inflightPeak;
  final int batches;

  /// 参与耗时统计的样本数。
  final int samples;

  /// 原生侧自报耗时（可选，ms）。
  final double avgNativeCostMs;
  final int nativeSamples;

  /// 是否可据埋点判定「生成已离开 UI 主线程」（原生样本存在且往返耗时不再
  /// 出现由主线程阻塞引起的极端长尾；此处仅给出数据可得性判断，最终判定见 baseline.md）。
  bool get hasThreadAttributionEvidence => nativeSamples > 0;

  Map<String, dynamic> toJson() => {
        'scenario': scenario,
        'attempted': attempted,
        'ok': ok,
        'failed': failed,
        'timeout': timeout,
        'minCostMs': minCostMs,
        'maxCostMs': maxCostMs,
        'avgCostMs': double.parse(avgCostMs.toStringAsFixed(2)),
        'inflightPeak': inflightPeak,
        'batches': batches,
        'samples': samples,
        'avgNativeCostMs': double.parse(avgNativeCostMs.toStringAsFixed(2)),
        'nativeSamples': nativeSamples,
      };
}
