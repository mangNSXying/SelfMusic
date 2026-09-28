import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/harmonyos/secure_storage_ohos.dart'
    show createSecureStorage;
import 'app_theme.dart';

/// 主题状态：管理强调色/背景色/亮暗，运行时实时切换并持久化到 secure storage。
class ThemeProvider extends ChangeNotifier {
  static const _kAccent = 'theme_accent';
  static const _kBackground = 'theme_background';
  static const _kMode = 'theme_mode';

  final FlutterSecureStorage _storage;
  Brightness _mode = Brightness.light;
  Color _accent = AppTheme.defaultAccent;
  Color? _background;
  AppTheme? _cached;

  ThemeProvider({FlutterSecureStorage? storage, bool autoLoad = true})
      : _storage = storage ?? createSecureStorage() {
    if (autoLoad) load();
  }

  Brightness get mode => _mode;
  Color get accent => _accent;
  Color? get background => _background;
  bool get isDark => _mode == Brightness.dark;

  AppTheme get theme {
    final cached = _cached;
    if (cached != null &&
        cached.accentValue == _accent.toARGB32() &&
        cached.customBackground == (_background != null)) {
      return cached;
    }
    final t = AppTheme.build(accent: _accent, background: _background, brightness: _mode);
    _cached = t;
    return t;
  }

  ThemeData get themeData => theme.themeData;

  /// 启动时从 storage 读取主题设置。
  Future<void> load() async {
    try {
      final a = await _storage.read(key: _kAccent);
      final b = await _storage.read(key: _kBackground);
      final m = await _storage.read(key: _kMode);
      if (a != null) _accent = Color(int.parse(a));
      if (b != null) _background = Color(int.parse(b));
      if (m == 'dark') _mode = Brightness.dark;
      _cached = null;
      notifyListeners();
    } catch (e) {
      debugPrint('ThemeProvider.load failed: $e');
    }
  }

  Future<void> setAccent(Color color) async {
    if (color.toARGB32() == _accent.toARGB32()) return;
    _accent = color;
    _cached = null;
    notifyListeners();
    try {
      await _storage.write(key: _kAccent, value: color.toARGB32().toString());
    } catch (e) {
      debugPrint('persist accent failed: $e');
    }
  }

  Future<void> setBackground(Color color) async {
    _background = color;
    _cached = null;
    notifyListeners();
    try {
      await _storage.write(key: _kBackground, value: color.toARGB32().toString());
    } catch (e) {
      debugPrint('persist background failed: $e');
    }
  }

  /// 恢复基于强调色自动派生的背景（清除手动背景色）。
  Future<void> clearBackgroundOverride() async {
    _background = null;
    _cached = null;
    notifyListeners();
    try {
      await _storage.delete(key: _kBackground);
    } catch (e) {
      debugPrint('clear background failed: $e');
    }
  }

  Future<void> setMode(Brightness mode) async {
    if (mode == _mode) return;
    _mode = mode;
    _cached = null;
    notifyListeners();
    try {
      await _storage.write(key: _kMode, value: mode == Brightness.dark ? 'dark' : 'light');
    } catch (e) {
      debugPrint('persist mode failed: $e');
    }
  }

  Future<void> toggleMode() =>
      setMode(_mode == Brightness.dark ? Brightness.light : Brightness.dark);

  /// 恢复默认主题（teal 强调色 + 亮色 + 自动背景）。
  Future<void> resetDefaults() async {
    _accent = AppTheme.defaultAccent;
    _background = null;
    _mode = Brightness.light;
    _cached = null;
    notifyListeners();
    try {
      await _storage.delete(key: _kAccent);
      await _storage.delete(key: _kBackground);
      await _storage.delete(key: _kMode);
    } catch (e) {
      debugPrint('reset theme failed: $e');
    }
  }
}
