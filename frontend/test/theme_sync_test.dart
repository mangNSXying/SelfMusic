import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/theme/app_theme.dart';
import 'package:selfmusic/theme/theme_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('主题本地变更回调；远端应用抑制回声并校验非法值', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final provider = ThemeProvider(autoLoad: false);
    final events = <String>[];
    provider.onSettingChanged = (key, value) => events.add('$key=$value');

    // 未显式设置过的默认值不参与补种。
    expect(await provider.syncValue(ThemeProvider.syncKeyMode), isNull);
    expect(await provider.syncValue(ThemeProvider.syncKeyAccent), isNull);
    expect(await provider.syncValue(ThemeProvider.syncKeyBackground), isNull);

    const accent = Color(0xFF123456);
    const background = Color(0xFF101010);
    await provider.setThemeMode(ThemeMode.dark);
    await provider.setAccent(accent);
    await provider.setBackground(background);
    expect(events, [
      'theme_mode=dark',
      'theme_accent=${accent.toARGB32()}',
      'theme_background=${background.toARGB32()}',
    ]);

    expect(await provider.syncValue(ThemeProvider.syncKeyMode), 'dark');
    expect(await provider.syncValue(ThemeProvider.syncKeyAccent),
        accent.toARGB32().toString());
    expect(await provider.syncValue(ThemeProvider.syncKeyBackground),
        background.toARGB32().toString());

    events.clear();
    expect(
        await provider.applyRemoteSyncValue(ThemeProvider.syncKeyMode, 'light'),
        isTrue);
    expect(provider.themeMode, ThemeMode.light);
    expect(
        await provider.applyRemoteSyncValue(
            ThemeProvider.syncKeyBackground, ''),
        isTrue);
    expect(provider.background, isNull);
    expect(
        await provider.applyRemoteSyncValue(ThemeProvider.syncKeyAccent, '-1'),
        isFalse);
    expect(
        await provider.applyRemoteSyncValue(ThemeProvider.syncKeyMode, 'bogus'),
        isFalse);
    expect(events, isEmpty, reason: '远端应用不得回推');

    await provider.resetDefaults();
    expect(events, [
      'theme_accent=${AppTheme.defaultAccent.toARGB32()}',
      'theme_background=',
      'theme_mode=system',
    ]);
    expect(await provider.syncValue(ThemeProvider.syncKeyBackground), '');
  });
}
