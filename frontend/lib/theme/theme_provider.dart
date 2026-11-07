import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../platform/harmonyos/secure_storage_ohos.dart'
    show createSecureStorage;
import 'app_theme.dart';

/// 主题状态：管理强调色/背景色/明暗模式，运行时实时切换并持久化到 secure storage。
///
/// 明暗为三态 [ThemeMode]：`system`（跟随手机/电脑系统亮度，默认）、`light`、`dark`。
/// `MaterialApp` 需同时提供 `theme` 与 `darkTheme` 并在 `themeMode` 上读取本类，
/// 系统亮度变化时由 Flutter 自动切换并重建主题相关依赖。
class ThemeProvider extends ChangeNotifier {
  static const String syncKeyAccent = 'theme_accent';
  static const String syncKeyBackground = 'theme_background';
  static const String syncKeyMode = 'theme_mode';
  static const _kAccent = syncKeyAccent;
  static const _kBackground = syncKeyBackground;
  static const _kMode = syncKeyMode;

  /// 本地主题变更回调（SyncEngine 注入；远端应用时抑制）。
  void Function(String key, String value)? onSettingChanged;
  bool _suppressSync = false;

  final FlutterSecureStorage _storage;
  ThemeMode _mode = ThemeMode.system;
  Color _accent = AppTheme.defaultAccent;
  Color? _background;
  bool _modeSet = false;
  bool _accentSet = false;
  bool _backgroundSet = false;
  String? _fontFamily;
  AppTheme? _cachedLight;
  AppTheme? _cachedDark;

  ThemeProvider({
    FlutterSecureStorage? storage,
    bool autoLoad = true,
    String? initialFontFamily,
  })  : _storage = storage ?? createSecureStorage(),
        _fontFamily = initialFontFamily {
    if (autoLoad) load();
  }

  ThemeMode get mode => _mode;
  ThemeMode get themeMode => _mode;
  Color get accent => _accent;
  Color? get background => _background;

  /// 当前自定义字体家族（null=平台默认）。
  /// 字体选择由 CustomFontService 持久化，本类只负责即时应用到主题。
  String? get fontFamily => _fontFamily;

  /// 有效亮度：`system` 时按平台当前亮度，其余按选定模式。
  bool get isDark => _mode == ThemeMode.system
      ? WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark
      : _mode == ThemeMode.dark;

  AppTheme _build(Brightness b) {
    final cached = b == Brightness.light ? _cachedLight : _cachedDark;
    if (cached != null &&
        cached.accentValue == _accent.toARGB32() &&
        cached.customBackground == (_background != null) &&
        cached.fontFamily == _fontFamily) {
      return cached;
    }
    final t = AppTheme.build(
      accent: _accent,
      background: _background,
      brightness: b,
      fontFamily: _fontFamily,
    );
    if (b == Brightness.light) {
      _cachedLight = t;
    } else {
      _cachedDark = t;
    }
    return t;
  }

  AppTheme get lightTheme => _build(Brightness.light);
  AppTheme get darkTheme => _build(Brightness.dark);
  ThemeData get themeData => lightTheme.themeData;
  ThemeData get darkThemeData => darkTheme.themeData;

