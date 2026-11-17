import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:selfmusic/providers/auth_provider.dart';
import 'package:selfmusic/screens/settings/pairing_screen.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/secret_store.dart';
import 'package:selfmusic/services/server_settings.dart';
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

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);

  @override
  Future<String> getApplicationSupportPath() async => dir;

  @override
  Future<String> getApplicationCachePath() async => dir;
}

/// 配对密钥接口的成功/失败可切换 fake。
class _MockAdapter implements HttpClientAdapter {
  bool fail = false;
  int keyRequests = 0;

  static const token = 'tok-abcdefgh-1234';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (fail) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'mock offline',
      );
    }
    if (options.uri.path.endsWith('/admin/pairing-token')) {
      keyRequests++;
      return ResponseBody.fromString(
        jsonEncode({
          'data': {'pairing_token': token}
        }),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      '{"data":{}}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory dir;
  late _FakeStorage storage;
  late _MockAdapter adapter;
  late ApiClient api;
  late ServerSettings server;
  late AuthProvider auth;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('selfmusic_pairing_');
    PathProviderPlatform.instance = _FakePathProvider(dir.path);
    storage = _FakeStorage();
    adapter = _MockAdapter();
    final dio = Dio(BaseOptions());
    dio.httpClientAdapter = adapter;
    api = ApiClient(dio: dio, storage: storage);
    server = ServerSettings(secret: SecretStore(storage: storage));
    await server.loadFast();
    auth = AuthProvider(api);
  });

  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<ServerSettings>.value(value: server),
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
        ],
        child: MaterialApp(
          theme: AppTheme.build().themeData,
          home: const PairingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> setAddress(WidgetTester tester, String url) async {
    // setBaseUrl 内部走真实文件 IO，必须脱离 FakeAsync 才能完成。
    await tester.runAsync(() async {
      await server.setBaseUrl(url);
      api.setBaseUrl(url);
    });
    await tester.pumpAndSettle();
  }

  testWidgets('未配置地址：只有本机配对，表单常驻且配对禁用', (tester) async {
    await pumpScreen(tester);

    expect(find.text('本机配对'), findsOneWidget);
    expect(find.text('未配对'), findsOneWidget);
    // 状态行副标题 + 配对密钥区未显示，故只出现一次。
    expect(find.text('未配置服务端地址'), findsOneWidget);
    expect(find.widgetWithText(TextField, '配对令牌'), findsOneWidget);
    expect(find.text('其它设备'), findsNothing);
    expect(find.text('取消配对'), findsNothing);

    final button =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '配对'));
    expect(button.onPressed, isNull, reason: '未配置地址时不可配对');
  });

  testWidgets('配置地址后自动拉取密钥：遮罩显示，点眼睛显示明文', (tester) async {
    await pumpScreen(tester);
    await setAddress(tester, 'https://example.test');

    expect(adapter.keyRequests, 1);
    expect(find.text('其它设备'), findsOneWidget);
    expect(find.textContaining('tok-••••••1234'), findsOneWidget);
    expect(find.textContaining('已获取'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility_outlined));
    await tester.pump();
    expect(find.textContaining('tok-abcdefgh-1234'), findsOneWidget);
  });

  testWidgets('拉取失败：保留缓存并显示离线文案，刷新可重试', (tester) async {
    await server.setPairingKey('tok-abcdefgh-1234');
    await pumpScreen(tester);

    adapter.fail = true;
    await setAddress(tester, 'https://example.test');

    expect(find.textContaining('离线，显示上次保存的密钥'), findsOneWidget);
    expect(find.textContaining('tok-••••••1234'), findsOneWidget);

    adapter.fail = false;
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();
    expect(find.textContaining('已获取'), findsOneWidget);
    expect(find.textContaining('离线'), findsNothing);
  });

  testWidgets('已配对：重新配对默认收起，展开后可取消配对', (tester) async {
    storage.store[ApiClient.kAccess] = 'device-token';
    storage.store[ApiClient.kRefresh] = 'refresh-token';
    storage.store[ApiClient.kClientId] = 'client-id';
    // setUp 里的 ApiClient 已缓存过空 token，这里换一个新实例读取种子令牌。
    final pairedDio = Dio(BaseOptions());
    pairedDio.httpClientAdapter = adapter;
    api = ApiClient(dio: pairedDio, storage: storage);
    auth = AuthProvider(api);
    await pumpScreen(tester);
    await setAddress(tester, 'https://example.test');

    expect(find.text('已配对'), findsOneWidget);
    expect(find.text('已配对设备'), findsOneWidget);
    expect(find.text('取消配对'), findsOneWidget);
    expect(find.widgetWithText(TextField, '配对令牌'), findsNothing,
        reason: '已配对时表单默认收起');
    expect(find.text('重新配对'), findsNWidgets(2));

    await tester.tap(find.text('重新配对').first);
    await tester.pump();
    expect(find.widgetWithText(TextField, '配对令牌'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重新配对'), findsOneWidget);

    await tester.tap(find.text('取消配对'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '取消配对'));
    await tester.pumpAndSettle();

    expect(find.text('未配对'), findsOneWidget);
    expect(find.widgetWithText(TextField, '配对令牌'), findsOneWidget);
    expect(find.text('取消配对'), findsNothing);
  });

  testWidgets('内容宽度上限 640，窄窗口占满', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    tester.view.physicalSize = const Size(1400, 900);
    await pumpScreen(tester);
    final wide = tester.getSize(find.byKey(const ValueKey('pairingContent')));
    expect(wide.width, 640);

    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpAndSettle();
    final narrow = tester.getSize(find.byKey(const ValueKey('pairingContent')));
    expect(narrow.width, 360);
  });
}
