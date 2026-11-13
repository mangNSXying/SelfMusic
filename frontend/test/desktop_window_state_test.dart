import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/platform/desktop_window_state.dart';
import 'package:sqlite3/open.dart';

/// 桌面端窗口几何记忆：冷启动恢复尺寸/位置与最大化，无记录时居中。
///
/// 托盘/窗口状态测试沿用仓库「真实实例」模式：真实 LocalIndex（sqlite3
/// open.overrideFor）+ mock 的 window_manager / screen_retriever 平台通道。

DynamicLibrary _openOnLinux() {
  try {
    return DynamicLibrary.open('libsqlite3.so');
  } on ArgumentError {
    return DynamicLibrary.open('libsqlite3.so.0');
  }
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String> getApplicationSupportPath() async => dir;
  @override
  Future<String> getApplicationCachePath() async => dir;
}

const MethodChannel _windowChannel = MethodChannel('window_manager');
const MethodChannel _screenChannel =
    MethodChannel('dev.leanflutter.plugins/screen_retriever');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalIndex index;
  late AppSettings settings;
  late List<MethodCall> windowCalls;
  late Rect bounds;
  late bool maximized;
  late bool minimized;

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, Object?> display({double width = 1920, double height = 1080}) =>
      <String, Object?>{
        'id': 'primary',
        'name': 'Primary',
        'size': <String, Object?>{'width': width, 'height': height},
        'visiblePosition': <String, Object?>{'dx': 0.0, 'dy': 0.0},
        'visibleSize': <String, Object?>{
          'width': width,
          'height': height - 40,
        },
        'scaleFactor': 1.0,
      };

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    dir = await Directory.systemTemp.createTemp('selfmusic_winstate_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    index = LocalIndex();
    await index.open();
    settings = AppSettings(index);

    windowCalls = [];
    bounds = const Rect.fromLTWH(10, 10, 1280, 720);
    maximized = false;
    minimized = false;

    messenger.setMockMethodCallHandler(_windowChannel, (call) async {
      windowCalls.add(call);
      switch (call.method) {
        case 'getBounds':
          return <String, Object?>{
            'x': bounds.left,
            'y': bounds.top,
            'width': bounds.width,
            'height': bounds.height,
          };
        case 'isMaximized':
          return maximized;
        case 'isMinimized':
          return minimized;
      }
      return true;
    });
    messenger.setMockMethodCallHandler(_screenChannel, (call) async {
      switch (call.method) {
        case 'getAllDisplays':
          return <String, Object?>{
            'displays': [display()],
          };
        case 'getPrimaryDisplay':
          return display();
        case 'getCursorScreenPoint':
          return <String, Object?>{'dx': 0.0, 'dy': 0.0};
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_windowChannel, null);
    messenger.setMockMethodCallHandler(_screenChannel, null);
    index.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> fireWindowEvent(String eventName) async {
    final args = const StandardMethodCodec()
        .encodeMethodCall(MethodCall('onEvent', {'eventName': eventName}));
    await messenger.handlePlatformMessage('window_manager', args, (_) {});
  }

  Future<void> waitSaved() => Future<void>.delayed(
      DesktopWindowState.saveDelay + const Duration(milliseconds: 200));

  test('无历史记录：窗口居中，并按记录恢复最大化', () async {
    settings.windowMaximized = true;
    final state = DesktopWindowState();
    addTearDown(state.detach);

    await state.restore(settings);

    // windowManager.center() 在 Dart 侧组合为 getBounds + setBounds(x, y)：
    // 可视区域 1920×1040、窗口 1280×720 → 居中位置 (320, 160)。
    final call = windowCalls.firstWhere((c) => c.method == 'setBounds');
    expect(call.arguments['x'], 320);
    expect(call.arguments['y'], 160);
    expect(call.arguments.containsKey('width'), isFalse);
    expect(windowCalls.map((c) => c.method), contains('maximize'));
  });

  test('损坏的历史记录回退为居中', () async {
    settings.windowBounds = 'not-json';
    final state = DesktopWindowState();
    addTearDown(state.detach);

    await state.restore(settings);

    final call = windowCalls.firstWhere((c) => c.method == 'setBounds');
    expect(call.arguments['x'], 320);
    expect(call.arguments['y'], 160);
    expect(call.arguments.containsKey('width'), isFalse);
  });

  test('有历史记录：按记录恢复尺寸与位置', () async {
    settings.windowBounds = jsonEncode(<double>[100, 80, 1000, 700]);
    final state = DesktopWindowState();
    addTearDown(state.detach);

    await state.restore(settings);

    final call = windowCalls.firstWhere((c) => c.method == 'setBounds');
    expect(call.arguments['x'], 100);
    expect(call.arguments['y'], 80);
    expect(call.arguments['width'], 1000);
    expect(call.arguments['height'], 700);
  });

  test('历史位置在屏幕外：钳制回当前显示器可视区域', () async {
    settings.windowBounds = jsonEncode(<double>[5000, 4000, 1000, 700]);
    final state = DesktopWindowState();
    addTearDown(state.detach);

    await state.restore(settings);

    final call = windowCalls.firstWhere((c) => c.method == 'setBounds');
    // 可视区域 1920×1040：右下角贴边。
    expect(call.arguments['x'], 920);
    expect(call.arguments['y'], 340);
    expect(call.arguments['width'], 1000);
    expect(call.arguments['height'], 700);
  });

  test('拖动/缩放防抖保存几何；最大化只记标记、不覆盖几何', () async {
    final state = DesktopWindowState();
    addTearDown(state.detach);
    await state.restore(settings);

    bounds = const Rect.fromLTWH(200, 120, 900, 640);
    await fireWindowEvent('resize');
    await waitSaved();

    expect(DesktopWindowState.decodeBounds(settings.windowBounds),
        const Rect.fromLTWH(200, 120, 900, 640));

    // 最大化：getBounds 此时是整屏（模拟为满屏），不能覆盖普通状态几何。
    maximized = true;
    bounds = const Rect.fromLTWH(0, 0, 1920, 1040);
    await fireWindowEvent('maximize');
    await waitSaved();

    expect(settings.windowMaximized, isTrue);
    expect(DesktopWindowState.decodeBounds(settings.windowBounds),
        const Rect.fromLTWH(200, 120, 900, 640));

    // 取消最大化：记录回普通状态的几何，并清掉最大化标记。
    maximized = false;
    bounds = const Rect.fromLTWH(200, 120, 900, 640);
    await fireWindowEvent('unmaximize');
    await waitSaved();

    expect(settings.windowMaximized, isFalse);
    expect(DesktopWindowState.decodeBounds(settings.windowBounds),
        const Rect.fromLTWH(200, 120, 900, 640));
  });

  test('最小化时不写入屏外占位几何', () async {
    settings.windowBounds = jsonEncode(<double>[100, 80, 1000, 700]);
    final state = DesktopWindowState();
    addTearDown(state.detach);
    await state.restore(settings);

    minimized = true;
    bounds = const Rect.fromLTWH(-32000, -32000, 160, 28);
    await fireWindowEvent('resize');
    await waitSaved();

    expect(DesktopWindowState.decodeBounds(settings.windowBounds),
        const Rect.fromLTWH(100, 80, 1000, 700));
  });
}
