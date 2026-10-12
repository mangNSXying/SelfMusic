import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../models/song.dart';
import '../../platform/harmonyos/ohos_bootstrap.dart';
import '../../platform/harmonyos/ohos_platform_bridge.dart';
import 'music_source.dart';
import 'scan_worker.dart';
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

/// 本地文件夹直连源：扫描/播放本机目录（Linux 桌面 + Android 共享存储）。
///
/// - 扫描：worker isolate 驱动 [runScan]（[scan]），先枚举（stat 快照），再按
///   增量指纹跳过 快速：只建索引（枚举 + stat 即落库，不打开音频文件）；
///   [ScanOptions] 只控制过滤。
/// - 播放：文件本身即本地，[cachedFilePath] 直接返回原路径走 setFilePath；
///   [open] 作为 Range 流式兜底。
/// - Android 读取共享存储需运行时权限（READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE），扫描前申请。
/// - ohos（鸿蒙）：[rootPath] 为系统目录选择器授权 URI（`file://docs/...`）。
///   dart:io 无法访问授权 URI，扫描在主 isolate 经平台桥完成（[scan] 的
///   isOhos 分支）；[cachedFilePath] 经桥解析沙箱真路径（openSync(uri).path）
///   返回后播放走 setFilePath 直连（mdk 原生 file://，2026-10-07 修复：
///   绕开 just_audio 本地代理——真机取证代理对死锁后事件通知空转烧
///   ~1.5 核 CPU），解析失败回退 [open] 的字节流分支（512 KiB 分块
///   readRange → DirectAudioSource → just_audio 本地代理 → fvp/mdk），
///   元数据/封面/歌词补读同路径自动复用。
class LocalDirectSource implements MusicSource {
  @override
  final String name;
  final String rootPath;
  final LocalIndex index;

  LocalDirectSource({
    required this.name,
    required this.rootPath,
    required this.index,
  });

  @override
  String get key => 'local:$name';

  @override
  SourceKind get kind => SourceKind.local;

  @override
  bool get supportsDirect => true;

  /// 本地源恒直连：文件本体即缓存，不经服务端。
  @override
  SourceRoute get route => SourceRoute.direct;

  @override
  Future<List<Song>> search(
          {String? query, int page = 1, int size = 100}) async =>
      index.searchSongs(sourceKey: key, query: query, page: page, size: size);

  // ---------- 直连扫描 ----------

