import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/shortcuts/shortcut_models.dart';
import 'package:selfmusic/shortcuts/shortcut_settings.dart';

void main() {
  group('默认绑定', () {
    test('窗口默认值符合约定', () {
      final window = defaultWindowBindings(primaryIsMeta: false);
      expect(window[ShortcutAction.playPause]!.describe(), 'Space');
      expect(window[ShortcutAction.previous]!.describe(), 'Ctrl + ←');
      expect(window[ShortcutAction.next]!.describe(), 'Ctrl + →');
      expect(window[ShortcutAction.seekBackward5]!.describe(), '←');
      expect(window[ShortcutAction.seekForward30]!.describe(), 'Shift + →');
      expect(window[ShortcutAction.search]!.describe(), 'Ctrl + F');
      expect(window[ShortcutAction.sectionArtists]!.describe(), 'Ctrl + 6');
      expect(window[ShortcutAction.openSettings]!.describe(), 'Ctrl + ,');
      expect(window[ShortcutAction.cycleTheme]!.describe(), 'Ctrl + Shift + T');
      expect(window[ShortcutAction.quit]!.describe(), 'Ctrl + Q');
      expect(window[ShortcutAction.help]!.describe(), 'F1');
      expect(window[ShortcutAction.removeFromQueue]!.describe(), 'Delete');
    });

    test('macOS 使用 Command', () {
      final window = defaultWindowBindings(primaryIsMeta: true);
      expect(window[ShortcutAction.previous]!.describe(isMac: true), '⌘ + ←');
      expect(window[ShortcutAction.search]!.describe(isMac: true), '⌘ + F');
    });

    test('全局默认只包含四个播放控制动作', () {
      final global = defaultGlobalBindings(primaryIsMeta: false);
      expect(global.keys.toSet(),
          ShortcutAction.values.where((e) => e.supportsGlobal).toSet());
      expect(
          global[ShortcutAction.playPause]!.describe(), 'Ctrl + Alt + Space');
      expect(global[ShortcutAction.previous]!.describe(), 'Ctrl + Alt + ←');
      expect(global[ShortcutAction.next]!.describe(), 'Ctrl + Alt + →');
      expect(
          global[ShortcutAction.toggleFavorite]!.describe(), 'Ctrl + Alt + L');
    });

    test('默认窗口与全局绑定互不冲突', () {
      final window = defaultWindowBindings(primaryIsMeta: false);
      final global = defaultGlobalBindings(primaryIsMeta: false);
      for (final action in window.keys) {
        expect(
          ShortcutSettings.findConflict(
            action: action,
            scope: ShortcutScope.window,
            binding: window[action],
            window: window,
            global: global,
          ),
          isNull,
        );
      }
      for (final action in global.keys) {
        expect(
          ShortcutSettings.findConflict(
            action: action,
            scope: ShortcutScope.global,
            binding: global[action],
            window: window,
            global: global,
          ),
          isNull,
        );
      }
    });
  });

  group('冲突校验', () {
    test('同组重复组合被拒绝', () {
      final window = defaultWindowBindings(primaryIsMeta: false);
      final error = ShortcutSettings.findConflict(
        action: ShortcutAction.previous,
        scope: ShortcutScope.window,
        binding: window[ShortcutAction.next],
        window: window,
        global: defaultGlobalBindings(primaryIsMeta: false),
      );
      expect(error, contains('下一首'));
    });

    test('窗口与全局重复组合被拒绝', () {
      final window = defaultWindowBindings(primaryIsMeta: false);
      final global = defaultGlobalBindings(primaryIsMeta: false);
      final error = ShortcutSettings.findConflict(
        action: ShortcutAction.playPause,
        scope: ShortcutScope.window,
        binding: global[ShortcutAction.playPause],
        window: window,
        global: global,
      );
      expect(error, contains('全局快捷键'));
    });

    test('全局快捷键必须带 Ctrl/Alt/Meta', () {
      final window = defaultWindowBindings(primaryIsMeta: false);
      final global = defaultGlobalBindings(primaryIsMeta: false);
      final error = ShortcutSettings.findConflict(
        action: ShortcutAction.playPause,
        scope: ShortcutScope.global,
        binding: ShortcutBinding(keyId: LogicalKeyboardKey.space.keyId),
        window: window,
        global: global,
      );
      expect(error, contains('修饰键'));
    });

    test('鸿蒙全局快捷键拒绝 Meta 且提示 Ctrl/Alt', () {
      final window = defaultWindowBindings(primaryIsMeta: false);
      final global = defaultGlobalBindings(primaryIsMeta: false);
      final metaError = ShortcutSettings.findConflict(
        action: ShortcutAction.playPause,
        scope: ShortcutScope.global,
        binding: ShortcutBinding(
          keyId: LogicalKeyboardKey.keyL.keyId,
          meta: true,
        ),
        window: window,
        global: global,
        metaSupported: false,
      );
      expect(metaError, contains('Meta'));

      final noModifierError = ShortcutSettings.findConflict(
        action: ShortcutAction.playPause,
        scope: ShortcutScope.global,
        binding: ShortcutBinding(keyId: LogicalKeyboardKey.keyL.keyId),
        window: window,
        global: global,
        metaSupported: false,
      );
      expect(noModifierError, contains('Ctrl 或 Alt'));
    });

    test('清除绑定不触发冲突', () {
      expect(
        ShortcutSettings.findConflict(
          action: ShortcutAction.playPause,
          scope: ShortcutScope.global,
          binding: null,
          window: defaultWindowBindings(primaryIsMeta: false),
          global: defaultGlobalBindings(primaryIsMeta: false),
        ),
        isNull,
      );
    });
  });

  group('序列化', () {
    test('JSON 往返保留键与修饰键', () {
      final binding = ShortcutBinding(
        keyId: LogicalKeyboardKey.f1.keyId,
        control: true,
        shift: true,
        alt: false,
        meta: false,
      );
      final parsed = ShortcutBinding.tryParse(binding.toJson());
      expect(parsed, binding);
      expect(parsed!.describe(), 'Ctrl + Shift + F1');
    });

    test('非法 JSON 返回 null', () {
      expect(ShortcutBinding.tryParse(null), isNull);
      expect(ShortcutBinding.tryParse({'keyId': 0}), isNull);
      expect(ShortcutBinding.tryParse({'keyId': 'x'}), isNull);
    });

    test('快捷键键加入备份白名单', () {
      expect(
          AppSettings.knownKeys, contains(AppSettings.kShortcutWindowBindings));
      expect(
          AppSettings.knownKeys, contains(AppSettings.kShortcutGlobalBindings));
    });
  });
}
