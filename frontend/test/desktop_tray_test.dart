import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:selfmusic/platform/desktop_tray.dart';
import 'package:tray_manager/tray_manager.dart';

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
      messenger.setMockMethodCallHandler(
          const MethodChannel('tray_manager'), null);
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

    // 菜单包含播放控制、添加歌曲、设置与退出；空队列时播放项置灰。
    Map<String, dynamic> menuItem(String key) {
      final call = trayCalls.lastWhere((c) => c.method == 'setContextMenu');
      final items = ((call.arguments as Map)['menu'] as Map)['items'] as List;
      return items
          .cast<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .firstWhere(
            (e) => e['key'] == key,
          );
    }

    expect(menuItem('nowPlaying')['label'], '未在播放');
    expect(menuItem('togglePlayback')['disabled'], isTrue);
    expect(menuItem('addSongs')['label'], '添加歌曲…');
    expect(menuItem('settings')['label'], '打开设置');

    var toggles = 0;
    var previous = 0;
    var next = 0;
    var addSongs = 0;
    var settings = 0;
    tray.bindPlaybackActions(
      onToggle: () async => toggles++,
      onPrevious: () async => previous++,
      onNext: () async => next++,
    );
    tray.bindWindowActions(
      onAddSongs: () async => addSongs++,
      onOpenSettings: () async => settings++,
    );

    await tray.updatePlaybackState(
      hasCurrent: true,
      playing: true,
      title: '测试歌曲',
      artist: '测试歌手',
    );
    expect(menuItem('nowPlaying')['label'], contains('测试歌曲'));
    expect(menuItem('togglePlayback')['label'], '暂停');
    expect(menuItem('togglePlayback')['disabled'], isFalse);

    tray.onTrayMenuItemClick(MenuItem(key: 'togglePlayback'));
    tray.onTrayMenuItemClick(MenuItem(key: 'previous'));
    tray.onTrayMenuItemClick(MenuItem(key: 'next'));
    await pumpEventQueue();
    expect(toggles, 1);
    expect(previous, 1);
    expect(next, 1);

    // 添加歌曲 / 打开设置：先恢复窗口，再执行页面动作。
    final showCallsBefore = windowCalls.where((c) => c.method == 'show').length;
    tray.onTrayMenuItemClick(MenuItem(key: 'addSongs'));
    await pumpEventQueue();
    expect(addSongs, 1);
    expect(windowCalls.where((c) => c.method == 'show').length,
        greaterThan(showCallsBefore));
    tray.onTrayMenuItemClick(MenuItem(key: 'settings'));
    await pumpEventQueue();
    expect(settings, 1);

    // Windows：隐藏窗口前必须先释放前台，否则其它应用窗口无法聚焦。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    // 模拟原生窗口关闭事件：应释放焦点并隐藏窗口，而不是走退出。
    final closeEvent = const StandardMethodCodec()
        .encodeMethodCall(const MethodCall('onEvent', {'eventName': 'close'}));
    await messenger.handlePlatformMessage('window_manager', closeEvent, (_) {});
    await Future<void>.delayed(Duration.zero);
    final blurAt = windowCalls.lastIndexWhere((c) => c.method == 'blur');
    final hideAt = windowCalls.lastIndexWhere((c) => c.method == 'hide');
    expect(blurAt, greaterThanOrEqualTo(0));
    expect(hideAt, greaterThan(blurAt));

    // 非 Windows 平台不需要额外 blur，仅隐藏。
    debugDefaultTargetPlatformOverride = null;
    final hideCountBefore = windowCalls.where((c) => c.method == 'hide').length;
    await messenger.handlePlatformMessage('window_manager', closeEvent, (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(windowCalls.where((c) => c.method == 'hide').length,
        hideCountBefore + 1);
    expect(windowCalls.where((c) => c.method == 'blur').length, 1);

    // 托盘菜单「显示主窗口」等价于 show + focus。
    await tray.showWindow();
    expect(windowCalls.map((c) => c.method),
        containsAll(<String>['show', 'focus']));
  });
}
