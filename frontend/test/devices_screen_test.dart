import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/screens/settings/devices_screen.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/theme/app_theme.dart';

class _FakeStorage extends FlutterSecureStorage {
  final Map<String, String> store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null || value.isEmpty) {
      store.remove(key);
    } else {
      store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    store.remove(key);
  }
}

/// 设备管理接口 fake：列表 / 改名 / 吊销 / 永久删除。
class _MockAdapter implements HttpClientAdapter {
  _MockAdapter(this.devices);

  List<Map<String, dynamic>> devices;
  final List<String> requests = [];

  int get purgeCount => requests
      .where((r) => r.startsWith('DELETE') && r.endsWith('/purge'))
      .length;

  static ResponseBody _json(Object body) => ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final method = options.method;
    requests.add('$method $path');

    if (method == 'GET' && path.endsWith('/admin/devices')) {
      return _json({'data': devices});
    }

    final purge = RegExp(r'/admin/devices/(\d+)/purge$').firstMatch(path);
    if (method == 'DELETE' && purge != null) {
      final id = int.parse(purge.group(1)!);
      devices = devices.where((d) => d['id'] != id).toList();
      return _json({'data': <String, dynamic>{}});
    }

    final single = RegExp(r'/admin/devices/(\d+)$').firstMatch(path);
    if (single != null) {
      final id = int.parse(single.group(1)!);
      final index = devices.indexWhere((d) => d['id'] == id);
      if (index < 0) return _json({'data': <String, dynamic>{}});
      if (method == 'DELETE') {
        devices[index] = {...devices[index], 'revoked': true};
      } else if (method == 'PUT') {
        final data = options.data;
        if (data is Map && data['name'] is String) {
          devices[index] = {...devices[index], 'name': data['name']};
        }
      }
      return _json({'data': <String, dynamic>{}});
    }

    return _json({'data': <String, dynamic>{}});
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _device({
  required int id,
  required String clientId,
  required String name,
  String platform = 'windows',
  bool revoked = false,
  String? lastSeenAt,
}) {
  return {
    'id': id,
    'clientId': clientId,
    'name': name,
    'platform': platform,
    'revoked': revoked,
    'lastSeenAt': lastSeenAt,
    'pairedAt': '2026-09-01T10:00:00',
  };
}

void main() {
  late _FakeStorage storage;
  late _MockAdapter adapter;
  late ApiClient api;

  List<Map<String, dynamic>> defaultDevices() => [
        _device(
          id: 1,
          clientId: 'self-client',
          name: '我的桌面',
          lastSeenAt: '2026-09-20T12:34:56',
        ),
        _device(
          id: 2,
          clientId: 'other-client',
          name: '旧手机',
          platform: 'android',
          lastSeenAt: '2026-09-19T08:00:00',
        ),
        _device(
          id: 3,
          clientId: 'dead-client',
          name: '已废平板',
          platform: 'android',
          revoked: true,
        ),
      ];

  setUp(() {
    storage = _FakeStorage()..store[ApiClient.kClientId] = 'self-client';
    adapter = _MockAdapter(defaultDevices());
    final dio = Dio(BaseOptions());
    dio.httpClientAdapter = adapter;
    api = ApiClient(dio: dio, storage: storage);
    api.setBaseUrl('https://example.test');
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      Provider<ApiClient>.value(
        value: api,
        child: MaterialApp(
          theme: AppTheme.build().themeData,
          home: const DevicesScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> dismissMenu(WidgetTester tester) async {
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  }

  testWidgets('按状态分组渲染卡片：本机 / 正常设备 / 已吊销', (tester) async {
    await pumpScreen(tester);

    expect(find.text('正常设备'), findsOneWidget);
    // 组头 + 卡片徽标各一次。
    expect(find.text('本机'), findsNWidgets(2));
    expect(find.text('已吊销'), findsNWidgets(2));

    expect(find.byKey(const ValueKey('deviceCard-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceCard-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('deviceCard-3')), findsOneWidget);
    expect(find.text('我的桌面'), findsOneWidget);
    expect(find.text('旧手机'), findsOneWidget);
    expect(find.text('已废平板'), findsOneWidget);
  });

  testWidgets('菜单按状态区分：正常设备可改名/吊销，已吊销只能删除', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('deviceMenu-3')));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('改名'), findsNothing);
    expect(find.text('吊销'), findsNothing);
    await dismissMenu(tester);

    await tester.tap(find.byKey(const ValueKey('deviceMenu-2')));
    await tester.pumpAndSettle();
    expect(find.text('改名'), findsOneWidget);
    expect(find.text('吊销'), findsOneWidget);
    expect(find.text('删除'), findsNothing);
    await dismissMenu(tester);
  });

  testWidgets('删除已吊销设备：确认后调用 purge 并刷新列表', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('deviceMenu-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('永久删除设备？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(
      adapter.requests,
      contains('DELETE /api/v1/admin/devices/3/purge'),
    );
    expect(find.byKey(const ValueKey('deviceCard-3')), findsNothing);
    expect(find.text('已吊销'), findsNothing);
  });

  testWidgets('整组清空已吊销设备：逐条 purge 后分组消失', (tester) async {
    adapter.devices = [
      ...defaultDevices(),
      _device(
        id: 4,
        clientId: 'dead-client-2',
        name: '退役手表',
        platform: 'android',
        revoked: true,
      ),
    ];
    await pumpScreen(tester);

    await tester.tap(find.widgetWithText(TextButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空已吊销设备？'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '全部删除'));
    await tester.pumpAndSettle();

    expect(adapter.purgeCount, 2);
    expect(find.byKey(const ValueKey('deviceCard-3')), findsNothing);
    expect(find.byKey(const ValueKey('deviceCard-4')), findsNothing);
    expect(find.text('已吊销'), findsNothing);
  });

  testWidgets('卡片网格随宽度自适应 1/2/4 列', (tester) async {
    adapter.devices = [
      ...defaultDevices(),
      for (var i = 10; i < 16; i++)
        _device(
          id: i,
          clientId: 'client-$i',
          name: '设备 $i',
          lastSeenAt: '2026-09-0${i % 9 + 1}T10:00:00',
        ),
    ];
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    int columns() {
      final grid = tester.widget<GridView>(find.byType(GridView).first);
      return (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount;
    }

    tester.view.physicalSize = const Size(1400, 900);
    await pumpScreen(tester);
    expect(columns(), 4);

    tester.view.physicalSize = const Size(700, 900);
    await tester.pumpAndSettle();
    expect(columns(), 2);

    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpAndSettle();
    expect(columns(), 1);
  });
}
