import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../data/sources/local_file_direct_source.dart';
import '../../../platform/harmonyos/ohos_bootstrap.dart';
import '../../../platform/harmonyos/ohos_platform_bridge.dart';
import '../../../widgets/app_toast.dart';

/// 平台文件/目录选择：把鸿蒙与桌面的差异全部收在这里。
///
/// 这些分支都是真机验证过的（file_selector_ohos 的 `getDirectoryPath` 未实现、
/// 鸿蒙需走平台桥并检查持久化授权），因此**只做搬迁不做重构**；弹窗侧只关心
/// 返回的结果。

/// 选目录的返回值：`path` 写入表单的目录字段，`persisted == false` 时弹窗
/// 需要提醒用户「重启后需重新选择」。
class PickedDirectory {
  final String path;
  final bool persisted;
  const PickedDirectory({required this.path, this.persisted = true});
}

/// 选一个本地目录。
///
/// 鸿蒙在系统不支持文件夹选择时返回 null，并**回调** [onUnsupported] 让弹窗
/// 自行决定是否转去选文件（原实现是在这里直接 toast 后调选文件）。
Future<PickedDirectory?> pickSourceDirectory({
  required Future<void> Function() onUnsupported,
}) async {
  if (isOhos) {
    // 点击时才校验 FOLDER 能力：进入本地类型不再预检/自动降级，
    // 避免用户刚选“本地文件夹”就被 toast 打断。
    final supported = await OhosPlatformBridge.supportsFolderSelection();
    if (!supported) {
      AppToast.show('当前系统不支持选择文件夹，已改为选择音频文件', ms: 3000);
      await onUnsupported();
      return null;
    }
    // 鸿蒙：系统目录选择器走平台桥（file_selector_ohos 的 getDirectoryPath
    // 未实现、调用必抛异常）。选定目录 URI 直接写入 path 字段（源配置
    // 结构不变）；用户取消/选择失败不动表单。
    final picked = await OhosPlatformBridge.pickDirectory();
    if (picked == null) return null;
    return PickedDirectory(path: picked.uri, persisted: picked.persisted);
  }
  final dir = await getDirectoryPath(confirmButtonText: '选择');
  if (dir == null) return null;
  return PickedDirectory(path: dir);
}

/// 选音频文件的返回结果（鸿蒙平台桥的原始条目）。
typedef PickedAudioFiles = List<OhosPickedFile>;

/// 选音频文件（鸿蒙 6 手机/平板无系统文件夹选择能力时的降级形态）。
///
/// 返回 null 表示用户取消或平台不支持（错误已 toast）；返回空列表表示用户
/// 确认但没选到可读文件。
Future<PickedAudioFiles?> pickSourceAudioFiles() async {
  try {
    final picked = await OhosPlatformBridge.pickAudioFiles();
    return picked;
  } on PlatformException catch (e) {
    AppToast.show('选择音频文件失败：${e.message ?? e.code}');
    return null;
  } on MissingPluginException catch (e) {
    debugPrint('[ohos] pickAudioFiles 桥未装配: $e');
    AppToast.show('当前平台不支持音频文件导入');
    return null;
  }
}

/// 读一个 PEM 私钥文件：校验 `PRIVATE KEY` 标记与 64KB 上限。
///
/// 返回 null 表示用户取消；非法时抛 [InvalidPrivateKeyException]，弹窗把
/// 文案落到密钥字段的错误位置。
Future<({String pem, String fileName})?> pickPrivateKeyFile() async {
  final picked = await openFile();
  if (picked == null) return null;
  final text = await picked.readAsString();
  if (!text.contains('PRIVATE KEY')) {
    throw const InvalidPrivateKeyException('不是有效的私钥文件（需含 PRIVATE KEY 的 PEM 文本）');
  }
  if (text.length > 65536) {
    throw const InvalidPrivateKeyException('密钥文件过大（>64KB），请确认选对了文件');
  }
  return (pem: text.trim(), fileName: picked.name);
}

class InvalidPrivateKeyException implements Exception {
  final String message;
  const InvalidPrivateKeyException(this.message);

  @override
  String toString() => message;
}
