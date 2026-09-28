import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:sqlite3/open.dart' as sqlite3_open;

import 'just_audio_fvp.dart';
import 'path_provider_ohos_retry.dart';
import 'secure_storage_ohos.dart';

/// 与 ArkTS 侧 EntryAbility 启动看门狗约定的通道（见 EntryAbility.ets）。
const MethodChannel _bootChannel = MethodChannel('selfmusic/boot');

/// 上报「Dart 启动就绪」：main() 完成 runApp 后调用一次（main.dart）。
///
/// ArkTS 看门狗若超时未收到，会主动向 Dart 发 poke 消息：证明消息通道
/// 存活、断言/驱动 path_provider 重试包装（保险机制，定位史见
/// [path_provider_ohos_retry.dart] 头注释）。非 ohos 平台为 no-op。
void markBootReady() {
  if (!isOhos) return;
  _bootChannel
      .invokeMethod('ready')
      .then((_) {}, onError: (Object e) => debugPrint('[ohos] ready 上报失败: $e'));
}

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
/// 四件事（全部仅 ohos 生效，其它平台零影响）：
/// 1. sqlite3：package:sqlite3 在 ohos 上默认 `throw UnsupportedError`
///    （OperatingSystem 枚举无 ohos），override 为加载系统 `libsqlite3.so`
///    （本地索引 local_index.dart 依赖）
/// 2. flutter_secure_storage：官方 ohos 桩全版本 sdk<3.0.0 不可用，换
///    [OhosSecureStorage] 文件实现；且包前端 `_selectOptions` 在 ohos 上
///    必抛 UnsupportedError（启动白屏真凶），默认实例经
///    [createSecureStorage] 绕过包前端（见该文件说明）
/// 3. just_audio：无 ohos 实现，接 [FvpJustAudio]（fvp/libmdk 适配层）
/// 4. path_provider：保险层——多点惰性断言安装重试包装（verify-4 实证
///    注册器在 main 前已跑完、从未覆盖；断言防未来引擎行为变化），在途
///    调用由看门狗 poke 驱动重发；超时重发与兜底路径仅作附加保险
///    （取证与定位史见 [OhosRetryingPathProvider] 文件头）
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
  // 装上重试包装（启动链所有路径调用均经 PathProviderPlatform.instance）。
  // verify-4 实证引擎注册器在 main() 之前已跑完、不会覆盖包装；多点断言
  // （此处 / 每次 poke / 首次路径调用现场）仅防未来引擎行为变化。
  ensureOhosPathWrapper('setupOhos');
  // 看门狗 poke 的落点，三个作用：
  // 1. 证明消息通道存活（poke 自身收发回执全程毫秒级正常）；
  // 2. 断言包装在位（防未来引擎行为变化的保险）；
  // 3. 驱动在途平台调用重发——若「单条回复丢失」真发生，重发的新回复
  //    产生于健康时段、可正常投递（见 OhosRetryingPathProvider 头注释）。
  _bootChannel.setMethodCallHandler((call) async {
    debugPrint('[ohos] 收到 ArkTS 看门狗 ${call.method}');
    ensureOhosPathWrapper('poke');
    OhosRetryingPathProvider.nudgeAllPending();
    return null;
  });
  // 【保守约束】本函数与 main() 直至 runApp 的整条链上，不要 await 任何
  // 依赖 Timer 的东西（Future.delayed / .timeout() / Timer 完成回调）：
  // 「启动期 Timer 不触发」未被证实也未被证伪（旧观察与「main 早已死亡」
  // 无法区分，见 path_provider_ohos_retry.dart 头注释定位史），启动关键
  // 路径不押注 Timer；平台消息的 await 由 poke 驱动重发兜底（上方
  // handler）；dart:io 的异步文件 I/O 与 sqlite3 FFI 不经 Timer，安全。
}
