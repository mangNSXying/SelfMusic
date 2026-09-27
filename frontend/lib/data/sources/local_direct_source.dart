import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../models/song.dart';
import 'music_source.dart';
import 'scan_worker.dart';
import 'sibling_cover.dart';
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

/// 本地文件夹直连源：扫描/播放本机目录（Linux 桌面 + Android 共享存储）。
///
/// - 扫描：[runScan] 驱动 worker isolate，先枚举（stat 快照），再按增量指纹跳过
///   未变化文件的读头；[ScanOptions] 控制 快速模式 / 最小元数据 / 头部大小。
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
      {ScanOptions options = const ScanOptions.none(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async {
    await _ensureAudioPermission();
    final out = await runScan<List<_LocalWalkOut>>(
      entry: _localWalkEntry,
      params: <String, Object?>{
        'key': key,
        'root': rootPath,
        'minSizeBytes': options.minSizeBytes,
        'minDurationSec': options.minDurationSec,
        'headBytes': options.headBytes,
        'fullMeta': options.fullMeta,
        'fast': options.fast,
        'collectCover': options.collectCover,
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
      final coverPath = (item.cover == null || item.cover!.isEmpty ||
              !options.collectCover)
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
    );
  }

  @override
  Future<void> cacheSong(Song song) async {
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
      minDurationSec: params['minDurationSec']! as int,
      headBytes: params['headBytes']! as int,
      fullMeta: params['fullMeta']! as bool,
      fast: params['fast']! as bool,
      collectCover: params['collectCover']! as bool,
      known: (params['known']! as Map<Object?, Object?>)
          .map((k, v) => MapEntry(k as String, v as ScanFingerprint)),
      onProgress: (p) => progress.send(p),
      isCancelled: () => cancelled,
    );
    send.send(out);
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
  required int minDurationSec,
  required int headBytes,
  required bool fullMeta,
  required bool fast,
  required bool collectCover,
  required Map<String, ScanFingerprint> known,
  void Function(ScanProgress)? onProgress,
  bool Function()? isCancelled,
}) async {
  final dir = Directory(root);
  if (!await dir.exists()) {
    throw StateError('本地目录不存在：$root');
  }
  // 阶段 1：枚举 + stat，产出「需要探测」的文件与「未变化」的条目；
  // 同时收集同目录图片（封面回退用，按小写相对路径索引）。
  final toProbe = <_LocalCandidate>[];
  final imageRefs = <String, String>{}; // rel(小写) → 绝对路径
  final out = <_LocalWalkOut>[];
  onProgress?.call(const ScanProgress(listing: true, done: 0, total: 0));
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (isCancelled?.call() ?? false) return out;
    if (entity is! File) continue;
    final path = entity.path;
    final rel = p.relative(path, from: root).replaceAll('\\', '/');
    if (_imageExt(path)) {
      imageRefs.putIfAbsent(rel.toLowerCase(), () => path);
      continue;
    }
    if (!_audioExt(path)) continue;
    final stat = await entity.stat();
    if (minSizeBytes > 0 && stat.size < minSizeBytes) continue;
    final ext = _extOf(path);
    final fp = known[rel];
    final mtime = stat.modified.millisecondsSinceEpoch ~/ 1000;
    if (fp != null && fp.same(stat.size, mtime, null)) {
      out.add(_LocalWalkOut(
        _rowFor(key, rel, ext, stat.size, mtime, null, fullMeta, false),
        null,
        _OutKind.unchanged,
      ));
      continue;
    }
    if (fast) {
      out.add(_LocalWalkOut(
        _rowFor(key, rel, ext, stat.size, mtime, null, fullMeta, true),
        null,
        fp == null ? _OutKind.added : _OutKind.updated,
      ));
      continue;
    }
    toProbe.add(_LocalCandidate(path, rel, ext, stat.size, mtime));
    if (out.length + toProbe.length >= 20000) {
      throw StateError('单源超过 20000 首上限（DESIGN §6.4 大目录保护）');
    }
  }
  if (isCancelled?.call() ?? false) return out;
  onProgress?.call(ScanProgress(listing: false, done: 0, total: toProbe.length));
  // 阶段 2：读头 + 解析（本地磁盘并行 4，解析 CPU 也在 worker 内完成）。
  var done = 0;
  final imageBytes = <String, Uint8List?>{}; // 图片绝对路径 → 字节/null
  await _mapConcurrent(toProbe, 4, (c) async {
    if (isCancelled?.call() ?? false) return;
    AudioMeta? meta;
    if (!fullMeta) {
      try {
        final head = await _readHeadAt(c.path, 0, headBytes);
        if (head.isEmpty) return;
        meta = parseMinimalHead(head, c.ext);
      } catch (_) {
        return; // 单文件失败跳过（不中断整源扫描）
      }
    } else {
      // 完整模式：头部补读（大封面）+ 尾部补读（m4a moov-at-end / ogg 时长）+ 同目录图片回退。
      try {
        meta = await readAudioMeta(
          readRange: (start, length) => _readHeadAt(c.path, start, length),
          format: c.ext,
          fileSize: c.size,
          headBytes: headBytes,
        );
      } catch (_) {
        return;
      }
      if (meta == null) return;
      if (!collectCover) {
        meta.cover = null;
      } else {
        meta.cover ??= await _siblingImageLocal(c.rel, imageRefs, imageBytes);
      }
    }
    final dur = meta?.duration ?? 0;
    if (minDurationSec > 0 && dur > 0 && dur < minDurationSec) return;
    final outKind =
        known[c.rel] == null ? _OutKind.added : _OutKind.updated;
    out.add(_LocalWalkOut(
      _rowFor(key, c.rel, c.ext, c.size, c.mtime, meta, fullMeta, false),
      meta?.cover,
      outKind,
    ));
    done++;
    onProgress?.call(
        ScanProgress(listing: false, done: done, total: toProbe.length));
  });
  return out;
}

