import 'dart:async';

import 'package:flutter/material.dart';

/// 全局 toast 顶层钥匙：挂到 `MaterialApp.scaffoldMessengerKey`，
/// 供任意页面/Provider 弹 toast，无需持有 BuildContext。（自顶向下经
/// [appNavigatorKey] 弹入根 Overlay，本 key 保留以备兜底）
final GlobalKey<ScaffoldMessengerState> toastMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 根 Navigator 钥匙：toast 以 OverlayEntry 弹在导航层之上，配合
/// `IgnorePointer` 做到「出现弹窗后不阻碍被遮挡控件的点击」（改进.txt §1-2）。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 轻量 toast（浮层造型，强调色半透明、文字居中、点击穿透）。
///
/// 回归统一异常出口：新代码一律用 [AppToast.error] 提示失败/异常，
/// 成功提示用 [AppToast.show]（isError=false）；顶级红字等持久错误可保留。
class AppToast {
  AppToast._();

  static OverlayEntry? _current;
  static Timer? _timer;

  static void show(String message, {bool isError = true, int ms = 2800}) {
    final nav = appNavigatorKey.currentState;
    final overlay = nav?.overlay;
    if (overlay == null) {
      debugPrint('[toast]${isError ? ' ERROR' : ''} $message');
      return;
    }
    // 仅保留最新一条：先摘掉旧 toast，避免浮层堆积。
    _current?.remove();
    _timer?.cancel();
    final entry = OverlayEntry(
      opaque: false,
      builder: (_) => _ToastBubble(message: message, isError: isError),
    );
    _current = entry;
    overlay.insert(entry);
    _timer = Timer(Duration(milliseconds: ms), () {
      if (entry.mounted) entry.remove();
      if (_current == entry) _current = null;
    });
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

/// 扁平浮条本体：强调色半透明圆角、文字居中；外层 IgnorePointer 保证
/// 点击直接穿透到被遮挡控件。
class _ToastBubble extends StatelessWidget {
  const _ToastBubble({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = isError
        ? const Color(0xE6C62828) // 错误保留红色，仅加透明度
        : cs.primary.withValues(alpha: 0.85); // 强调色半透明
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 76),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              constraints: const BoxConstraints(maxWidth: 420),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
  }
}