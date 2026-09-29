/// 时长削弱（改进.txt 功能8）：加权抽样时的「权重-时长」分段函数。
///
/// 分段由设置 `设置>歌曲` 配置（`app_settings.weightCurveSegments`），本类只做
/// 读取期即时计算，不落库、不改 play_meta，服务端零改动。作用域为选定区间：
/// 命中第一段即止，未命中返回 1.0（不削弱）。
class WeightCurve {
  final bool enabled;
  final List<WeightCurveSegment> segments;

  const WeightCurve({this.enabled = false, this.segments = const []});

  /// 该曲时长对应的削弱系数：开关关 / 时长未知（NULL/0）/ 未命中任何区间 → 1.0。
  double multiplierFor(double? durationSec) {
    if (!enabled || durationSec == null || durationSec <= 0) return 1.0;
    for (final s in segments) {
      final min = s.minSec;
      final max = s.maxSec;
      if (durationSec >= min && (max == null || durationSec < max)) {
        return s.factor;
      }
    }
    return 1.0;
  }

  /// 便捷入口：从设置片段构建（无效片段静默丢弃，factor 钳制到权重上下界）。
  factory WeightCurve.fromSettings(bool enabled, List<Map<String, Object?>> segments) {
    final out = <WeightCurveSegment>[];
    for (final m in segments) {
      final min = _num(m['min_sec']);
      if (min == null || min <= 0) continue; // 起始时长必填且 >0
      final max = _num(m['max_sec']);
      final f = _num(m['factor']);
      if (f == null || f <= 0) continue;
      if (max != null && max <= min) continue; // 区间必须有序（空 max=无上限）
      out.add(WeightCurveSegment(
        minSec: min,
        maxSec: max,
        factor: f.clamp(0.5, 1.5),
      ));
    }
    out.sort((a, b) => a.minSec.compareTo(b.minSec));
    return WeightCurve(enabled: enabled, segments: out);
  }

  static double? _num(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}

/// 一段「权重-时长」区间：`[minSec, maxSec)`（maxSec 为空 = 无上限）。
class WeightCurveSegment {
  final double minSec;
  final double? maxSec;
  final double factor;

  const WeightCurveSegment({
    required this.minSec,
    this.maxSec,
    required this.factor,
  });
}