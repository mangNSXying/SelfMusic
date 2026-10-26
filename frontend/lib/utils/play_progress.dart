/// 播放进度统计（中位播放进度）：101 桶直方图 + 升权门槛。
///
/// 一次播放占用在离开曲目时记一个最终进度样本（0..100%）。直方图只保存
/// 每桶次数，不保存逐条明细；跨设备同步时按桶取 max（服务端为事件累加的
/// 权威值，客户端快照合并不会重复计数）。
library;

import 'dart:convert';

class PlayProgressHistogram {
  /// 0..100 共 101 桶，1% 粒度。
  static const int bucketCount = 101;

  /// 少于 3 条样本时中位线不可评比，升权闸门视为不满足。
  static const int minSamples = 3;

  final List<int> _counts;

  PlayProgressHistogram._(this._counts);

  factory PlayProgressHistogram.empty() =>
      PlayProgressHistogram._(List<int>.filled(bucketCount, 0));

  factory PlayProgressHistogram.fromJson(Object? raw) {
    Object? decoded = raw;
    if (decoded is String) {
      if (decoded.trim().isEmpty) return PlayProgressHistogram.empty();
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return PlayProgressHistogram.empty();
      }
    }
    if (decoded is! List) return PlayProgressHistogram.empty();
    final counts = List<int>.filled(bucketCount, 0);
    final n = decoded.length < bucketCount ? decoded.length : bucketCount;
    for (var i = 0; i < n; i++) {
      final v = decoded[i];
      if (v is num) {
        final c = v.toInt();
        counts[i] = c < 0 ? 0 : c;
      }
    }
    return PlayProgressHistogram._(counts);
  }

  int get total {
    var n = 0;
    for (final c in _counts) {
      n += c;
    }
    return n;
  }

  bool get isEmpty => total == 0;

  PlayProgressHistogram record(int percent) {
    final next = List<int>.of(_counts);
    next[clampProgressPercent(percent)]++;
    return PlayProgressHistogram._(next);
  }

  /// 快照/基线合并：按桶取 max。服务端事件累加值 >= 本地已确认值，
  /// 因此不会把本地未确认样本抹小，也不会把同一事件重复相加。
  PlayProgressHistogram mergeMax(PlayProgressHistogram other) {
    final next = List<int>.of(_counts);
    for (var i = 0; i < bucketCount; i++) {
      if (other._counts[i] > next[i]) next[i] = other._counts[i];
    }
    return PlayProgressHistogram._(next);
  }

  /// 全历史中位数：偶数样本取中间两桶的均值；无样本返回 null。
  double? get medianPercent {
    final n = total;
    if (n == 0) return null;
    final lowerRank = (n - 1) ~/ 2;
    final upperRank = n ~/ 2;
    int? lower;
    int? upper;
    var cumulative = 0;
    for (var i = 0; i < bucketCount; i++) {
      cumulative += _counts[i];
      if (lower == null && cumulative > lowerRank) lower = i;
      if (upper == null && cumulative > upperRank) {
        upper = i;
        break;
      }
    }
    return (lower! + upper!) / 2.0;
  }

  String? toJsonOrNull() => isEmpty ? null : jsonEncode(_counts);

  List<int> toList() => List<int>.unmodifiable(_counts);
}

int clampProgressPercent(int percent) => percent.clamp(0, 100).toInt();

/// 离开曲目时的最终进度百分比；自然结束固定 100%。
///
/// 时长未知且非自然结束返回 null（无法采样）。与 `judgeWeightRatio` 同口径：
/// 调用方传播放器实际时长，不用歌曲元数据兜底。
int? progressPercentOf(
  Duration? duration,
  Duration position, {
  bool completed = false,
}) {
  if (completed) return 100;
  if (duration == null || duration.inMilliseconds <= 0) return null;
  final pct = (position.inMilliseconds * 100) ~/ duration.inMilliseconds;
  return pct.clamp(0, 100).toInt();
}

/// 目标权重对应的升权中位门槛；目标 <= 1.0 不设闸门（返回 null）。
///
/// 1.1 → 50%，1.2 → 55%，…，1.5 → 70%；离群档位按线性公式外推。
double? requiredMedianPercent(double targetFactor) {
  if (targetFactor <= 1.0 + 1e-9) return null;
  final v = (50 + (targetFactor - 1.1) * 50).clamp(0.0, 100.0).toDouble();
  return (v * 100).roundToDouble() / 100;
}

/// 中位线是否放行升权：目标 <= 1.0 放行；样本不足 3 条拒绝；否则中位数 >= 门槛。
bool allowsUpgrade(PlayProgressHistogram hist, double targetFactor) {
  final required = requiredMedianPercent(targetFactor);
  if (required == null) return true;
  if (hist.total < PlayProgressHistogram.minSamples) return false;
  final median = hist.medianPercent;
  return median != null && median + 1e-9 >= required;
}

/// 界面展示：整数不带小数点，无样本显示 `—`。
String formatMedianProgress(double? percent) {
  if (percent == null) return '—';
  return percent % 1 == 0
      ? '${percent.toInt()}%'
      : '${percent.toStringAsFixed(1)}%';
}
