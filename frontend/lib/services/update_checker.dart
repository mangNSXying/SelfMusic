import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/local/app_settings.dart';
import '../platform/harmonyos/ohos_bootstrap.dart' show isOhos;
import '../platform/harmonyos/ohos_platform_bridge.dart';
import '../utils/app_version.dart';
import '../widgets/app_toast.dart';
import '../widgets/update_dialog.dart';
import 'update_service.dart';

/// 「之后提醒」的随机延后天数范围（含端点）。
const int kUpdateSnoozeMinDays = 3;
const int kUpdateSnoozeMaxDays = 7;

/// 生成「之后提醒」延后天数：默认在 3~7 天间随机。
int pickSnoozeDays(Random random) =>
    kUpdateSnoozeMinDays +
    random.nextInt(kUpdateSnoozeMaxDays - kUpdateSnoozeMinDays + 1);

/// 打开线上发布页/下载直链（外部浏览器）。
///
/// 优先当前平台对应的资产直链，找不到才回退发布页；两者皆失败时 toast 提示。
Future<void> openReleaseDownload(ReleaseInfo release) async {
  final downloadUrl = selectDownloadUrl(release);
  final target = downloadUrl ?? release.pageUrl;
  if (target.isEmpty) {
    AppToast.show('未找到可用的下载链接');
    return;
  }
  // 鸿蒙：url_launcher 无平台实现，必须走原生桥的 startAbility（浏览器）。
  if (isOhos) {
    if (await OhosPlatformBridge.openUrl(target)) return;
    AppToast.show('无法打开浏览器，请手动访问：$target');
    return;
  }
  final uri = Uri.tryParse(target);
  if (uri == null) {
    AppToast.show('下载链接无效：$target');
    return;
  }
  try {
    if (await canLaunchUrl(uri)) {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return;
    }
  } catch (e) {
    debugPrint('打开下载链接失败：$e');
  }
  AppToast.show('无法打开浏览器，请手动访问：$target');
}

/// 检查更新的结果分类（便于调用方决定提示文案）。
enum UpdateCheckOutcome {
  /// 有更新并已弹窗（用户已做出选择）。
  prompted,

  /// 已是最新版本。
  upToDate,

  /// 自动检查命中，但被延后/忽略规则拦下（保持静默）。
  suppressed,

  /// 请求失败或无发布版。
  failed,
}

/// 是否应当弹窗提醒本次更新。
///
/// 手动检查恒为 true（用户主动发起，不受延后/忽略影响）；自动检查要求版本
/// 真的更新，且延后已到期、当前版本未被「不再提醒」忽略。[snoozeVersion]
/// 限定延后只压住当时提示的那个版本：期间出了更高版本照常提醒。
bool shouldPromptForUpdate({
  required String releaseTag,
  required String currentVersion,
  required DateTime now,
  DateTime? snoozeUntil,
  String snoozeVersion = '',
  String skipVersion = '',
  bool manual = false,
}) {
  if (!isNewerVersion(releaseTag, currentVersion)) return false;
  if (manual) return true;
  final snoozed = snoozeUntil != null && now.isBefore(snoozeUntil);
  if (snoozed && (snoozeVersion.isEmpty || snoozeVersion == releaseTag)) {
    return false;
  }
  if (skipVersion.isNotEmpty && skipVersion == releaseTag) return false;
  return true;
}

/// 检查更新并（按需）弹出更新弹窗。
///
/// [manual] = true 来自「关于软件 → 检查更新」：不受延后/忽略状态限制，
/// 且无更新/失败时给出 toast；自动检查则全程静默。
Future<UpdateCheckOutcome> checkForUpdate(
  BuildContext context, {
  required AppSettings settings,
  bool manual = false,
  UpdateService? service,
  Random? random,
  DateTime? now,
  String? currentVersion,
}) async {
  final version = currentVersion ?? await AppVersion.load();
  final source = settings.updateSource;

  ReleaseInfo? release;
  try {
    release = await (service ?? UpdateService.instance).fetchLatest(source);
  } catch (e) {
    debugPrint('检查更新失败（$source）：$e');
    if (manual && context.mounted) AppToast.show('检查更新失败，请稍后重试');
    return UpdateCheckOutcome.failed;
  }
  if (!context.mounted) return UpdateCheckOutcome.failed;

  if (release == null || !isNewerVersion(release.tag, version)) {
    if (manual) AppToast.show('已是最新版本', isError: false);
    return UpdateCheckOutcome.upToDate;
  }

  final clock = now ?? DateTime.now();
  if (!shouldPromptForUpdate(
    releaseTag: release.tag,
    currentVersion: version,
    now: clock,
    snoozeUntil: settings.updateSnoozeUntil,
    snoozeVersion: settings.updateSnoozeVersion,
    skipVersion: settings.updateSkipVersion,
    manual: manual,
  )) {
    return UpdateCheckOutcome.suppressed;
  }

  final result = await showUpdateDialog(
    context,
    release: release,
    currentVersion: version,
    onOpenDownload: () => openReleaseDownload(release!),
  );
  switch (result) {
    case UpdateDialogResult.snooze:
      settings.updateSnoozeVersion = release.tag;
      settings.updateSnoozeUntil =
          clock.add(Duration(days: pickSnoozeDays(random ?? Random())));
    case UpdateDialogResult.skipVersion:
      settings.updateSkipVersion = release.tag;
      settings.updateSnoozeUntil = null;
    case UpdateDialogResult.openDownload:
      // 主动更新即视为不再忽略/延后：清了提醒状态，装好后自然不会再提示。
      settings.updateSnoozeUntil = null;
      settings.updateSkipVersion = '';
    case UpdateDialogResult.dismiss:
      // 取消：不改状态，下次启动照常提醒（延后已到期则同样会提醒）。
      break;
  }
  return UpdateCheckOutcome.prompted;
}