/// 扫描期同目录图片回退：从同批枚举的图片清单中按候选顺序命中并读入（按路径缓存）。
Future<Uint8List?> _siblingImageLocal(String ref,
    Map<String, String> imageRefs, Map<String, Uint8List?> cache) async {
  for (final cand in siblingImageCandidates(ref)) {
    final path = imageRefs[cand.toLowerCase()];
    if (path == null) continue;
    if (cache.containsKey(path)) {
      final hit = cache[path];
      if (hit != null) return hit;
      continue;
    }
    try {
      final bytes = await _readHeadAt(path, 0, kCoverReadCapBytes);
      if (isImageBytes(bytes)) {
        cache[path] = bytes;
        return bytes;
      }
      cache[path] = null;
    } catch (_) {
      cache[path] = null;
    }
  }
  return null;
}

class _LocalCandidate {
  final String path;
  final String rel;
  final String ext;
  final int size;
  final int mtime;
  const _LocalCandidate(this.path, this.rel, this.ext, this.size, this.mtime);
}

DirectSongRow _rowFor(String key, String ref, String ext, int size, int mtime,
    AudioMeta? meta, bool fullMeta, bool fast) {
  final titleFromMeta = !fast && (meta?.title?.isNotEmpty ?? false);
  final title = titleFromMeta ? meta!.title! : fallbackTitle(ref);
  return DirectSongRow(
    sourceKey: key,
    ref: ref,
    title: title,
    titleFromMeta: titleFromMeta,
    artist: meta?.artist,
    album: meta?.album,
    albumArtist: meta?.albumArtist,
    trackNo: fullMeta && !fast ? meta?.trackNo : null,
    year: fullMeta && !fast ? meta?.year : null,
    genre: fullMeta && !fast ? meta?.genre : null,
    duration: fullMeta && !fast ? meta?.duration : null,
    format: ext,
    size: size,
    mtime: mtime,
    coverPath: null,
  );
}

Future<Uint8List> _readHeadAt(String path, int start, int length) async {
  final raf = await File(path).open();
  try {
    final len = await raf.length();
    if (start >= len || length <= 0) return Uint8List(0);
    final end = (start + length) > len ? len : start + length;
    await raf.setPosition(start);
    return await raf.read(end - start);
  } finally {
    await raf.close();
  }
}

/// 有界并发（顺序保序；任务返回后释放槽位）。
Future<void> _mapConcurrent<T>(
    List<T> items, int pool, Future<void> Function(T) fn) async {
  if (items.isEmpty) return;
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      await fn(items[i]);
    }
  }
  await Future.wait([for (var i = 0; i < pool; i++) worker()]);
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
    RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav)$', caseSensitive: false)
        .hasMatch(path);

bool _imageExt(String path) =>
    RegExp(r'\.(jpg|jpeg|png|webp)$', caseSensitive: false).hasMatch(path);

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
    default:
      return 'audio/mpeg';
  }
}