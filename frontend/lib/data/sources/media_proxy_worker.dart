import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'smb_dart_smb2.dart';
import 'sftp_common.dart';
import 'sftp_worker.dart';

/// MediaProxy 独立 isolate 入口。
///
/// 数据路径：SMB/SFTP 连接与读取都在本 isolate 内完成，HTTP 响应直接写给
/// native player（mpv/ExoPlayer/AVPlayer）；UI isolate 只收 URL 和控制消息。
void mediaProxyIsolateEntry(List<Object?> args) {
  final ready = args[0] as SendPort;
  final events = args[1] as SendPort;
  _MediaProxyEngine(events).run(ready);
}

class _MediaProxyEngine {
  _MediaProxyEngine(this.events);

  final SendPort events;
  HttpServer? _server;
  ReceivePort? _cmd;
  _ProxySession? _session;
  Future<void> _queue = Future<void>.value();

  void _log(String tag, [Object? extra]) {
    try {
      events.send({
        'op': 'log',
        'line': '$tag${extra == null ? '' : ' $extra'}',
      });
    } catch (_) {}
  }

  Future<void> run(SendPort ready) async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.autoCompress = false;
      _server = server;
      server.listen((req) => unawaited(_handleHttp(req)));
      final cmd = ReceivePort();
      _cmd = cmd;
      cmd.listen((msg) {
        if (msg is! Map) return;
        _queue = _queue.then((_) => _handleCommand(msg)).catchError((Object e) {
          _log('command.error', e);
        });
      });
      ready.send(cmd.sendPort);
      _log('isolate.ready', 'port=${server.port}');
    } catch (e) {
      _log('isolate.bindFail', e);
      Isolate.exit();
    }
  }

  Future<void> _handleCommand(Map msg) async {
    final op = msg['op'];
    final id = msg['id'];
    switch (op) {
      case 'start':
        await _startSession(msg, id);
        break;
      case 'stop':
        await _stopSession();
        _reply(id, {'ok': true});
        break;
      case 'shutdown':
        await _stopSession();
        try {
          await _server?.close(force: true);
        } catch (_) {}
        _reply(id, {'ok': true});
        _log('isolate.shutdown');
        _cmd?.close();
        Isolate.exit();
    }
  }

  void _reply(Object? id, Map<String, Object?> body) {
    if (id == null) return;
    try {
      events.send({'id': id, ...body});
    } catch (_) {}
  }

  Future<void> _startSession(Map msg, Object? id) async {
    _ProxyAdapter? adapter;
    try {
      final config = (msg['config'] as Map).cast<String, Object?>();
      final basename = (msg['basename'] as String?) ?? 'audio.bin';
      await _stopSession();
      adapter = _createAdapter(config);
      final swProbe = Stopwatch()..start();
      _log('adapter.probe.start', 'kind=${config['kind']} key=${config['sourceKey']}');
      final total = await adapter.probe();
      _log('adapter.probe.done',
          'kind=${config['kind']} key=${config['sourceKey']} total=$total ms=${swProbe.elapsedMilliseconds}');
      if (total <= 0) {
        throw StateError('无法确定媒体大小（${config['sourceKey']}）');
      }
      final token = _newToken();
      final session = _ProxySession(
        token: token,
        basename: basename,
        adapter: adapter,
        total: total,
        mime: (config['mime'] as String?) ?? 'application/octet-stream',
        sourceKey: (config['sourceKey'] as String?) ?? '',
        kind: (config['kind'] as String?) ?? '',
      );
      _session = session;
      _log('session.start',
          'kind=${session.kind} key=${session.sourceKey} total=$total basename=${session.basename}');
      _reply(id, {
        'ok': true,
        'port': _server!.port,
        'token': token,
        'total': total,
      });
    } catch (e) {
      try {
        await adapter?.close();
      } catch (_) {}
      _session = null;
      _log('session.startFail', '$e');
      _reply(id, {'ok': false, 'error': '$e'});
    }
  }

  Future<void> _stopSession() async {
    final session = _session;
    _session = null;
    if (session == null) return;
    session.closed = true;
    await session.drain();
    try {
      await session.adapter.close();
    } catch (e) {
      _log('session.closeError', e);
    }
    _log('session.stop', 'key=${session.sourceKey}');
  }

  _ProxyAdapter _createAdapter(Map<String, Object?> config) {
    switch (config['kind']) {
      case 'smb':
        return _SmbProxyAdapter(config);
      case 'sftp':
        return _SftpProxyAdapter(config);
      case 'file':
        // 仅测试：本机文件，用来验证 HTTP/Range/生命周期。
        return _FileProxyAdapter(config);
      default:
        throw StateError('MediaProxy 不支持的源类型：${config['kind']}');
    }
  }

  Future<void> _handleHttp(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length < 3 || segments[0] != 'media') {
      _simple(request, HttpStatus.notFound, 'not found');
      return;
    }
    final session = _session;
    final token = segments[1];
    if (session == null) {
      _simple(request, HttpStatus.notFound, 'no session');
      return;
    }
    if (session.closed || token != session.token) {
      _simple(request, HttpStatus.gone, 'stale session');
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      _simple(request, HttpStatus.methodNotAllowed, 'method');
      return;
    }
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final parsed = _parseRange(rangeHeader, session.total);
    if (parsed == null) {
      try {
        request.response.statusCode =
            HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */${session.total}');
        request.response.headers.contentLength = 0;
        await request.response.close();
      } catch (_) {}
      _log('http.badRange',
          'key=${session.sourceKey} range=$rangeHeader total=${session.total}');
      return;
    }
    final (start, endExclusive) = (parsed[0], parsed[1]);
    final partial = start != 0 || endExclusive != session.total;
    if (request.method == 'HEAD') {
      _setHeaders(request.response, session, start, endExclusive, partial);
      await request.response.close();
      _log('http.head',
          'key=${session.sourceKey} range=$start-$endExclusive total=${session.total}');
      return;
    }

    session.active++;
    // 越短的 Range 越像 seek/探测，优先于整首缓存流；同长度由新流优先。
    final rangeLen = endExclusive - start;
    final priority = session.total - rangeLen;
    final tie = ++session.streamSeq;
    final sw = Stopwatch()..start();
    var wrote = false;
    var sent = 0;
    var aborted = false;
    var clientGone = false;
    var transferError = false;
    try {
      final stream = await session.adapter.open(start, endExclusive,
          priority: priority, tie: tie);
      _setHeaders(request.response, session, start, endExclusive, partial);
      request.response.bufferOutput = false;
      unawaited(request.response.done.then(
        (_) => clientGone = true,
        onError: (Object e, StackTrace st) => clientGone = true,
      ));
      _log('http.request',
          'key=${session.sourceKey} prio=$priority tie=$tie range=$start-$endExclusive total=${session.total}');
      await for (final chunk in stream) {
        if (clientGone || session.closed) {
          aborted = true;
          _log('http.cancel',
              'key=${session.sourceKey} range=$start-$endExclusive bytes=$sent');
          break;
        }
        request.response.add(chunk);
        wrote = true;
        sent += chunk.length;
        await request.response.flush();
      }
      final shortRead = !aborted && sent < endExclusive - start;
      final goneBeforeClose = aborted || clientGone || session.closed;
      if (shortRead) aborted = true;
      try {
        await request.response.close();
      } catch (_) {
        // 提前中止时已按完整区间声明 contentLength，写入不足会让 close()
        // 抛 HttpException；这是切歌/停止的正常收尾，不是传输失败。
        // 客户端仍在却写不满，才是适配器提前收流，必须保留错误日志。
        if (!goneBeforeClose) {
          transferError = true;
          rethrow;
        }
        aborted = true;
      }
      _log(aborted ? 'http.abort' : 'http.done',
          'key=${session.sourceKey} range=$start-$endExclusive bytes=$sent ms=${sw.elapsedMilliseconds}');
    } catch (e) {
      final expected = !transferError && (aborted || clientGone || session.closed);
      _log(expected ? 'http.abort' : 'http.error',
          'key=${session.sourceKey} range=$start-$endExclusive bytes=$sent ms=${sw.elapsedMilliseconds} e=$e');
      try {
        if (!expected && !wrote) {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.headers.contentLength = 0;
        }
        await request.response.close();
      } catch (_) {}
    } finally {
      session.requestDone();
    }
  }

  List<int>? _parseRange(String? header, int total) {
    if (header == null || header.isEmpty) return [0, total];
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (m == null) return null;
    final a = m[1]!;
    final b = m[2]!;
    if (a.isEmpty && b.isEmpty) return null;
    int start;
    int endExclusive;
    if (a.isEmpty) {
      final n = int.tryParse(b);
      if (n == null || n <= 0) return null;
      start = total - n;
      if (start < 0) start = 0;
      endExclusive = total;
    } else {
      final s = int.tryParse(a);
      if (s == null || s < 0 || s >= total) return null;
      start = s;
      if (b.isEmpty) {
        endExclusive = total;
      } else {
        final e = int.tryParse(b);
        if (e == null || e < start) return null;
        endExclusive = min(e + 1, total);
      }
    }
    if (endExclusive <= start) return null;
    return [start, endExclusive];
  }

  void _setHeaders(HttpResponse response, _ProxySession session, int start,
      int endExclusive, bool partial) {
    response.statusCode =
        partial ? HttpStatus.partialContent : HttpStatus.ok;
    try {
      response.headers.contentType = ContentType.parse(session.mime);
    } catch (_) {
      response.headers.contentType = ContentType.binary;
    }
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    response.headers.contentLength = endExclusive - start;
    if (partial) {
      response.headers.set(HttpHeaders.contentRangeHeader,
          'bytes $start-${endExclusive - 1}/${session.total}');
    }
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
  }

  void _simple(HttpRequest request, int status, String message) {
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.text;
      request.response.write(message);
      request.response.close().ignore();
    } catch (_) {}
  }

  String _newToken() {
    final r = Random.secure();
    return List<int>.generate(16, (_) => r.nextInt(256))
        .map((e) => e.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

class _ProxySession {
  _ProxySession({
    required this.token,
    required this.basename,
    required this.adapter,
    required this.total,
    required this.mime,
    required this.sourceKey,
    required this.kind,
  });

  final String token;
  final String basename;
  final _ProxyAdapter adapter;
  final int total;
  final String mime;
  final String sourceKey;
  final String kind;
  bool closed = false;
  int active = 0;
  int streamSeq = 0;
  Completer<void>? _idle;

  void requestDone() {
    if (active > 0) active--;
    if (active == 0) {
      _idle?.complete();
      _idle = null;
    }
  }

  Future<void> drain() async {
    if (active == 0) return;
    final idle = _idle ??= Completer<void>();
    await idle.future.timeout(const Duration(milliseconds: 300),
        onTimeout: () {});
  }
}

abstract class _ProxyAdapter {
  Future<int> probe();
  Future<Stream<List<int>>> open(int start, int endExclusive,
      {int priority = 0, int tie = 0});
  Future<void> close();
}

class _FileProxyAdapter implements _ProxyAdapter {
  _FileProxyAdapter(Map<String, Object?> config)
      : _file = File(config['path']! as String),
        _known = (config['size'] as num?)?.toInt() ?? 0;

  final File _file;
  final int _known;

  @override
  Future<int> probe() async {
    try {
      final n = await _file.length();
      return n > 0 ? n : _known;
    } catch (_) {
      return _known;
    }
  }

  @override
  Future<Stream<List<int>>> open(int start, int endExclusive,
          {int priority = 0, int tie = 0}) async =>
      _file.openRead(start, endExclusive);

  @override
  Future<void> close() async {}
}

class _SmbProxyAdapter implements _ProxyAdapter {
  _SmbProxyAdapter(Map<String, Object?> config)
      : _path = config['path']! as String,
        _known = (config['size'] as num?)?.toInt() ?? 0,
        _backend = Smb2PoolBackend(
          host: config['host']! as String,
          share: config['share']! as String,
          username: (config['username'] as String?) ?? '',
          password: (config['password'] as String?) ?? '',
          initBrokerPort: config['smbBrokerPort'] as SendPort?,
        );

  final String _path;
  final int _known;
  final Smb2PoolBackend _backend;

  @override
  Future<int> probe() async {
    final n = await _backend.fileSize(_path);
    return n > 0 ? n : _known;
  }

  @override
  Future<Stream<List<int>>> open(int start, int endExclusive,
          {int priority = 0, int tie = 0}) async =>
      _backend.readStream(_path, start, endExclusive);

  @override
  Future<void> close() => _backend.close();
}

class _SftpProxyAdapter implements _ProxyAdapter {
  _SftpProxyAdapter(Map<String, Object?> config)
      : _path = config['path']! as String,
        _known = (config['size'] as num?)?.toInt() ?? 0,
        _host = config['host']! as String,
        _port = (config['port'] as num?)?.toInt() ?? 22,
        _username = (config['username'] as String?) ?? '',
        _auth = parseSftpAuthMethod(config['auth']),
        _password = (config['password'] as String?) ?? '',
        _keyPem = (config['keyPem'] as String?) ?? '',
        _keyPassphrase = (config['keyPassphrase'] as String?) ?? '',
        _pinnedFp = config['pinnedFp']! as String;

  final String _path;
  final int _known;
  final String _host;
  final int _port;
  final String _username;
  final SftpAuthMethod _auth;
  final String _password;
  final String _keyPem;
  final String _keyPassphrase;
  final String _pinnedFp;
  SftpWorker? _worker;
  Future<void>? _starting;

  Future<void> _ensure() async {
    final cur = _worker;
    if (cur != null && !cur.isClosed) return;
    final starting = _starting;
    if (starting != null) {
      await starting;
      return;
    }
    final f = _start();
    _starting = f;
    try {
      await f;
    } finally {
      if (identical(_starting, f)) _starting = null;
    }
  }

  Future<void> _start() async {
    _worker = await SftpWorker.start(
      host: _host,
      port: _port,
      username: _username,
      authMethod: _auth,
      password: _password,
      keyPem: _keyPem,
      keyPassphrase: _keyPassphrase,
      pinnedFp: _pinnedFp,
    );
  }

  @override
  Future<int> probe() async {
    await _ensure();
    // 探针只读 1 字节，给最高优先级，避免排在播放流的读后面。
    final r = await _worker!.open(_path,
        start: 0, length: 1, fallbackTotal: _known, priority: 1 << 40);
    final total = r.totalLength ?? _known;
    try {
      final sub = r.stream.listen(null);
      await sub.cancel();
    } catch (_) {}
    return total;
  }

  @override
  Future<Stream<List<int>>> open(int start, int endExclusive,
      {int priority = 0, int tie = 0}) async {
    await _ensure();
    final r = await _worker!.open(_path,
        start: start,
        length: endExclusive - start,
        fallbackTotal: _known,
        priority: priority,
        tie: tie);
    return r.stream;
  }

  @override
  Future<void> close() async {
    final w = _worker;
    _worker = null;
    if (w != null) {
      try {
        await w.close();
      } catch (_) {}
    }
  }
}
