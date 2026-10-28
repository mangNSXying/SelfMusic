import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';

import 'equalizer_backend.dart';
import 'equalizer_types.dart';

/// Windows/Linux：通过 vendored just_audio_media_kit 暴露的 mpv Player，
/// 设置 `af` 链（10 个命名 lavfi-equalizer + 可选 preamp volume）。
///
/// 拖动时用 `af-command` 让实时图平滑变化；300ms 后再用 `af set` 写回
/// 完整链——mpv 的 af-command 不更新存储参数，seek/切歌会按旧参数重建图。
class MpvEqualizerBackend extends EqualizerBackend {
  MpvEqualizerBackend({super.onCapabilitiesChanged});

  Player? _mpv;
  Timer? _commitTimer;
  Timer? _liveTimer;
  Future<void> _op = Future<void>.value();
  bool _disposed = false;
  bool _enabled = false;
  List<double> _gains = List.of(kDefaultEqBands);
  double _preampDb = 0;
  List<double> _liveGains = const [];
  double _livePreampDb = 0;
  EqualizerCapabilities _caps = EqualizerCapabilities.unsupported;

  @override
  EqualizerCapabilities get capabilities => _caps;

  @override
  Future<void> init() async {
    _setCaps(EqualizerCapabilities.mpv);
    await _attachIfNeeded();
    if (_disposed) return;
    await _pushFull();
  }

  /// just_audio 的平台实例初始化是异步的；首次 init 时拿不到 Player 不阻塞，
  /// 后续 apply（切歌/开关/拖动）会继续尝试挂载。
  Future<void> _attachIfNeeded() async {
    if (_mpv != null || _disposed) return;
    final mediaKitPlayer = JustAudioMediaKit.instance?.activePlayer;
    if (mediaKitPlayer == null) return;
    _mpv = mediaKitPlayer.player;
  }

  @override
  Future<void> apply({
    required bool enabled,
    required List<double> gains,
    required double preampDb,
    bool commit = false,
  }) async {
    _enabled = enabled;
    _gains = normalizeEqBands(gains);
    _preampDb = preampDb.clamp(kEqPreampMinDb, kEqPreampMaxDb).toDouble();
    await _attachIfNeeded();
    if (_mpv == null) return;
    if (commit) {
      _commitTimer?.cancel();
      _liveTimer?.cancel();
      await _pushFull();
      return;
    }
    if (_liveGains.length != _gains.length ||
        (_preampDb - _livePreampDb).abs() > 0.01 ||
        !_enabled) {
      _commitTimer?.cancel();
      _liveTimer?.cancel();
      await _pushFull();
      return;
    }
    _liveTimer?.cancel();
    _liveTimer = Timer(const Duration(milliseconds: 30), _sendLiveGains);
    _commitTimer?.cancel();
    _commitTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_pushFull());
    });
  }

  void _sendLiveGains() {
    final player = _mpv;
    if (player == null || !_enabled) return;
    final changed = <int>[];
    for (var i = 0; i < _gains.length && i < _liveGains.length; i++) {
      if ((_gains[i] - _liveGains[i]).abs() > 0.001) changed.add(i);
    }
    if (changed.isEmpty) return;
    _liveGains = List.of(_gains);
    for (final i in changed) {
      unawaited(_command(<String>[
        'af-command',
        'eq$i',
        'gain',
        _gains[i].toStringAsFixed(2),
        'equalizer',
      ]));
    }
  }

  Future<void> _pushFull() {
    if (_disposed) return Future<void>.value();
    final chain = _enabled
        ? buildMpvEqualizerChain(gains: _gains, preampDb: _preampDb)
        : '';
    _liveGains = List.of(_gains);
    _livePreampDb = _preampDb;
    return _command(<String>['af', 'set', chain]);
  }

  Future<void> _command(List<String> args) {
    final player = _mpv;
    final native = player?.platform;
    if (native is! NativePlayer) return Future<void>.value();
    final next = _op.then((_) async {
      try {
        await native.command(args);
      } catch (e) {
        debugPrint('[eq] mpv 命令失败 ${args.join(' ')}: $e');
      }
    });
    _op = next;
    return next;
  }

  void _setCaps(EqualizerCapabilities caps) {
    final changed = caps.kind != _caps.kind ||
        caps.bandCount != _caps.bandCount ||
        caps.note != _caps.note;
    _caps = caps;
    if (changed) onCapabilitiesChanged?.call(caps);
  }

  @override
  Future<void> flush() async {
    _commitTimer?.cancel();
    _liveTimer?.cancel();
    await _pushFull();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _commitTimer?.cancel();
    _liveTimer?.cancel();
    _mpv = null;
  }
}
