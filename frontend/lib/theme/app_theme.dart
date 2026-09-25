import 'package:flutter/material.dart';

/// 模块化主题核心：基于语义化颜色 token 生成 ThemeData。
///
/// - 默认浅色背景 `#FEFEFE` + teal 强调色 `#00A098`（对应参考图 UI 效果）。
/// - 支持运行时自定义背景色、强调色、亮暗模式，无需重建编译器即可实时生效。
class AppColorPalette {
  final Color background;
  final Color surface;
  final Color accent;
  final Color onAccent;
  final Color textPrimary;
  final Color textSecondary;
  final Color divider;

  const AppColorPalette({
    required this.background,
    required this.surface,
    required this.accent,
    required this.onAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.divider,
  });

  /// 从 seed 色派生完整的语义化配色。
  /// [background] 为空时由 seed 自动生成极浅的浅色背景（亮模式）。
  factory AppColorPalette.derive({
    required Color accent,
    Color? background,
    Brightness brightness = Brightness.light,
  }) {
    final hsl = HSLColor.fromColor(accent);
    final isLight = brightness == Brightness.light;

    final bg = background ??
        (isLight
            ? HSLColor.fromAHSL(1, hsl.hue, 0.30, 0.985).toColor()
            : HSLColor.fromAHSL(1, hsl.hue, 0.25, 0.08).toColor());

    final surface =
        isLight
            ? Color.alphaBlend(Color.alphaBlend(accent.withValues(alpha: 0.05), Colors.white), bg)
            : Color.alphaBlend(accent.withValues(alpha: 0.08), bg);

    final onAccent = isLight ? Colors.white : const Color(0xFF00190F);

    final textPrimary = isLight ? const Color(0xFF1A1C1B) : const Color(0xFFF2F5F4);
    final textSecondary = isLight ? const Color(0xFF6B7270) : const Color(0xFF9BA5A1);
    final divider = isLight ? const Color(0xFFE4E9E7) : const Color(0xFF2A3330);

    return AppColorPalette(
      background: bg,
      surface: surface,
      accent: accent,
      onAccent: onAccent,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      divider: divider,
    );
  }
}

/// 主导航 Section（顶栏下层导航）。
enum NavSection {
  playlists('歌单', Icons.queue_music),
  liked('喜欢', Icons.favorite),
  sources('播放源', Icons.storage),
  songs('歌曲', Icons.music_note),
  albums('专辑', Icons.album),
  artists('歌手', Icons.person);

  const NavSection(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 侧边栏设置分区条目。
enum SettingsItem {
  general('备份', Icons.backup_outlined),
  playback('播放', Icons.play_circle_outline),
  appearance('界面', Icons.palette_outlined),
  songs('歌曲', Icons.library_music_outlined),
  notifications('通知', Icons.notifications_outlined),
  server('服务端', Icons.dns_outlined);

  const SettingsItem(this.label, this.icon);
  final String label;
  final IconData icon;
}

class AppTheme {
  /// 默认强调色（teal，对应参考图）。
  static const Color defaultAccent = Color(0xFF00A098);

  /// 默认背景色（近白，对应参考图）。
  static const Color defaultBackground = Color(0xFFFEFEFE);

  /// 预置配色盘，供设置界面选择。
  static const List<Color> accentPalette = [
    Color(0xFF00A098), // teal（默认）
    Color(0xFF7C4DFF), // 紫
    Color(0xFF43A047), // 绿
    Color(0xFF1E88E5), // 蓝
    Color(0xFFFB8C00), // 橙
    Color(0xFFE91E63), // 粉
    Color(0xFF00838F), // 青
    Color(0xFF6D4C41), // 棕
  ];

  /// 语义化颜色 token（缓存，颜色变化时才重建）。
  final AppColorPalette palette;

  /// 生成的完整 Material ThemeData。
  final ThemeData themeData;

  /// 用于序列化到 storage 的强调色（十进制）。
  final int accentValue;

  /// 是否自动派生背景（未手动指定 background）。
  final bool customBackground;

  AppTheme._({
    required this.palette,
    required this.themeData,
    required this.accentValue,
    required this.customBackground,
  });

  /// 构建完整主题。
  factory AppTheme.build({
    Color accent = defaultAccent,
    Color? background,
    Brightness brightness = Brightness.light,
  }) {
    final pal = AppColorPalette.derive(
      accent: accent,
      background: background,
      brightness: brightness,
    );

    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      primary: pal.accent,
      onPrimary: pal.onAccent,
      surface: pal.surface,
      onSurface: pal.textPrimary,
    );

    final theme = ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      brightness: brightness,
      scaffoldBackgroundColor: pal.background,
      appBarTheme: AppBarTheme(
        backgroundColor: pal.surface,
        foregroundColor: pal.textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(color: pal.divider, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: pal.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: pal.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: pal.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: pal.accent, width: 1.5),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: pal.surface,
        indicatorColor: pal.accent.withValues(alpha: 0.15),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: pal.textSecondary,
        textColor: pal.textPrimary,
      ),
    );

    return AppTheme._(
      palette: pal,
      themeData: theme,
      accentValue: accent.toARGB32(),
      customBackground: background != null,
    );
  }
}
