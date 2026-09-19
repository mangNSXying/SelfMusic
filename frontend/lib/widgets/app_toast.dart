import 'package:flutter/material.dart';

/// 全局 toast 顶层钥匙：挂到 `MaterialApp.scaffoldMessengerKey`，
/// 供任意页面/Provider 弹 toast，无需持有 BuildContext。
final GlobalKey<ScaffoldMessengerState> toastMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 轻量 toast（floating SnackBar 造型）。
///
/// 回归统一异常出口：新代码一律用 [AppToast.error] 提示失败/异常，
/// 成功提示用 [AppToast.show]（isError=false）；顶级红字等持久错误可保留。
class AppToast {
  AppToast._();

  static void show(String message, {bool isError = true, int ms = 2800}) {
    final state = toastMessengerKey.currentState;
    if (state == null) {
      debugPrint('[toast]${isError ? ' ERROR' : ''} $message');
      return;
    }
    state
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        backgroundColor: isError ? const Color(0xFFC62828) : const Color(0xE6323232),
        behavior: SnackBarBehavior.floating,
        duration: Duration(milliseconds: ms),
        // 上浮到迷你播放条之上（financially 小屏也可见）。
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 76),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
  }

  /// 异常包装：字符串化异常后以 toast 展示，[prefix] 如「播放失败」。
  static void error(Object e, [String? prefix]) =>
      show('${prefix == null ? '' : '$prefix：'}${_brief(e)}');

  /// 把冗长的异常字符串压缩为可读信息：
  /// just_audio 的 PlayerException 形如 `(1000) Source error`，取 message 部分。
  static String _brief(Object e) {
    final s = e.toString();
    final m = RegExp(r'^\(\d+\)\s+(.*)$').firstMatch(s);
    if (m != null) {
      final msg = m.group(1)!.trim();
      if (msg.isNotEmpty) return msg;
    }
    return s;
  }
}