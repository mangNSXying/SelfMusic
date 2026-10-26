import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/theme/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, String> data;
  late ThemeProvider provider;

  setUp(() {
    data = <String, String>{};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(data);
    provider = ThemeProvider(storage: const FlutterSecureStorage());
  });

  group('默认与持久化', () {
    test('默认 mode 为跟随系统（system）', () {
      expect(provider.themeMode, ThemeMode.system);
      expect(provider.mode, ThemeMode.system);
    });

    test('setThemeMode 持久化为 system/light/dark', () async {
      await provider.setThemeMode(ThemeMode.dark);
      expect(data['theme_mode'], 'dark');

      await provider.setThemeMode(ThemeMode.light);
      expect(data['theme_mode'], 'light');

      await provider.setThemeMode(ThemeMode.system);
      expect(data['theme_mode'], 'system');
    });

    test('load 兼容旧值 light/dark，缺失时默认 system', () async {
      ThemeProvider fresh() =>
          ThemeProvider(storage: const FlutterSecureStorage());

      data['theme_mode'] = 'dark';
      final dark = fresh();
      await dark.load();
      expect(dark.themeMode, ThemeMode.dark);

      data['theme_mode'] = 'light';
      final light = fresh();
      await light.load();
      expect(light.themeMode, ThemeMode.light);

      data.clear();
      final unset = fresh();
      await unset.load();
      expect(unset.themeMode, ThemeMode.system);
    });
  });

  group('周期循环', () {
    test('cycleMode: system → light → dark → system', () async {
      await provider.cycleMode();
      expect(provider.themeMode, ThemeMode.light);
      await provider.cycleMode();
      expect(provider.themeMode, ThemeMode.dark);
      await provider.cycleMode();
      expect(provider.themeMode, ThemeMode.system);
    });
  });

  group('双主题与亮度', () {
    test('light/dark 各生成独立主题，brightness 正确', () async {
      await provider.setThemeMode(ThemeMode.light);
      expect(provider.themeData.brightness, Brightness.light);
      expect(provider.darkThemeData.brightness, Brightness.dark);
      expect(provider.themeData, isNot(same(provider.darkThemeData)));
    });

    test('isDark 在显式模式下跟随所选，不依赖平台亮度', () async {
      await provider.setThemeMode(ThemeMode.dark);
      expect(provider.isDark, isTrue);

      await provider.setThemeMode(ThemeMode.light);
      expect(provider.isDark, isFalse);
    });

    test('isDark 在 system 下跟随 platformBrightness', () async {
      await provider.setThemeMode(ThemeMode.system);
      final dispatcher = TestWidgetsFlutterBinding.instance.platformDispatcher
        ..platformBrightnessTestValue = Brightness.light;
      expect(provider.isDark, isFalse);

      dispatcher.platformBrightnessTestValue = Brightness.dark;
      expect(provider.isDark, isTrue);
    });

    test('强调色变化后缓存重建，双主题同步更新', () async {
      await provider.setThemeMode(ThemeMode.dark);
      final darkBefore = provider.darkThemeData;
      await provider.setAccent(const Color(0xFF7C4DFF));
      expect(provider.darkThemeData, isNot(same(darkBefore)));
      expect(provider.themeData.colorScheme.primary.toARGB32(),
          const Color(0xFF7C4DFF).toARGB32());
    });
  });

  group('字体', () {
    test('默认使用平台字体（fontFamily 为空）', () {
      expect(provider.fontFamily, isNull);
      expect(provider.themeData.textTheme.bodyMedium?.fontFamily,
          isNot('SelfMusicTestFont'));
    });

    test('setFontFamily 即时重建双主题并应用字体', () async {
      final lightBefore = provider.themeData;
      final darkBefore = provider.darkThemeData;
      await provider.setFontFamily('SelfMusicTestFont');

      expect(provider.fontFamily, 'SelfMusicTestFont');
      expect(provider.themeData, isNot(same(lightBefore)),
          reason: '字体变化必须让亮色主题缓存失效');
      expect(provider.darkThemeData, isNot(same(darkBefore)),
          reason: '字体变化必须让暗色主题缓存失效');
      expect(provider.themeData.textTheme.bodyMedium?.fontFamily,
          'SelfMusicTestFont');
      expect(provider.darkThemeData.textTheme.bodyMedium?.fontFamily,
          'SelfMusicTestFont');
    });

    test('initialFontFamily 构造即生效，切回 null 恢复默认', () async {
      final themed = ThemeProvider(
        storage: const FlutterSecureStorage(),
        autoLoad: false,
        initialFontFamily: 'SelfMusicTestFont',
      );
      expect(themed.themeData.textTheme.bodyMedium?.fontFamily,
          'SelfMusicTestFont');

      await themed.setFontFamily(null);
      expect(themed.fontFamily, isNull);
      expect(themed.themeData.textTheme.bodyMedium?.fontFamily,
          isNot('SelfMusicTestFont'));
    });
  });
}
