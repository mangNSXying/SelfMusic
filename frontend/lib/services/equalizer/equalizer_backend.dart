import 'package:flutter/foundation.dart';

import 'equalizer_types.dart';

/// 平台均衡器后端：统一接收 10 段标准参数，内部自行映射到设备能力。
abstract class EqualizerBackend {
  EqualizerBackend({this.onCapabilitiesChanged});

  final ValueChanged<EqualizerCapabilities>? onCapabilitiesChanged;

  EqualizerCapabilities get capabilities;

  Future<void> init();

  Future<void> apply({
    required bool enabled,
    required List<double> gains,
    required double preampDb,
    bool commit = false,
  });

  /// 拖动结束后把实时参数落成可跨 seek/切歌保留的存储参数。
  Future<void> flush();

  Future<void> dispose();
}
