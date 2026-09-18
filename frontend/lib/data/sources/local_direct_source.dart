import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../../models/song.dart';
import '../../models/album.dart';
import 'music_source.dart';
import '../local/local_index.dart';
import '../local/audio_metadata.dart';

/// 本地文件夹直连源：扫描/播放本机目录（Linux 桌面 + Android 共享存储）。
///
/// - 扫描：Isolate 内递归 [Directory.list] + 读文件头解析元数据，主 isolate 落库 [LocalIndex]。
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

  // ---------- 服务器模式接口（直连源不提供） ----------

  @override
  String? streamUrl(int songId) => null;

  @override
  Map<String, String>? streamHeaders() => null;

  @override
  Future<List<Song>> fetchSongs(
          {String? query, int page = 1, int size = 50}) async =>
      index.searchSongs(sourceKey: key, query: query, page: page, size: size);

  @override
  Future<List<Album>> fetchAlbums(
          {String? query, int page = 1, int size = 50}) async =>
      const [];

  @override
  Future<List<Song>> fetchAlbumSongs(int albumId) async => const [];

  @override
  Future<List<Song>> search(
          {String? query, int page = 1, int size = 100}) async =>
      index.searchSongs(sourceKey: key, query: query, page: page, size: size);

  // ---------- 直连扫描 ----------

  @override
  Future<ScanSummary> scan(
      {ScanOptions options = const ScanOptions.none()}) async {
    await _ensureAudioPermission();
    final srcKey = key;
    final root = rootPath;
    final coversDir = p.join(index.dir, 'covers');
    final minSize = options.minSizeBytes;
    final minDuration = options.minDurationSec;
    final out = await Isolate.run(
      () => _localWalk(
        key: srcKey,
        root: root,
        minSizeBytes: minSize,
        minDurationSec: minDuration,
      ),
    );
    final alive = <String>[];
    for (final item in out) {
      alive.add(item.row.ref);
      final coverPath = (item.cover == null || item.cover!.isEmpty)
          ? null
          : _persistCoverToDir(item.cover!, item.row.ref, coversDir);
      index.upsertSong(DirectSongRow(
        sourceKey: srcKey,
        ref: item.row.ref,
        title: item.row.title,
        artist: item.row.artist,
        album: item.row.album,
        trackNo: item.row.trackNo,
        year: item.row.year,
        genre: item.row.genre,
        duration: item.row.duration,
        format: item.row.format,
        size: item.row.size,
        mtime: item.row.mtime,
        coverPath: coverPath,
      ));
    }
    index.markMissingExcept(srcKey, alive);
    index.clearMissing(srcKey);
    return ScanSummary(added: out.length, updated: 0, total: out.length);
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

// ---------- helpers ----------

class _LocalWalkOut {
  final DirectSongRow row;
  final Uint8List? cover;
  const _LocalWalkOut(this.row, this.cover);
}

/// 进入 isolate：递归遍历本地目录 + 读文件头元数据，返回可落库行与封面字节。
Future<List<_LocalWalkOut>> _localWalk({
  required String key,
  required String root,
  required int minSizeBytes,
  required int minDurationSec,
}) async {
  final dir = Directory(root);
  if (!await dir.exists()) {
    throw StateError('本地目录不存在：$root');
  }
  final out = <_LocalWalkOut>[];
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final path = entity.path;
    if (!_audioExt(path)) continue;
    final stat = await entity.stat();
    if (minSizeBytes > 0 && stat.size < minSizeBytes) continue;
    final ext = _extOf(path);
    final rel = p.relative(path, from: root).replaceAll('\\', '/');
    final head = await _readHead(entity, 262144);
    final meta = head.isEmpty ? null : parseAudioHead(head, ext, stat.size);
    final dur = meta?.duration ?? 0;
    if (minDurationSec > 0 && dur > 0 && dur < minDurationSec) continue;
    out.add(_LocalWalkOut(
      DirectSongRow(
        sourceKey: key,
        ref: rel,
        title: meta?.title?.isNotEmpty == true
            ? meta!.title!
            : fallbackTitle(rel),
        artist: meta?.artist,
        album: meta?.album,
        trackNo: meta?.trackNo,
        year: meta?.year,
        genre: meta?.genre,
        duration: meta?.duration,
        format: ext,
        size: stat.size,
        mtime: stat.modified.millisecondsSinceEpoch ~/ 1000,
        coverPath: null,
      ),
      meta?.cover,
    ));
    if (out.length >= 20000) {
      throw StateError('单源超过 20000 首上限（DESIGN §6.4 大目录保护）');
    }
  }
  return out;
}

Future<Uint8List> _readHead(File f, int max) async {
  final raf = await f.open();
  try {
    final len = await raf.length();
    final n = len < max ? len : max;
    if (n <= 0) return Uint8List(0);
    return await raf.read(n);
  } finally {
    await raf.close();
  }
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

String? _persistCoverToDir(Uint8List cover, String ref, String coversDir) {
  try {
    final h = md5.convert(utf8.encode(ref)).toString();
    Directory(coversDir).createSync(recursive: true);
    final filePath = p.join(coversDir, '$h.jpg');
    File(filePath).writeAsBytesSync(cover, flush: true);
    return filePath;
  } catch (_) {
    return null;
  }
}

bool _audioExt(String path) =>
    RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav)$', caseSensitive: false)
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
    default:
      return 'audio/mpeg';
  }
}
