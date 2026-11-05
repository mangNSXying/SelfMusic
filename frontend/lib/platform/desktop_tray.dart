import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'app_background.dart';

/// 桌面端（Windows/Linux）系统托盘驻留。
///
/// 关闭主窗口时默认隐藏窗口、进程继续运行（播放不中断），托盘菜单可恢复
/// 窗口、控制播放、添加歌曲、打开设置或真正退出。托盘初始化失败（如 Linux
/// 桌面没有 StatusNotifier 宿主）时保持「关闭即退出」：否则窗口藏起来后
/// 用户没有任何入口找回。
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

  /// 播放控制与窗口级菜单动作由 UI 层（main.dart 的 Root）注入。
  /// 托盘本身不依赖各 Provider，避免平台层反向依赖业务层。
  Future<void> Function()? _onTogglePlayback;
  Future<void> Function()? _onPrevious;
  Future<void> Function()? _onNext;
  Future<void> Function()? _onAddSongs;
  Future<void> Function()? _onOpenSettings;

  bool _hasCurrent = false;
  bool _playing = false;
  String _currentTitle = '';
  String _currentArtist = '';

  /// 菜单写入串行化：播放状态可能在一次装载里连续通知多次，确保最终落地的
  /// 是最后一次快照；[_menuVersion] 用于丢弃排队中的过期快照。
  Future<void> _menuWrite = Future<void>.value();
  int _menuVersion = 0;
  int _appliedMenuVersion = 0;

  /// 托盘图标是否已成功创建；设置页据此提示当前环境是否真的能驻留。
  bool get trayReady => _trayReady;

  /// 退出前的收口（停播放器/落库）；真正退进程由本类统一执行。
  void setBeforeQuit(Future<void> Function() handler) {
    _beforeQuit = handler;
  }

  /// 绑定托盘里的播放控制。回调由 UI 层转发到 PlayerProvider。
  void bindPlaybackActions({
    required Future<void> Function() onToggle,
    required Future<void> Function() onPrevious,
    required Future<void> Function() onNext,
  }) {
    _onTogglePlayback = onToggle;
    _onPrevious = onPrevious;
    _onNext = onNext;
  }

  /// 绑定需要先恢复主窗口再执行的菜单动作（添加歌曲 / 打开设置）。
  void bindWindowActions({
    required Future<void> Function() onAddSongs,
    required Future<void> Function() onOpenSettings,
  }) {
    _onAddSongs = onAddSongs;
    _onOpenSettings = onOpenSettings;
  }

  /// 清理 UI 层注入的回调（根组件销毁时调用）。
  void clearActions() {
    _onTogglePlayback = null;
    _onPrevious = null;
    _onNext = null;
    _onAddSongs = null;
    _onOpenSettings = null;
  }

  /// 同步当前播放状态，供菜单显示曲名与播放/暂停文案、决定控制项是否可用。
  ///
  /// 返回的 Future 在本次菜单写入完成后结束；调用方通常无需等待。
  Future<void> updatePlaybackState({
    required bool hasCurrent,
    required bool playing,
    String? title,
    String? artist,
  }) {
    final nextTitle = hasCurrent ? (title ?? '').trim() : '';
    final nextArtist = hasCurrent ? (artist ?? '').trim() : '';
    if (nextTitle == _currentTitle &&
        nextArtist == _currentArtist &&
        hasCurrent == _hasCurrent &&
        playing == _playing) {
      return _menuWrite;
    }
    _hasCurrent = hasCurrent;
    _playing = playing;
    _currentTitle = nextTitle;
    _currentArtist = nextArtist;
    _queueMenuUpdate();
    return _menuWrite;
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
      final version = _menuVersion;
      final menu = _buildMenu();
      await trayManager.setContextMenu(menu);
      _appliedMenuVersion = version;
      trayManager.addListener(this);
      _trayReady = true;
      // 初始化期间若已有播放状态更新排队（正常启动不会发生），这里补写一次，
      // 避免因当时 _trayReady 还是 false 而丢掉最新快照。
      if (_menuVersion > _appliedMenuVersion) _queueMenuUpdate();
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
      // 用户可能用的是「最小化」而不是关闭到托盘：先还原再显示，否则
      // show()/focus() 对最小化窗口不生效（任务栏窗口仍是最小化状态）。
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
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
      unawaited(_popUpMenu());
    }
  }

  /// Windows 右键时先等排队中的状态更新落地，避免弹出一份旧菜单。
  Future<void> _popUpMenu() async {
    await _menuWrite;
    try {
      await trayManager.popUpContextMenu();
    } catch (e) {
      debugPrint('弹出托盘菜单失败：$e');
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showWindow());
      case 'togglePlayback':
        _runPlaybackAction(_onTogglePlayback);
      case 'previous':
        _runPlaybackAction(_onPrevious);
      case 'next':
        _runPlaybackAction(_onNext);
      case 'addSongs':
        unawaited(_runWindowAction(_onAddSongs));
      case 'settings':
        unawaited(_runWindowAction(_onOpenSettings));
      case 'quit':
        unawaited(_quit());
    }
  }

  void _runPlaybackAction(Future<void> Function()? action) {
    if (action == null) return;
    // 播放控制不弹出主窗口：托盘右键随手暂停/切歌是桌面端的主要用途。
    unawaited(Future<void>.sync(action).catchError((Object e) {
      debugPrint('托盘播放控制失败：$e');
    }));
  }

  Future<void> _runWindowAction(Future<void> Function()? action) async {
    if (action == null) return;
    await showWindow();
    try {
      await action();
    } catch (e) {
      debugPrint('托盘菜单动作失败：$e');
    }
  }

  /// 把当前播放状态写进菜单；[version] 过期的排队任务直接丢弃。
  void _queueMenuUpdate() {
    final version = ++_menuVersion;
    final menu = _buildMenu();
    _menuWrite = _menuWrite.then((_) async {
      if (!_trayReady || version <= _appliedMenuVersion) return;
      await trayManager.setContextMenu(menu);
      _appliedMenuVersion = version;
    }).catchError((Object e) {
      debugPrint('更新托盘菜单失败：$e');
    });
  }

  Menu _buildMenu() {
    final hasCurrent = _hasCurrent;
    return Menu(items: [
      MenuItem(
        key: 'nowPlaying',
        label: _nowPlayingLabel(),
        disabled: true,
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'togglePlayback',
        label: hasCurrent && _playing ? '暂停' : '播放',
        disabled: !hasCurrent,
      ),
      MenuItem(key: 'previous', label: '上一首', disabled: !hasCurrent),
      MenuItem(key: 'next', label: '下一首', disabled: !hasCurrent),
      MenuItem.separator(),
      MenuItem(key: 'addSongs', label: '添加歌曲…'),
      MenuItem(key: 'show', label: '显示主窗口'),
      MenuItem(key: 'settings', label: '打开设置'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]);
  }

  String _nowPlayingLabel() {
    if (!_hasCurrent) return '未在播放';
    if (_currentTitle.isEmpty) return '正在播放';
    final artist = _currentArtist.isEmpty ? '' : ' - $_currentArtist';
    var text = '正在播放：$_currentTitle$artist';
    if (text.runes.length > 64) {
      text = '${String.fromCharCodes(text.runes.take(63))}…';
    }
    return _menuLabel(text);
  }

  /// Windows 原生菜单把 `&` 当助记符（`Rock & Roll` 会显示成 `Rock _Roll`）；
  /// 其余平台不动。换行/制表符统一压成空格，避免菜单项被截断。
  String _menuLabel(String label) {
    final cleaned = label.replaceAll(RegExp(r'[\r\n\t]+'), ' ').trim();
    return Platform.isWindows ? cleaned.replaceAll('&', '&&') : cleaned;
  }
}
