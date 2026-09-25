import 'dart:io' show Platform;

/// 跨平台运行信息：统一暴露当前平台标识与默认设备名。
///
/// `lib/` 全为跨平台 Dart 代码，这里用 `dart:io` 的 [Platform] 收口平台差异，
/// 供配对等场景上报真实平台（服务器据此区分 Android / Linux 设备）。
class PlatformInfo {
  const PlatformInfo._();

  /// 上报给后端 `devices.platform` 的值。
  ///
  /// ohos 用字符串比较而非 `Platform.isOhos`：stable 工具链的 dart:io
  /// 没有该 getter，字符串判断在两套 SDK 下都可编译且行为一致。
  static String get platform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isIOS) return 'ios';
    if (Platform.operatingSystem == 'ohos') return 'ohos';
    return 'unknown';
  }

  /// 配对默认设备名（跟随平台）。
  static String get defaultDeviceName => 'selfmusic-$platform';
}
