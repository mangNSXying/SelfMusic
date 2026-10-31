import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/platform/desktop_tray.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('托盘可用：关闭窗口隐藏、托盘恢复显示', () async {
    final windowCalls = <MethodCall>[];
    final trayCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'),
        (call) async {
      windowCalls.add(call);
      if (call.method == 'isMinimized') return false;
      return true;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('tray_manager'),
        (call) async {
      trayCalls.add(call);
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(
          const MethodChannel('window_manager'), null);
      messenger
          .setMockMethodCallHandler(const MethodChannel('tray_manager'), null);
    });

    final tray = DesktopTray.instance;
    await tray.initWindow();
    await tray.initTray(closeToTray: true);

    expect(tray.trayReady, isTrue);
    expect(
      windowCalls.map((c) => c.method),
      containsAll(<String>['ensureInitialized', 'setPreventClose']),
    );
    expect(
      windowCalls
          .lastWhere((c) => c.method == 'setPreventClose')
          .arguments['isPreventClose'],
      isTrue,
    );
    expect(
      trayCalls.map((c) => c.method),
      containsAll(<String>['setIcon', 'setContextMenu']),
    );

    // 模拟原生窗口关闭事件：应隐藏窗口而不是走退出。
    final closeEvent = const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('onEvent', {'eventName': 'close'}));
    await messenger.handlePlatformMessage('window_manager', closeEvent, (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(windowCalls.map((c) => c.method), contains('hide'));

    // 托盘菜单「显示主窗口」等价于 show + focus。
    await tray.showWindow();
    expect(windowCalls.map((c) => c.method), containsAll(<String>['show', 'focus']));
  });
}
