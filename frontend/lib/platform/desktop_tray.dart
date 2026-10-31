import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_background.dart';

/// 桌面端（Windows/Linux）系统托盘驻留。
///
/// 关闭主窗口时默认隐藏窗口、进程继续运行（播放不中断），托盘菜单可恢复
/// 窗口或真正退出。托盘初始化失败（如 Linux 桌面没有 StatusNotifier 宿主）
/// 时保持「关闭即退出」：否则窗口藏起来后用户没有任何入口找回。
class DesktopTray with TrayListener, WindowListener {
  DesktopTray._();

  static final DesktopTray instance = DesktopTray._();

  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  bool _windowReady = false;
  bool _trayReady = false;
  bool _closeToTray = true;
  bool _quitting = false;
  Future<void> Function()? _beforeQuit;

  /// 托盘图标是否已成功创建；设置页据此提示当前环境是否真的能驻留。
  bool get trayReady => _trayReady;

  /// 退出前的收口（停播放器/落库）；真正退进程由本类统一执行。
  void setBeforeQuit(Future<void> Function() handler) {
    _beforeQuit = handler;
  }

  /// 尽早调用：拦截原生关闭事件。窗口相关插件须在 runApp 前初始化。
  Future<void> initWindow() async {
    if (!isSupported || _windowReady) return;
    try {
      await windowManager.ensureInitialized();
      // 恒拦截关闭：驻留时改为隐藏；未驻留时也要先停播放器再退进程，
      // 避免 media_kit 的 mpv 子进程被连带粗暴终止。
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
      _windowReady = true;
    } catch (e) {
      debugPrint('窗口管理初始化失败，关闭窗口仍直接退出：$e');
    }
  }

  /// 创建托盘图标与菜单；[closeToTray] 为设置项当前值。
  Future<void> initTray({required bool closeToTray}) async {
    _closeToTray = closeToTray;
    if (!isSupported || !_windowReady || _trayReady) return;
    try {
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
      );
      // Linux 的 0.5.x 实现没有 tooltip 方法（返回 not implemented），失败可忽略。
      try {
        await trayManager.setToolTip('SelfMusic');
      } catch (_) {}
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示主窗口'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
      trayManager.addListener(this);
      _trayReady = true;
    } catch (e) {
      debugPrint('托盘初始化失败，关闭窗口将直接退出：$e');
      // 菜单没建起来的图标点不出任何入口，直接移除，避免留下一个死图标。
      try {
        await trayManager.destroy();
      } catch (_) {}
    }
  }

  /// 设置页切换「关闭时驻留托盘」。
  void setCloseToTray(bool value) {
    _closeToTray = value;
  }

  Future<void> showWindow() async {
    if (!isSupported || !_windowReady) return;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('显示主窗口失败：$e');
    }
  }

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      await _beforeQuit?.call();
    } catch (e) {
      // 收口异常不许拦住退出。
      debugPrint('退出前收口失败：$e');
    }
    await exitAppGracefully();
  }

  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  Future<void> _handleWindowClose() async {
    if (_closeToTray && _trayReady) {
      try {
        await _hideWindow();
        return;
      } catch (e) {
        debugPrint('隐藏窗口失败，改为退出：$e');
      }
    }
    await _quit();
  }

  /// Windows 的 ShowWindow(SW_HIDE) 不会把前台让给其它窗口：隐藏后本进程仍
  /// 持有前台（隐藏窗口），其它应用窗口点不亮、键盘焦点也回不来。先把前台
  /// 显式交给 Z 序下一个可见窗口，再隐藏。Linux 的 WM 会自行处理，无需此步。
  Future<void> _hideWindow() async {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      try {
        await windowManager.blur();
      } catch (e) {
        debugPrint('释放窗口焦点失败：$e');
      }
    }
    await windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(showWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // Linux 的 AppIndicator 由面板直接弹菜单，不会派发这些事件。
    if (Platform.isWindows) {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'quit':
        unawaited(_quit());
    }
  }
}
