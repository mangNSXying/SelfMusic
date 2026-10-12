import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/direct_source_manager.dart';
import '../widgets/app_toast.dart';

/// 网址输入框共享逻辑：`https://` 可视化自动补全 + `http://` 弹窗引导。
///
/// 约束：仅走 HTTP 的地址使用（后端地址、WebDAV 地址）。
/// SFTP/SMB/本地路径不走 HTTP，禁止调用这里（见各弹窗注释）。

/// 是否带有 scheme（大小写不敏感，`HTTP://` 也算有）。
/// scheme 段含空白视为无 scheme，避免 `https ://` 误判。
bool urlHasScheme(String input) {
  final s = input.trim();
  if (s.isEmpty) return false;
  final i = s.indexOf('://');
  if (i <= 0) return false;
  final scheme = s.substring(0, i);
  if (scheme.contains(RegExp(r'\s'))) return false;
  return true;
}

/// 是否为显式 `http://`（大小写不敏感，前后空格已容忍）。
bool urlIsExplicitHttp(String input) {
  final s = input.trim();
  final i = s.indexOf('://');
  if (i <= 0) return false;
  return s.substring(0, i).trim().toLowerCase() == 'http';
}

/// 缺 scheme 时补 `https://`（已 trim；空串原样返回；已有 scheme 原样返回 trimmed）。
String urlWithHttpsPrefix(String input) {
  final s = input.trim();
  if (s.isEmpty) return s;
  if (urlHasScheme(s)) return s;
  return 'https://$s';
}

/// 把补全结果写回输入框（可视化）：返回 true 表示发生过修改。
/// 同时把光标移到末尾，避免补前缀后光标错位。
bool applyHttpsPrefixToController(TextEditingController ctrl) {
  final before = ctrl.text;
  final after = urlWithHttpsPrefix(before);
  if (after == before) return false;
  ctrl.text = after;
  ctrl.selection = TextSelection.collapsed(offset: after.length);
  return true;
}

/// 失焦/保存时调用：补全 + toast 提示用户。返回是否发生补全。
bool autoCompleteUrlController(TextEditingController ctrl) {
  final changed = applyHttpsPrefixToController(ctrl);
  if (changed) {
    AppToast.show('已自动补全 https:// 前缀', isError: false);
  }
  return changed;
}

/// `http://` 二次确认：开关已开或非 http 直接放行（true）；
/// 否则弹窗询问，一键开启「允许不安全 HTTP」后返回 true，取消返回 false。
Future<bool> ensureHttpAllowed(BuildContext context, String url) async {
  if (!urlIsExplicitHttp(url)) return true;
  bool allowed = false;
  try {
    allowed = context.read<DirectSourceManager>().settings.allowInsecureHttp;
  } catch (_) {
    allowed = false;
  }
  if (allowed) return true;
  final enable = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('检测到明文 HTTP'),
      content: const Text(
          '当前地址使用明文 http://，默认已被关闭。\n\n可前往「设置 → 服务端 → 网络与安全」开启「允许不安全 HTTP」，或改用 https://。\n\n是否现在开启并继续保存？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(c).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(c).pop(true),
          child: const Text('去开启并继续'),
        ),
      ],
    ),
  );
  if (enable != true) return false;
  if (!context.mounted) return true;
  context.read<DirectSourceManager>().settings.allowInsecureHttp = true;
  AppToast.show('已开启「允许不安全 HTTP」', isError: false);
  return true;
}
