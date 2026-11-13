import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../data/local/app_settings.dart';

/// 桌面端（Windows/Linux）主窗口几何状态记忆。
///
/// 冷启动按上次记录恢复尺寸/位置与最大化状态；没有记录（首次启动，或历史
/// 数据不可用）时居中显示，避免原生默认落点固定在左上角。拖动/缩放期间窗口
/// 事件密集，写入按 [saveDelay] 合并；最终以 [flush] 收口。
class DesktopWindowState with WindowListener {
  DesktopWindowState();

  static final DesktopWindowState instance = DesktopWindowState();

  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux);

  /// 可恢复的最小尺寸：更小的历史值视为异常数据，回退「居中 + 默认尺寸」。
  static const Size minRestoreSize = Size(640, 400);

  /// 拖动/缩放停下来多久后写一次库（避免每帧事件都写）。
  static const Duration saveDelay = Duration(milliseconds: 400);

  AppSettings? _settings;
  Timer? _saveTimer;
  bool _restoring = false;
  bool _attached = false;

  /// Windows 上待首帧后执行的最大化（原因见 [restore]）。
  bool _deferredMaximize = false;

  /// 在窗口首次显示前调用（runApp 之前）：恢复上次的尺寸与位置。
  ///
  /// 首次启动或记录不可用时居中。最大化有意分平台处理：Linux 的 GTK 只是
  /// 记录状态、窗口映射时直接以最大化出现，首帧前设置无闪烁；Windows 的
  /// SC_MAXIMIZE 会立刻显示尚未渲染的窗口（启动期黑屏），且原生 runner 首帧
  /// 时用 `SW_SHOWNORMAL` 会把最大化复位——故记下待办，由首帧后调用
  /// [applyDeferredMaximize]。
  Future<void> restore(AppSettings settings) async {
    if (!isSupported) return;
    _settings = settings;
    _restoring = true;
    try {
      final saved = decodeBounds(settings.windowBounds);
      if (saved != null) {
        await windowManager.setBounds(await _fitOnScreen(saved));
      } else {
        await windowManager.center();
      }
      if (settings.windowMaximized) {
        if (Platform.isWindows) {
          _deferredMaximize = true;
        } else {
          await windowManager.maximize();
        }
      }
    } catch (e) {
      debugPrint('恢复窗口状态失败：$e');
    } finally {
      _restoring = false;
    }
    if (!_attached) {
      windowManager.addListener(this);
      _attached = true;
    }
  }

  /// 首帧后调用：执行 Windows 推迟的「恢复最大化」。
  Future<void> applyDeferredMaximize() async {
    if (!_deferredMaximize) return;
    _deferredMaximize = false;
    try {
      await windowManager.maximize();
    } catch (e) {
      debugPrint('恢复窗口最大化失败：$e');
    }
  }

  /// 退出前调用：把防抖窗口内还没落盘的几何状态写掉。
  Future<void> flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    await _persist();
  }

  /// 停止监听窗口事件（测试/会话收尾用；桌面端正常生命周期内不调用）。
  void detach() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_attached) {
      windowManager.removeListener(this);
      _attached = false;
    }
  }

  @override
  void onWindowResize() => _scheduleSave();

  @override
  void onWindowResized() => _scheduleSave();

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowMoved() => _scheduleSave();

  @override
  void onWindowMaximize() => _scheduleSave();

  @override
  void onWindowUnmaximize() => _scheduleSave();

  @override
  void onWindowRestore() => _scheduleSave();

  void _scheduleSave() {
    if (_settings == null || _restoring) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(saveDelay, () {
      _saveTimer = null;
      unawaited(_persist());
    });
  }

  Future<void> _persist() async {
    final settings = _settings;
    if (settings == null || _restoring) return;
    try {
      // 最小化时窗口几何是屏外占位坐标（如 Windows 的 -32000），不能记。
      if (await windowManager.isMinimized()) return;
      final maximized = await windowManager.isMaximized();
      settings.windowMaximized = maximized;
      // 最大化时 getBounds 是整屏尺寸：保留普通状态下的几何，否则取消最大化
      // 会得到一个「满屏大小」的普通窗口。
      if (maximized) return;
      final bounds = await windowManager.getBounds();
      if (bounds.width < minRestoreSize.width ||
          bounds.height < minRestoreSize.height) {
        return;
      }
      settings.windowBounds = encodeBounds(bounds);
    } catch (e) {
      debugPrint('保存窗口状态失败：$e');
    }
  }

  /// 把历史几何钳制到当前屏幕可视区域：显示器拔掉、分辨率变小后，直接按
  /// 原坐标恢复会得到落在屏外、用户看不到也点不到的窗口。
  Future<Rect> _fitOnScreen(Rect saved) async {
    List<Display> displays;
    try {
      displays = await screenRetriever.getAllDisplays();
    } catch (e) {
      debugPrint('读取显示器信息失败，按原样恢复窗口位置：$e');
      return saved;
    }
    if (displays.isEmpty) return saved;
    Rect? target;
    var bestArea = 0.0;
    for (final display in displays) {
      final visible = _visibleRect(display);
      if (!visible.overlaps(saved)) continue;
      final overlap = saved.intersect(visible);
      final area = overlap.width * overlap.height;
      if (area > bestArea) {
        bestArea = area;
        target = visible;
      }
    }
    if (target == null) {
      try {
        target = _visibleRect(await screenRetriever.getPrimaryDisplay());
      } catch (_) {
        return saved;
      }
    }
    final width = math.min(saved.width, target.width);
    final height = math.min(saved.height, target.height);
    final left = saved.left.clamp(target.left, target.right - width);
    final top = saved.top.clamp(target.top, target.bottom - height);
    return Rect.fromLTWH(left, top, width, height);
  }

  static Rect _visibleRect(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }

  /// 窗口几何编码为 JSON `[x, y, width, height]`（逻辑像素）。
  static String encodeBounds(Rect bounds) => jsonEncode(<double>[
        bounds.left,
        bounds.top,
        bounds.width,
        bounds.height,
      ]);

  /// 解码 [encodeBounds] 写入的记录；损坏或过小的几何返回 null（走居中）。
  static Rect? decodeBounds(String raw) {
    if (raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw) as List;
      if (list.length != 4) return null;
      final values = [for (final v in list) (v as num).toDouble()];
      final bounds = Rect.fromLTWH(values[0], values[1], values[2], values[3]);
      if (bounds.width < minRestoreSize.width ||
          bounds.height < minRestoreSize.height) {
        return null;
      }
      return bounds;
    } catch (_) {
      return null;
    }
  }
}
