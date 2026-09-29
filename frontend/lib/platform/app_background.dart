import 'dart:io';

import 'package:flutter/services.dart';

import 'harmonyos/ohos_bootstrap.dart' show isOhos;

/// 把应用移到后台（等效 home 键，不销毁 Activity/UIAbility）。
///
/// 移动端返回手势的后台化：侧滑/返回键不退出应用而是转后台，音乐后台
/// 续播（2026-09-29 用户反馈：侧滑返回直接退出应用，无法后台播放）。
/// 桌面端无此概念恒 false；通道异常（极端环境）同样返回 false，
/// 由调用方自行兜底（见 main.dart _onPopInvoked）。
Future<bool> moveAppToBackground() async {
  try {
    if (Platform.isAndroid) {
      const channel = MethodChannel('com.shamiko.selfmusic/app');
      await channel.invokeMethod<void>('moveToBackground');
      return true;
    }
    if (isOhos) {
      const channel = MethodChannel('selfmusic/app');
      await channel.invokeMethod<void>('moveToBackground');
      return true;
    }
  } catch (_) {
    // 通道未注册 / 原生侧异常：不算成功，调用方走兜底路径。
  }
  return false;
}
