import 'dart:math' as math;

/// 均衡器统一参数模型（settings.md §3.2）。
///
/// 所有平台共用同一组标准频率与 10 段增益，存储/导出/同步只保存增益，
/// 不保存设备频段——Android 原生回退、mpv 链都由这组参数映射出来。
const int kEqBandCount = 10;
const double kEqMinDb = -12;
const double kEqMaxDb = 12;
const double kEqPreampMinDb = -12;
const double kEqPreampMaxDb = 0;

const List<double> kEqFrequencies = [
  31.5,
  63,
  125,
  250,
  500,
  1000,
  2000,
  4000,
  8000,
  16000,
];

const List<String> kEqFrequencyLabels = [
  '31',
  '63',
  '125',
  '250',
  '500',
  '1k',
  '2k',
  '4k',
  '8k',
  '16k',
];

const List<double> kDefaultEqBands = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];

/// 旧版 5 段标签对应的近似中心频率（迁移用）。
const List<double> kEqV1Frequencies = [60, 230, 910, 3600, 14000];

class EqPreset {
  const EqPreset(this.name, this.gains);

  final String name;
  final List<double> gains;
}

const List<EqPreset> kEqPresets = [
  EqPreset('平直', kDefaultEqBands),
  EqPreset('流行', [-1, 2, 4, 3, 0, -1, -1, 1, 2, 3]),
  EqPreset('摇滚', [5, 4, 2, 0, -1, -1, 0, 2, 3, 4]),
  EqPreset('爵士', [3, 2, 1, 2, 1, 0, 1, 2, 3, 4]),
  EqPreset('古典', [4, 3, 2, 1, 0, 0, 0, 1, 2, 3]),
  EqPreset('人声', [-2, -1, 0, 3, 5, 5, 3, 1, 0, -1]),
  EqPreset('低音', [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
];

/// 旧 5 段（60/230/910/3.6k/14k）按对数频率插值到 10 段。
List<double> migrateEqBandsV1ToV2(Iterable<dynamic> old) {
  final src = old.map((e) => (e as num).toDouble()).toList(growable: false);
  if (src.length != kEqV1Frequencies.length) {
    return List<double>.of(kDefaultEqBands);
  }
  final out = List<double>.filled(kEqBandCount, 0);
  for (var i = 0; i < kEqBandCount; i++) {
    out[i] = _interpolateLogGain(kEqFrequencies[i], src)
        .clamp(kEqMinDb, kEqMaxDb)
        .toDouble();
  }
  return out;
}

double _interpolateLogGain(double frequency, List<double> gains) {
  if (frequency <= kEqV1Frequencies.first) return gains.first;
  if (frequency >= kEqV1Frequencies.last) return gains.last;
  for (var i = 0; i < kEqV1Frequencies.length - 1; i++) {
    final f0 = kEqV1Frequencies[i];
    final f1 = kEqV1Frequencies[i + 1];
    if (frequency > f1) continue;
    final t =
        (math.log(frequency) - math.log(f0)) / (math.log(f1) - math.log(f0));
    return gains[i] + (gains[i + 1] - gains[i]) * t;
  }
  return gains.last;
}

/// 把任意长度输入规范成 10 段（多截少补 0），并钳制到统一 dB 范围。
List<double> normalizeEqBands(Iterable<dynamic> raw) {
  final src = raw.toList(growable: false);
  return List<double>.generate(kEqBandCount, (i) {
    if (i >= src.length) return 0;
    return (src[i] as num).toDouble().clamp(kEqMinDb, kEqMaxDb).toDouble();
  });
}

bool eqBandsMatch(List<double> a, List<double> b, {double tolerance = 0.05}) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > tolerance) return false;
  }
  return true;
}

EqPreset? matchingEqPreset(List<double> gains) {
  for (final p in kEqPresets) {
    if (eqBandsMatch(p.gains, gains)) return p;
  }
  return null;
}

/// 桌面 libmpv 的 `af` 链：10 个命名 peaking filter + 可选 preamp 衰减。
///
/// 命名 label 供拖动时 `af-command eqN gain ...` 实时更新；preamp 用
/// lavfi-volume 放在链首，避免正增益叠加后削波。
String buildMpvEqualizerChain({
  required List<double> gains,
  required double preampDb,
}) {
  final parts = <String>[];
  final pre = preampDb.clamp(kEqPreampMinDb, kEqPreampMaxDb).toDouble();
  if (pre < -0.05) {
    parts.add('@pre:lavfi-volume=volume=${pre.toStringAsFixed(1)}dB');
  }
  for (var i = 0; i < kEqBandCount; i++) {
    final gain =
        (i < gains.length ? gains[i] : 0).clamp(kEqMinDb, kEqMaxDb).toDouble();
    parts.add(
      '@eq$i:lavfi-equalizer=frequency=${_fmtFrequency(kEqFrequencies[i])}'
      ':width_type=q:width=1.414:gain=${gain.toStringAsFixed(2)}',
    );
  }
  return parts.join(',');
}

String _fmtFrequency(double f) {
  if (f == f.roundToDouble()) return f.round().toString();
  return f.toStringAsFixed(1);
}

/// 后端能力信息：UI 用来展示平台/回退状态。
enum EqBackendKind { dynamics, equalizer, mpv, unsupported }

class EqualizerCapabilities {
  const EqualizerCapabilities({
    required this.kind,
    required this.bandCount,
    required this.frequencies,
    required this.minDb,
    required this.maxDb,
    this.note,
  });

  final EqBackendKind kind;
  final int bandCount;
  final List<double> frequencies;
  final double minDb;
  final double maxDb;
  final String? note;

  bool get supported => kind != EqBackendKind.unsupported;
  bool get isFallback => kind == EqBackendKind.equalizer;

  static const EqualizerCapabilities unsupported = EqualizerCapabilities(
    kind: EqBackendKind.unsupported,
    bandCount: 0,
    frequencies: [],
    minDb: kEqMinDb,
    maxDb: kEqMaxDb,
    note: '当前平台暂不支持应用级均衡器',
  );

  static const EqualizerCapabilities mpv = EqualizerCapabilities(
    kind: EqBackendKind.mpv,
    bandCount: kEqBandCount,
    frequencies: kEqFrequencies,
    minDb: kEqMinDb,
    maxDb: kEqMaxDb,
  );

  factory EqualizerCapabilities.fromChannelMap(Map<dynamic, dynamic>? map) {
    if (map == null) return unsupported;
    final rawKind = map['kind'];
    final kind = switch (rawKind) {
      'dynamics' => EqBackendKind.dynamics,
      'equalizer' => EqBackendKind.equalizer,
      'mpv' => EqBackendKind.mpv,
      _ => EqBackendKind.unsupported,
    };
    final rawFreqs = map['frequencies'];
    final freqs = rawFreqs is List
        ? rawFreqs
            .whereType<num>()
            .map((e) => e.toDouble())
            .toList(growable: false)
        : const <double>[];
    return EqualizerCapabilities(
      kind: kind,
      bandCount: (map['bandCount'] as num?)?.toInt() ?? freqs.length,
      frequencies: freqs,
      minDb: (map['minDb'] as num?)?.toDouble() ?? kEqMinDb,
      maxDb: (map['maxDb'] as num?)?.toDouble() ?? kEqMaxDb,
      note: map['note'] as String?,
    );
  }
}