  /// 启动时从 storage 读取主题设置；旧值 `dark/light` 兼容，缺失默认跟随系统。
  /// 同一时刻只允许一次加载，后续写入会先等待其完成，避免异步加载覆盖用户刚做的修改。
  Future<void>? _loading;
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final a = await _storage.read(key: _kAccent);
      final b = await _storage.read(key: _kBackground);
      final m = await _storage.read(key: _kMode);
      _accentSet = a != null;
      _backgroundSet = b != null;
      _modeSet = m != null;
      if (a != null) _accent = Color(int.parse(a));
      if (b != null) _background = Color(int.parse(b));
      switch (m) {
        case 'dark':
          _mode = ThemeMode.dark;
        case 'light':
          _mode = ThemeMode.light;
        default:
          _mode = ThemeMode.system;
      }
      _cachedLight = null;
      _cachedDark = null;
      notifyListeners();
    } catch (e) {
      debugPrint('ThemeProvider.load failed: $e');
    }
  }

  Future<void> setAccent(Color color) async {
    await _loading;
    if (color.toARGB32() == _accent.toARGB32()) return;
    _accent = color;
    _accentSet = true;
    _cachedLight = null;
    _cachedDark = null;
    notifyListeners();
    _emit(syncKeyAccent, color.toARGB32().toString());
    try {
      await _storage.write(key: _kAccent, value: color.toARGB32().toString());
    } catch (e) {
      debugPrint('persist accent failed: $e');
    }
  }

  Future<void> setBackground(Color color) async {
    await _loading;
    final value = color.toARGB32();
    if (_background?.toARGB32() == value) return;
    _background = color;
    _backgroundSet = true;
    _cachedLight = null;
    _cachedDark = null;
    notifyListeners();
    _emit(syncKeyBackground, value.toString());
    try {
      await _storage.write(key: _kBackground, value: value.toString());
    } catch (e) {
      debugPrint('persist background failed: $e');
    }
  }

  /// 恢复基于强调色自动派生的背景（清除手动背景色）。
  Future<void> clearBackgroundOverride() async {
    await _loading;
    if (_background == null) return;
    _background = null;
    _backgroundSet = true;
    _cachedLight = null;
    _cachedDark = null;
    notifyListeners();
    _emit(syncKeyBackground, '');
    try {
      await _storage.delete(key: _kBackground);
    } catch (e) {
      debugPrint('clear background failed: $e');
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _loading;
    if (mode == _mode) return;
    _mode = mode;
    _modeSet = true;
    notifyListeners();
    _emit(syncKeyMode, mode.name);
    try {
      await _storage.write(key: _kMode, value: mode.name);
    } catch (e) {
      debugPrint('persist mode failed: $e');
    }
  }

  void _emit(String key, String value) {
    if (!_suppressSync) onSettingChanged?.call(key, value);
  }

  /// 设置同步：读取当前主题的协议值（背景自动=`''`）。
  /// 未显式设置过的键返回 null——默认值不参与补种，避免新设备覆盖云端。
  Future<String?> syncValue(String key) async {
    await load();
    switch (key) {
      case syncKeyMode:
        return _modeSet ? _mode.name : null;
      case syncKeyAccent:
        return _accentSet ? _accent.toARGB32().toString() : null;
      case syncKeyBackground:
        if (!_backgroundSet) return null;
        return _background?.toARGB32().toString() ?? '';
      default:
        return null;
    }
  }

  /// 设置同步：应用远端主题值；非法值忽略，写入时不回推。
  Future<bool> applyRemoteSyncValue(String key, String value) async {
    await load();
    _suppressSync = true;
    try {
      switch (key) {
        case syncKeyMode:
          ThemeMode? mode;
          for (final m in ThemeMode.values) {
            if (m.name == value) {
              mode = m;
              break;
            }
          }
          if (mode == null || mode == _mode) return false;
          await setThemeMode(mode);
          return true;
        case syncKeyAccent:
          final color = _parseColor(value);
          if (color == null || color.toARGB32() == _accent.toARGB32()) {
            return false;
          }
          await setAccent(color);
          return true;
        case syncKeyBackground:
          if (value.isEmpty) {
            if (_background == null) return false;
            await clearBackgroundOverride();
            return true;
          }
          final color = _parseColor(value);
          if (color == null || _background?.toARGB32() == color.toARGB32()) {
            return false;
          }
          await setBackground(color);
          return true;
        default:
          return false;
      }
    } finally {
      _suppressSync = false;
    }
  }

  static Color? _parseColor(String value) {
    final v = int.tryParse(value);
    if (v == null || v < 0 || v > 0xFFFFFFFF) return null;
    return Color(v);
  }

  /// 即时切换界面字体（null=平台默认）。字体文件与持久化由 CustomFontService
  /// 管理，这里只负责让 MaterialApp 用新字体重建主题。
  Future<void> setFontFamily(String? family) async {
    await _loading;
    if (family == _fontFamily) return;
    _fontFamily = family;
    _cachedLight = null;
    _cachedDark = null;
    notifyListeners();
  }

  /// 钉死到指定明暗（仅 light/dark；跟随系统请走 [setThemeMode]）。
  Future<void> setMode(Brightness brightness) => setThemeMode(
      brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light);

  /// 三态循环：system → light → dark → system（侧栏快捷按钮）。
  Future<void> cycleMode() {
    final next = switch (_mode) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    return setThemeMode(next);
  }

  /// 恢复默认主题（teal 强调色 + 跟随系统 + 自动背景）。
  Future<void> resetDefaults() async {
    await _loading;
    _accent = AppTheme.defaultAccent;
    _background = null;
    _mode = ThemeMode.system;
    _accentSet = true;
    _backgroundSet = true;
    _modeSet = true;
    _cachedLight = null;
    _cachedDark = null;
    notifyListeners();
    // 恢复默认是显式意图：三键都推，覆盖云端旧的自定义值。
    _emit(syncKeyAccent, _accent.toARGB32().toString());
    _emit(syncKeyBackground, '');
    _emit(syncKeyMode, _mode.name);
    try {
      await _storage.delete(key: _kAccent);
      await _storage.delete(key: _kBackground);
      await _storage.delete(key: _kMode);
    } catch (e) {
      debugPrint('reset theme failed: $e');
    }
  }
}
