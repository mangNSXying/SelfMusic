import 'equalizer_backend.dart';
import 'equalizer_types.dart';

/// 无应用级均衡器能力的平台（当前为鸿蒙 AVPlayer / Web）。
class UnsupportedEqualizerBackend extends EqualizerBackend {
  UnsupportedEqualizerBackend(
      {required this.note, super.onCapabilitiesChanged});

  final String note;

  @override
  EqualizerCapabilities get capabilities => EqualizerCapabilities(
        kind: EqBackendKind.unsupported,
        bandCount: 0,
        frequencies: const [],
        minDb: kEqMinDb,
        maxDb: kEqMaxDb,
        note: note,
      );

  @override
  Future<void> init() async {}

  @override
  Future<void> apply({
    required bool enabled,
    required List<double> gains,
    required double preampDb,
    bool commit = false,
  }) async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}
