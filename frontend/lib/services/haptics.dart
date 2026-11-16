import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform/harmonyos/ohos_bootstrap.dart' show isOhos;

/// 触感强度：滚轮换档/页签切换用 selection，普通按键用 light，长按用 medium。
enum HapticStrength { selection, light, medium }

/// 平台震动实现。Android/鸿蒙走 MethodChannel，其余平台 no-op。
abstract class HapticsPlatform {
  const HapticsPlatform();

  /// 是否为手机/平板通道实现（桌面/Web 为 false，设置行据此隐藏）。
  bool get isMobile;

  Future<bool> hasVibrator();

  Future<bool> vibrate({required int durationMs, int? amplitude});

  /// Android 与鸿蒙共用同名通道（先例：audio_guard），Dart 侧解码零分叉。
  static HapticsPlatform forCurrentPlatform() {
    if (!kIsWeb && (Platform.isAndroid || isOhos)) {
      return const ChannelHapticsPlatform();
    }
    return const NoopHapticsPlatform();
  }
}

/// 原生通道实现；[channel] 可注入，便于单测 mock。
class ChannelHapticsPlatform extends HapticsPlatform {
  const ChannelHapticsPlatform([
    MethodChannel channel = const MethodChannel('com.shamiko.selfmusic/vibration'),
  ]) : _channel = channel;

  final MethodChannel _channel;

  @override
  bool get isMobile => true;

  @override
  Future<bool> hasVibrator() async {
    try {
      return await _channel.invokeMethod<bool>('hasVibrator') ?? false;
    } on MissingPluginException {
      debugPrint('[haptic] hasVibrator 通道未注册');
      return false;
    } on PlatformException catch (e) {
      debugPrint('[haptic] hasVibrator 失败：${e.code} ${e.message}');
      return false;
    } catch (e) {
      debugPrint('[haptic] hasVibrator 异常：$e');
      return false;
    }
  }

  @override
  Future<bool> vibrate({required int durationMs, int? amplitude}) async {
    try {
      final ok = await _channel.invokeMethod<bool>('vibrate', {
        'durationMs': durationMs,
        if (amplitude != null) 'amplitude': amplitude,
      });
      return ok ?? false;
    } on MissingPluginException {
      debugPrint('[haptic] vibrate 通道未注册');
      return false;
    } on PlatformException catch (e) {
      debugPrint('[haptic] vibrate 失败：${e.code} ${e.message}');
      return false;
    } catch (e) {
      debugPrint('[haptic] vibrate 异常：$e');
      return false;
    }
  }
}

/// 桌面/Web/iOS：不调用任何通道，静默降级。
class NoopHapticsPlatform extends HapticsPlatform {
  const NoopHapticsPlatform();

  @override
  bool get isMobile => false;

  @override
  Future<bool> hasVibrator() async => false;

  @override
  Future<bool> vibrate({required int durationMs, int? amplitude}) async => false;
}

/// 全局触感门面：设置开关 + 平台能力 + 马达探测三重门控。
///
/// 只在共享 widget 层触发，避免同一动作在页面与组件两处重复震动。
class Haptics {
  Haptics._();

  static HapticsPlatform platform = HapticsPlatform.forCurrentPlatform();

  /// 与设置项 `haptic_feedback` 同步；main.dart 启动时初始化。
  static bool enabled = true;

  static bool? _hasVibrator;

  static bool get capable => platform.isMobile;

  /// 探测完成前按「有马达」处理，避免首个点击被误吞。
  static bool get hasVibrator => _hasVibrator ?? true;

  /// 进程内只探测一次；设置页也会调用，重复调用直接返回。
  static Future<void> probe() async {
    if (_hasVibrator != null) return;
    if (!capable) {
      _hasVibrator = false;
      return;
    }
    final result = await platform.hasVibrator();
    _hasVibrator = result;
    if (!result) debugPrint('[haptic] 设备未报告振动马达');
  }

  static void fire(HapticStrength strength) {
    if (!enabled || !capable || _hasVibrator == false) return;
    final spec = _spec(strength);
    unawaited(platform.vibrate(durationMs: spec.$1, amplitude: spec.$2));
  }

  static (int, int) _spec(HapticStrength strength) => switch (strength) {
        HapticStrength.selection => (5, 60),
        HapticStrength.light => (10, 110),
        HapticStrength.medium => (20, 180),
      };

  @visibleForTesting
  static void debugReset({HapticsPlatform? platform, bool enabled = true}) {
    Haptics.platform = platform ?? HapticsPlatform.forCurrentPlatform();
    Haptics.enabled = enabled;
    _hasVibrator = null;
  }
}
