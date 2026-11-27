import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:selfmusic/data/local/app_settings.dart';
import 'package:selfmusic/data/local/local_index.dart';
import 'package:selfmusic/services/api_client.dart';
import 'package:selfmusic/services/sync_engine.dart';
import 'package:sqlite3/open.dart';

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

/// SSE 生命周期测试：能力协商、断点唤醒、前后台门控、404 降级。
class _SseApi extends ApiClient {
  int streams = 0;
  int pulls = 0;
  int latestFetches = 0;
  int? streamStatus;
  bool cancelled = false;
  StreamController<Uint8List>? controller;

  @override
  String get baseUrl => 'https://sse.example';

  @override
  Future<String?> getClientId() async => 'test-client';

  @override
  Future<Map<String, dynamic>?> syncPull(int cursor) async {
    pulls++;
    return {
      'cursor': cursor + 1,
      'has_more': false,
      'songs': [],
      'sources': [],
      'playlists': [],
      'playstates': [],
      'settings': [],
      'breakpoint_protocol': 2,
      'push_protocol': 1,
      'server_time': '2026-11-27T12:00:00',
    };
  }

  @override
  Future<Map<String, dynamic>?> syncPush(
      String clientId, List<Map<String, dynamic>> events) async {
    return {
      'applied': [],
      'duplicates': [],
      'breakpoint_protocol': 2,
      'push_protocol': 1,
      'server_time': '2026-11-27T12:00:00',
    };
  }

  @override
  Future<Map<String, dynamic>?> fetchLatestBreakpoint() async {
    latestFetches++;
    return {
      'client_uuid': 'pl-1',
      'source': 'webdav',
      'source_ref': '/a.mp3',
      'position_ms': 1000,
      'device_client_id': 'other-device',
      'breakpoint_protocol': 2,
      'push_protocol': 1,
      'server_epoch': 'epoch-1',
      'updated_at': '2026-11-27T12:00:00',
      'head_rev': 1,
      'history_rev': 1,
      'head_updated_at': '2026-11-27T12:00:00',
    };
  }

  @override
  Future<Response<ResponseBody>> openEventStream(String path) async {
    streams++;
    if (streamStatus != null) {
      final req = RequestOptions(path: path);
      throw DioException(
        requestOptions: req,
        response: Response(requestOptions: req, statusCode: streamStatus),
        type: DioExceptionType.badResponse,
      );
    }
    final c = StreamController<Uint8List>();
    controller = c;
    c.onCancel = () {
      cancelled = true;
    };
    return Response<ResponseBody>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: ResponseBody(c.stream, 200),
    );
  }

  void emit(String text) {
    controller?.add(Uint8List.fromList(utf8.encode(text)));
  }
}

void main() {
  late LocalIndex index;
  late Directory tmp;
  late SyncEngine engine;
  late _SseApi api;
  late Duration savedTick;

  setUp(() async {
    open.overrideFor(OperatingSystem.linux, () => _openOnLinux());
    tmp = await Directory.systemTemp.createTemp('selfmusic_syncsse_');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    index = LocalIndex();
    await index.open();
    api = _SseApi();
    engine = SyncEngine(api: api, index: index, settings: AppSettings(index));

    // 不在测试里等 2s tick；只验证 start/pause/resume 与 SSE 事件本身。
    savedTick = SyncEngine.tickFast;
    SyncEngine.tickFast = const Duration(seconds: 30);
  });

  tearDown(() async {
    engine.stop();
    engine.setPlaying(false);
    try {
      await api.controller?.close();
    } catch (_) {}
    SyncEngine.tickFast = savedTick;
    try {
      await engine.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } catch (_) {}
    index.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('push_protocol 出现后建立 SSE；breakpoint 事件走快路径', () async {
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.streams, 1, reason: '服务端声明 push_protocol 后应建立 SSE');
    expect(api.controller, isNotNull);

    api.emit('event: ready\n'
        'data: {"push_protocol":1,"breakpoint_protocol":2,'
        '"server_epoch":"epoch-1","server_time":"2026-11-27T12:00:00",'
        '"cursor":1}\n\n');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final beforeLatest = api.latestFetches;
    final beforePulls = api.pulls;
    api.emit('event: breakpoint\n'
        'data: {"playlist_uuid":"pl-1","head_rev":2,"history_rev":2,'
        '"intent":"progress","cursor":2,'
        '"server_time":"2026-11-27T12:00:01"}\n\n');
    await Future<void>.delayed(const Duration(milliseconds: 450));

    expect(api.latestFetches, greaterThan(beforeLatest),
        reason: 'breakpoint 事件应触发 /playstates/latest 快路径');
    expect(api.pulls, beforePulls,
        reason: '快路径已覆盖该歌单时不应再触发全量 pull');
  });

  test('后台未播放断开 SSE；回前台重连', () async {
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.streams, 1);

    engine.pause();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(api.cancelled, isTrue, reason: '后台未播放应取消 SSE 订阅');

    engine.resume();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(api.streams, 2, reason: '回前台应重新建立 SSE');
  });

  test('SSE 端点 404 后本会话不再重连', () async {
    api.streamStatus = 404;
    engine.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(api.streams, 1);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(api.streams, 1, reason: '旧服务端/无端点不应反复重试');
  });
}