  @override
  Future<ScanSummary> scan(
      {ScanOptions options = const ScanOptions(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async {
    await _ensureAudioPermission();
    final out = isOhos
        ? await _ohosScan(options: options, token: token, onProgress: onProgress)
        : await runScan<List<_LocalWalkOut>>(
            entry: _localWalkEntry,
            params: <String, Object?>{
              'key': key,
              'root': rootPath,
              'minSizeBytes': options.minSizeBytes,
              'known': index.scanFingerprint(key),
            },
            token: token,
            onProgress: onProgress,
          );

    final alive = <String>[];
    final toWrite = <DirectSongRow>[];
    var added = 0, updated = 0, unchanged = 0;
    for (final item in out) {
      alive.add(item.row.ref);
      switch (item.kind) {
        case _OutKind.unchanged:
          unchanged++;
          continue;
        case _OutKind.added:
          added++;
        case _OutKind.updated:
          updated++;
      }
      // 快速扫描不取封面（item.cover 恒为 null），此分支保留给未来取值方式变化。
      final coverPath = item.cover == null || item.cover!.isEmpty
          ? null
          : index.persistCover(item.cover!, item.row.ref);
      toWrite.add(DirectSongRow(
        sourceKey: item.row.sourceKey,
        ref: item.row.ref,
        title: item.row.title,
        titleFromMeta: item.row.titleFromMeta,
        artist: item.row.artist,
        album: item.row.album,
        albumArtist: item.row.albumArtist,
        trackNo: item.row.trackNo,
        year: item.row.year,
        genre: item.row.genre,
        duration: item.row.duration,
        format: item.row.format,
        size: item.row.size,
        mtime: item.row.mtime,
        etag: item.row.etag,
        coverPath: coverPath ?? item.row.coverPath,
      ));
    }
    // 提交（写隔离批量单事务）：await 保证 scan 返回时行已落库可见。
    await index.upsertSongs(toWrite);
    await index.markMissingExcept(key, alive);
    await index.clearMissing(key);
    return ScanSummary(
        added: added,
        updated: updated,
        unchanged: unchanged,
        total: alive.length);
  }

  /// ohos 目录枚举：直接列举（同会话临时授权与已激活的持久化授权均可
  /// 读），失败时激活持久化授权后重试一次——重启后首次扫描落入重试分支
  /// （持久化数据存系统数据库，每次启动需手动激活才生效）。激活也失败
  /// （授权被撤销/目录删除/从未持久化成功）时 PlatformException 上抛，由
  /// [_ohosScan] 统一转译为用户文案。
  ///
  /// 不采用「先激活再枚举」：先枚举后激活重试在「会话内 activate 异常」
  /// 与「持久化未成功」两种场景下行为均正确，且常规路径少一次桥调用
  /// （2026-10-06 引入；2026-10-07 hilog 证实该环节工作正常——根因是
  /// ArkTS 侧把 URI 直接传给仅收沙箱路径的 fs.listFile，已修复）。
  Future<List<OhosDirEntry>> _listOhosDirectory() async {
    try {
      return await OhosPlatformBridge.listDirectory(rootPath);
    } on PlatformException {
      await OhosPlatformBridge.activateDirectory(rootPath);
      return await OhosPlatformBridge.listDirectory(rootPath);
    }
  }

  /// ohos 扫描（主 isolate，不走 runScan worker）：dart:io 无法访问授权
  /// URI、平台通道 handler 也注册在主 isolate，故桥一次性返回全量枚举
  /// （ArkTS 侧 fs.listFile + 逐文件 stat），Dart 侧复用 [_diffSnapshotEntry]
  /// 公共 diff。取消/进度降级为调用前后检查（桥调用进行中不可取消）。
  Future<List<_LocalWalkOut>> _ohosScan({
    required ScanOptions options,
    ScanToken? token,
    void Function(ScanProgress)? onProgress,
  }) async {
    if (token?.cancelled ?? false) return const [];
    onProgress?.call(const ScanProgress(listing: true, done: 0, total: 0));
    try {
      final entries = await _listOhosDirectory();
      final known = index.scanFingerprint(key);
      final out = <_LocalWalkOut>[];
      for (final e in entries) {
        // fs.listFile(recursion) 返回以 / 开头的相对路径；库内 ref 约定与
        // Android 一致（无头形态），读取时由桥封装补回头部斜杠再拼 URI。
        final rel = e.rel.startsWith('/') ? e.rel.substring(1) : e.rel;
        final item = _diffSnapshotEntry(
          key: key,
          rel: rel,
          path: e.rel,
          size: e.size,
          mtime: e.mtime,
          minSizeBytes: options.minSizeBytes,
          known: known,
          emitted: out.length,
        );
        if (item == null) continue;
        out.add(item);
      }
      return out;
    } on PlatformException catch (e) {
      // 真实错误码带出（2026-10-07 修复：此前一律转译为「授权已失效」
      // 误导诊断——真机 hilog 显示实际为 13900002 ENOENT，根因是 ArkTS
      // 侧 URI 误用，已在平台桥修复；保留 code 便于后续定位）。授权被
      // 撤销（EPERM/激活失败）与目录被删/移动（ENOENT）补救方式相同：
      // 重新选择目录（场景 1.7）。
      debugPrint('[ohos] 扫描目录失败: $e');
      throw StateError('目录不可读（${e.code}），请编辑该源重新选择目录');
    }
  }

  // ---------- 直连播放 ----------

  /// 本地文件即本体，直接返回绝对路径走 `setFilePath`（无需经过 open 流）。
  /// ohos：授权目录 URI 先经桥解析沙箱真路径（openSync(uri).path），dart:io
  /// 能看到即进程内原生（mdk）可开——播放直连绕开 just_audio 本地代理
  /// （2026-10-07 修复：代理对死锁后 socket 事件通知 ~305µs 周期空转，
  /// ~2.9k HandleMessage/s 烧 ~1.5 核 CPU）；解析失败/路径不可见回退
  /// DirectAudioSource 字节流兜底（[open] → just_audio 本地代理 → fvp）。
  @override
  Future<String?> cachedFilePath(Song song) async {
    if (isOhos) {
      final path = await OhosPlatformBridge.resolvePath(rootPath, song.sourceRef);
      if (path == null) return null;
      return File(path).existsSync() ? path : null;
    }
    final path = _absPath(song.sourceRef);
    return File(path).existsSync() ? path : null;
  }

  /// 本地源的**原生解析可用路径**（R-2）：本体即本地文件，只要沙箱内可打开就
  /// 返回其真路径——**与离线缓存无关**（本地源本就无需「缓存登记」，旧判定把
  /// 「无缓存」误当「不可用」而错失原生解析）。语义与 [cachedFilePath] 在当前
  /// 实现下同源，但此处显式表达「原生可用性」而非「断网可播缓存」，避免未来
  /// 二者语义分化时再次误判。
  @override
  Future<String?> localSandboxPath(Song song) async {
    if (isOhos) {
      final path = await OhosPlatformBridge.resolvePath(rootPath, song.sourceRef);
      if (path == null) return null;
      return File(path).existsSync() ? path : null;
    }
    final path = _absPath(song.sourceRef);
    return File(path).existsSync() ? path : null;
  }

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    if (isOhos) return _openOhos(song, range);
    final file = File(_absPath(song.sourceRef));
    final len = await file.length();
    final start = range?.start ?? 0;
    final end = range == null
        ? len
        : (range.end == null ? len : (range.end! + 1).clamp(0, len));
    final contentLength = range == null ? len : (end - start);
    return OpenedStream(
      contentLength: contentLength,
      contentType: _mimeOf(_extOf(song.sourceRef)),
      stream: file.openRead(start, end),
      // 文件大小已知 → 调用方能精确判断范围读取有没有被截断。
      totalLength: len,
    );
  }

  /// ohos 播放读取：`song.fileSize` 为扫描时已知的文件大小（totalLength
  /// 无需额外 stat），512 KiB 分块 [OhosPlatformBridge.readRange] 拼流；
  /// MIME 复用 [_mimeOf]，范围/总长语义与其它分支一致（[IntRange.end] 为
  /// 闭区间）。元数据/封面/lrc 补读（DirectTaskQueue 经 open(range) 字节流）
  /// 同路径自动复用。
  OpenedStream _openOhos(Song song, IntRange? range) {
    final len = song.fileSize;
    if (len <= 0) {
      throw StateError('歌曲文件大小未知（扫描数据不完整），请重新扫描');
    }
    final start = range?.start ?? 0;
    final end = range == null
        ? len
        : (range.end == null ? len : (range.end! + 1).clamp(0, len));
    final contentLength = range == null ? len : (end - start);
    return OpenedStream(
      contentLength: contentLength,
      contentType: _mimeOf(_extOf(song.sourceRef)),
      stream: _ohosByteStream(song.sourceRef, start, end),
      totalLength: len,
    );
  }

  /// 按区间懒拉取授权目录字节（消费多少读多少，单块 512 KiB 满足起播与
  /// 拖动进度条场景；读取失败由流错误上抛，播放侧按打开失败处理）。
  Stream<Uint8List> _ohosByteStream(String ref, int start, int end) async* {
    const chunkBytes = 512 * 1024;
    var offset = start;
    while (offset < end) {
      final length = (end - offset) < chunkBytes ? end - offset : chunkBytes;
      yield await OhosPlatformBridge.readRange(
          rootPath, ref, offset, length);
      offset += length;
    }
  }

  @override
  Future<void> cacheSong(Song song, {bool Function()? shouldAbort}) async {
    // 本地文件本身即可离线播放，无需缓存。
  }

  // ---------- 直写管理（阶段6，本地直写；ohos 授权 URI 暂不支持写） ----------

  @override
  bool get supportsWrite => !isOhos;

  List<String> _guardParts(String ref) {
    final parts = ref.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.any((s) => s == '.' || s == '..')) {
      throw StateError('路径非法（路径穿越）：$ref');
    }
    return parts;
  }

  void _guardLeaf(String name) {
    if (name.isEmpty || name.contains('/') || name.contains('\\') || name.contains('..')) {
      throw StateError('文件名非法：$name');
    }
  }

  @override
  Future<void> uploadFile(String parentRef, String filename,
      Stream<List<int>> bytes, int length) async {
    if (isOhos) throw UnimplementedError('鸿蒙端暂不支持上传');
    _guardLeaf(filename);
    final dirParts = parentRef.isEmpty ? <String>[] : _guardParts(parentRef);
    final dir = Directory(p.joinAll([rootPath, ...dirParts]));
    if (!await dir.exists()) await dir.create(recursive: true);
    final dst = File(p.join(dir.path, filename));
    final sink = dst.openWrite();
    try {
      await sink.addStream(bytes);
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> deleteSong(Song song) async {
    if (isOhos) throw UnimplementedError('鸿蒙端暂不支持删除');
    final f = File(_absPath(song.sourceRef));
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> createFolder(String parentRef, String name) async {
    if (isOhos) throw UnimplementedError('鸿蒙端暂不支持新建文件夹');
    _guardLeaf(name);
    final dirParts = parentRef.isEmpty ? <String>[] : _guardParts(parentRef);
    final dir = Directory(p.joinAll([rootPath, ...dirParts, name]));
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  @override
  Future<void> close() async {}

  /// 本地文件由 [cachedFilePath] 直接返回路径走 `setFilePath`，无需 URL。
  @override
  DirectStream? directStream(Song song) => null;

  /// 本地源恒直连：不走代理。
  @override
  String? proxyOrigin(Song song) => null;

  @override
  Future<Map<String, String>> proxyAuthHeaders(Song song) async => const {};

  /// 本地文件无需预热：装载时读的是本地路径，不存在网络握手。
  @override
  Future<void> probe(Song song) async {}

  @override
  String displayPath(Song song) => _absPath(song.sourceRef);

  /// 将源内相对引用安全地拼到根目录（过滤 `..` 防止越界）。
  String _absPath(String ref) {
    final parts = ref
        .split('/')
        .where((s) => s.isNotEmpty && s != '.' && s != '..')
        .toList();
    return p.joinAll([rootPath, ...parts]);
  }

  // ---------- config ----------

  Map<String, String> get configJ => {
        'name': name,
        'path': rootPath,
      };

  String get configJson => jsonEncode(configJ);
}

// ---------- isolate worker（runScan entry） ----------

void _localWalkEntry(Map<String, Object?> msg) async {
  final params = msg['params']! as Map<String, Object?>;
  final send = msg['send']! as SendPort;
  final progress = msg['progress']! as SendPort;
  final cancelReq = ReceivePort();
  send.send({'__cancel__': cancelReq.sendPort});
  var cancelled = false;
  cancelReq.listen((_) => cancelled = true);
  try {
    final out = await _localWalk(
      key: params['key']! as String,
      root: params['root']! as String,
      minSizeBytes: params['minSizeBytes']! as int,
      known: (params['known']! as Map<Object?, Object?>)
          .map((k, v) => MapEntry(k as String, v as ScanFingerprint)),
      onProgress: (p) => progress.send(p),
      isCancelled: () => cancelled,
    );
    send.send(out);
  } catch (e) {
    // 隔离内异常以 {'__error__'} 回传主 isolate 转抛：worker 必须自行 catch，
    // 否则带 uncaught error 死掉后 runScan 干等 10 分钟超时。
    send.send({'__error__': e.toString()});
  } finally {
    cancelReq.close();
  }
}

class _LocalWalkOut {
  final DirectSongRow row;
  final Uint8List? cover;
  final _OutKind kind;
  const _LocalWalkOut(this.row, this.cover, this.kind);
}

enum _OutKind { added, updated, unchanged }

/// 进入 worker isolate：先枚举（stat 快照 + 指纹跳过），再并行读未变化文件头。
Future<List<_LocalWalkOut>> _localWalk({
  required String key,
  required String root,
  required int minSizeBytes,
  required Map<String, ScanFingerprint> known,
  void Function(ScanProgress)? onProgress,
  bool Function()? isCancelled,
}) async {
  final dir = Directory(root);
  if (!await dir.exists()) {
    throw StateError('本地目录不存在：$root');
  }
  // 快速：只建索引。枚举 + stat 拿到 rel/size/mtime 即落库，不打开任何音频文件。
  final out = <_LocalWalkOut>[];
  onProgress?.call(const ScanProgress(listing: true, done: 0, total: 0));
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (isCancelled?.call() ?? false) return out;
    if (entity is! File) continue;
    final path = entity.path;
    final rel = p.relative(path, from: root).replaceAll('\\', '/');
    // 后缀过滤前置（stat 前）：非音频文件跳过 stat，避免无谓 IO。
    if (!_audioExt(path)) continue;
    final stat = await entity.stat();
    // 「忽略音频」大小过滤：stat 已经带了 size，无需读文件。
    final mtime = stat.modified.millisecondsSinceEpoch ~/ 1000;
    final item = _diffSnapshotEntry(
      key: key,
      rel: rel,
      path: path,
      size: stat.size,
      mtime: mtime,
      minSizeBytes: minSizeBytes,
      known: known,
      emitted: out.length,
    );
    if (item == null) continue;
    out.add(item);
  }
  return out;
}

/// 快照 diff 公共纯函数（isolate 与 ohos 主 isolate 两条扫描路径共用）：
/// 音频后缀过滤 → minSize 过滤 → known 指纹比对 → 20000 上限保护。
///
/// 参数为单文件快照（rel/size/mtime）；[path] 仅用于后缀判断（ohos 传
/// 选择器返回的原始相对路径，isolate 传绝对路径，后缀语义等价）；
/// [emitted] 为已产出条目总数（含 unchanged，上限语义与 isolate 路径
/// 逐字节一致：总数 ≥20000 时新的 added/updated 抛异常）。
/// 返回 null 表示该文件被过滤；unchanged/added/updated 决策由 known 指纹
/// 驱动。
_LocalWalkOut? _diffSnapshotEntry({
  required String key,
  required String rel,
  required String path,
  required int size,
  required int mtime,
  required int minSizeBytes,
  required Map<String, ScanFingerprint> known,
  required int emitted,
}) {
  if (!_audioExt(path)) return null;
  if (minSizeBytes > 0 && size < minSizeBytes) return null;
  final fp = known[rel];
  if (fp != null && fp.same(size, mtime, null)) {
    return _LocalWalkOut(
      _rowFor(key, rel, _extOf(path), size, mtime),
      null,
      _OutKind.unchanged,
    );
  }
  if (emitted >= 20000) {
    throw StateError('单源超过 20000 首上限（DEVELOPER.md「客户端扫描与元数据」 大目录保护）');
  }
  return _LocalWalkOut(
    _rowFor(key, rel, _extOf(path), size, mtime),
    null,
    fp == null ? _OutKind.added : _OutKind.updated,
  );
}

DirectSongRow _rowFor(
    String key, String ref, String ext, int size, int mtime) {
  return DirectSongRow(
    sourceKey: key,
    ref: ref,
    title: fallbackTitle(ref),
    titleFromMeta: false,
    artist: null,
    album: null,
    albumArtist: null,
    trackNo: null,
    year: null,
    genre: null,
    duration: null,
    format: ext,
    size: size,
    mtime: mtime,
    coverPath: null,
  );
}

/// Android 运行时申请音频读取权限（13+ 用 audio，低版本回退 storage）。
Future<void> _ensureAudioPermission() async {
  if (!Platform.isAndroid) return;
  if (await Permission.audio.isGranted) return;
  if (await Permission.audio.request().isGranted) return;
  final storage = await Permission.storage.request();
  if (!storage.isGranted) {
    throw StateError('未授予音频读取权限，请在系统设置中允许后重试');
  }
}

bool _audioExt(String path) =>
    RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav|aif|aiff|aifc)$', caseSensitive: false)
        .hasMatch(path);

String _extOf(String path) {
  final i = path.lastIndexOf('.');
  return i >= 0 ? path.substring(i + 1).toLowerCase() : '';
}

String _mimeOf(String ext) {
  switch (ext) {
    case 'flac':
      return 'audio/flac';
    case 'm4a':
    case 'aac':
      return 'audio/mp4';
    case 'ogg':
      return 'audio/ogg';
    case 'wav':
      return 'audio/wav';
    case 'aif':
    case 'aiff':
    case 'aifc':
      return 'audio/aiff';
    default:
      return 'audio/mpeg';
  }
}