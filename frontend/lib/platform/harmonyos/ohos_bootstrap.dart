import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:sqlite3/open.dart' as sqlite3_open;

import 'just_audio_fvp.dart';
import 'secure_storage_ohos.dart';

/// 当前是否运行在 HarmonyOS（ohos）。
///
/// 不用 `Platform.isOhos`：stable 工具链的 dart:io 没有该 getter，
/// `operatingSystem` 字符串比较在两套 SDK 下都可编译且行为一致。
bool get isOhos => !kIsWeb && Platform.operatingSystem == 'ohos';

/// ohos 上 sqlite3 的系统库加载函数。
///
/// 必须是顶层函数：sqlite3 异步 API（isolate）场景要求 open 回调可跨
/// isolate 引用（当前仅主 isolate 同步 open，仍按规范写顶层）。
DynamicLibrary _openSqliteOnOhos() => DynamicLibrary.open('libsqlite3.so');

/// HarmonyOS（ohos）启动引导：在 runApp 前、任何插件/存储使用前调用。
///
/// 三件事（全部仅 ohos 生效，其它平台零影响）：
/// 1. sqlite3：package:sqlite3 在 ohos 上默认 `throw UnsupportedError`
///    （OperatingSystem 枚举无 ohos），override 为加载系统 `libsqlite3.so`
///    （本地索引 local_index.dart 依赖）
/// 2. flutter_secure_storage：官方 ohos 桩全版本 sdk<3.0.0 不可用，
///    换 [OhosSecureStorage] 文件实现（PoC 级 base64 混淆，见该文件说明）
/// 3. just_audio：无 ohos 实现，接 [FvpJustAudio]（fvp/libmdk 适配层）
///
/// 其余已在别处收口的 ohos 差异（无需在此处理）：
/// - audio_session：`AudioSession.instance` 在无插件平台 catch 掉
///   MissingPluginException 返回空实现，just_audio 的 handleInterruptions 安全
/// - audio_service / permission_handler：调用点均已 Platform.isAndroid 门控
/// - wakelock_plus：player_screen 调用点有 isOhos guard
Future<void> setupOhos() async {
  if (!isOhos) return;
  debugPrint('[ohos] 启动引导：sqlite3 / secure storage / just_audio(fvp)');
  sqlite3_open.open.overrideForAll(_openSqliteOnOhos);
  FlutterSecureStoragePlatform.instance = OhosSecureStorage();
  JustAudioPlatform.instance = FvpJustAudio();
}
