import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// 普通提示默认停留时长。
  static const int _defaultMs = 2800;

  /// 错误提示默认停留时长：留足阅读与点击复制的时间。
  static const int _errorMs = 6000;

  static OverlayEntry? _current;
  static Timer? _timer;

  static void show(String message, {bool isError = true, int? ms}) {
    final nav = appNavigatorKey.currentState;
    final overlay = nav?.overlay;
    if (overlay == null) {
      debugPrint('[toast]${isError ? ' ERROR' : ''} $message');
      return;
    }
    // 仅保留最新一条：先摘掉旧 toast，避免浮层堆积。
    _dismiss();
    final entry = OverlayEntry(
      opaque: false,
      builder: (_) => _ToastBubble(
        message: message,
        isError: isError,
        onTap: isError ? () => _copyAndNotify(message) : null,
      ),
    );
    _current = entry;
    overlay.insert(entry);
    _timer = Timer(
      Duration(milliseconds: ms ?? (isError ? _errorMs : _defaultMs)),
      () {
        if (_current == entry) _current = null;
        _timer = null;
        // 不能用 `entry.mounted` 当摘除前提：它取决于该条目**是否已被构建**
        // （_OverlayEntryWidgetState 挂载）。弹入后到计时到期之间没有产出帧
        // 时（启动期同步/DB isolate 往返、后台重入等无帧区间），条目尚未构建 →
        // mounted=false → 跳过 remove，条目永久滞留 _entries，等下一帧才渲染
        // 出来且计时器已消费，表现为「同步完成」等 toast 不再消失。
        // 故无条件摘除；已移除/overlay 已销毁的边界由 try/catch 兜底。
        try {
          entry.remove();
        } catch (_) {
          // 已被移除或 Overlay 已销毁：无需再摘。
        }
      },
    );
  }

  /// 立即摘掉当前 toast 并取消计时。
  static void _dismiss() {
    _timer?.cancel();
    _timer = null;
    final entry = _current;
    _current = null;
    if (entry == null) return;
    try {
      entry.remove();
    } catch (_) {
      // 已被移除或 Overlay 已销毁：无需再摘。
    }
  }

  /// 点击错误 toast：关闭当前弹窗并复制错误信息，再提示复制结果。
  static Future<void> _copyAndNotify(String message) async {
    _dismiss();
    try {
      await Clipboard.setData(ClipboardData(text: message));
    } catch (_) {
      show('复制失败', isError: false);
      return;
    }
    show('错误信息已复制', isError: false);
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

/// 扁平浮条本体：强调色半透明圆角、文字居中；普通 toast 外层 IgnorePointer
/// 保证点击直接穿透到被遮挡控件，错误 toast 则仅气泡本体可点（点击复制）。
class _ToastBubble extends StatelessWidget {
  const _ToastBubble({
    required this.message,
    required this.isError,
    this.onTap,
  });

  final String message;
  final bool isError;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg = isError
        ? const Color(0xE6C62828) // 错误保留红色，仅加透明度
        : cs.primary.withValues(alpha: 0.85); // 强调色半透明
    Widget bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          if (onTap != null)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '点击复制',
                style: TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ),
        ],
      ),
    );
    if (onTap != null) {
      bubble = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: bubble,
      );
    }
    final body = Material(
      type: MaterialType.transparency,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 76),
          child: bubble,
        ),
      ),
    );
    return onTap == null ? IgnorePointer(child: body) : body;
  }
}
