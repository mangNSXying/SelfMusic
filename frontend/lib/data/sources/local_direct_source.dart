import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../models/song.dart';
import 'music_source.dart';
import 'scan_worker.dart';
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

/// 本地文件夹直连源：扫描/播放本机目录（Linux 桌面 + Android 共享存储）。
///
/// - 扫描：[runScan] 驱动 worker isolate，先枚举（stat 快照），再按增量指纹跳过
///   快速：只建索引（枚举 + stat 即落库，不打开音频文件）；[ScanOptions] 只控制过滤。
/// - 播放：文件本身即本地，[cachedFilePath] 直接返回原路径走 setFilePath；
///   [open] 作为 Range 流式兜底。
/// - Android 读取共享存储需运行时权限（READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE），扫描前申请。
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
    final out = await runScan<List<_LocalWalkOut>>(
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

  // ---------- 直连播放 ----------

  /// 本地文件即本体，直接返回绝对路径走 `setFilePath`（无需经过 open 流）。
  @override
  Future<String?> cachedFilePath(Song song) async {
    final path = _absPath(song.sourceRef);
    return File(path).existsSync() ? path : null;
  }

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
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

  @override
  Future<void> cacheSong(Song song, {bool Function()? shouldAbort}) async {
    // 本地文件本身即可离线播放，无需缓存。
  }

  @override
  Future<void> close() async {}

  /// 本地文件由 [cachedFilePath] 直接返回路径走 `setFilePath`，无需 URL。
  @override
  DirectStream? directStream(Song song) => null;

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
    if (!_audioExt(path)) continue;
    final stat = await entity.stat();
    // 「忽略音频」大小过滤：stat 已经带了 size，无需读文件。
    if (minSizeBytes > 0 && stat.size < minSizeBytes) continue;
    final mtime = stat.modified.millisecondsSinceEpoch ~/ 1000;
    final fp = known[rel];
    if (fp != null && fp.same(stat.size, mtime, null)) {
      out.add(_LocalWalkOut(
        _rowFor(key, rel, _extOf(path), stat.size, mtime),
        null,
        _OutKind.unchanged,
      ));
      continue;
    }
    if (out.length >= 20000) {
      throw StateError('单源超过 20000 首上限（DESIGN §6.4 大目录保护）');
    }
    out.add(_LocalWalkOut(
      _rowFor(key, rel, _extOf(path), stat.size, mtime),
      null,
      fp == null ? _OutKind.added : _OutKind.updated,
    ));
  }
  return out;
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