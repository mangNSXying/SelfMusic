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

/// 退出进程前的平台收口钩子：鸿蒙侧由 main.dart 注册（播控桥收卡——
/// AVSession 销毁 + 长时任务停止，await 300ms 封顶；exit(0) 前未确认
/// destroy 已被 ArkTS 处理的话进程即死、播控卡与长时任务悬挂，表现为
/// 播控中心幽灵卡）。未注册（非鸿蒙/桥未建）直接跳过。
Future<void> Function()? beforeExitHook;

/// 退出进程的统一收口：先跑 [beforeExitHook]（异常吞掉，不许拦住退出），
/// 再 exit(0)。调用方仍需先完成各自的播放器 shutdown / 断点落库。
Future<void> exitAppGracefully() async {
  final hook = beforeExitHook;
  if (hook != null) {
    try {
      await hook();
    } catch (_) {
      // 收口异常不许拦住退出。
    }
  }
  exit(0);
}
