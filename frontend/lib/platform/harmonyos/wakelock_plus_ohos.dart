import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

import 'ohos_platform_bridge.dart';

/// 鸿蒙端 wakelock_plus 平台实现（2026-10-06 ohos-permissions feature）：
/// 转接 selfmusic/platform 通道的 keepScreenOn（ArkTS 侧
/// window.setWindowKeepScreenOn，无需权限声明）。
///
/// 背景：wakelock_plus 无鸿蒙平台包，默认实例 MethodChannelWakelockPlus
/// 在 ohos 上抛 MissingPluginException——播放器页此前以
/// `Platform.operatingSystem != 'ohos'` guard 掉 enable/disable，本类就位
/// 后 guard 移除、常亮真正生效。
///
/// `enabled` 仅维护本地回显状态：窗口级 keepScreenOn 无系统查询接口，
/// 且退后台随窗口失焦自动失效、回前台由播放器页按播放态重新拉起
/// （WakelockPlus.enable/disable），本地状态即事实状态的充分近似。
class OhosWakelockPlusPlatform extends WakelockPlusPlatformInterface {
  bool _enabled = false;

  @override
  Future<void> toggle({required bool enable}) async {
    // 窗口获取失败 ArkTS 侧 error 上抛 → WakelockPlus.enable 抛出；
    // 调用方（播放器页）fire-and-forget 不 await，异常进全局错误日志
    // 不中断播放。
    await OhosPlatformBridge.keepScreenOn(enable);
    _enabled = enable;
  }

  @override
  Future<bool> get enabled async => _enabled;
}
