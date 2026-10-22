import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../models/song.dart';
import '../../platform/harmonyos/ohos_platform_bridge.dart';
import '../local/audio_metadata.dart';
import '../local/local_index.dart';
import 'music_source.dart';
import 'scan_worker.dart';

/// 文件级本地源的单个条目（持久化到源配置的 `files` 数组）。
class LocalFileEntry {
  final String ref;
  final String uri;
  final String name;
  final int size;
  final int mtime;

  const LocalFileEntry({
    required this.ref,
    required this.uri,
    required this.name,
    required this.size,
    required this.mtime,
  });

  Map<String, dynamic> toJson() => {
        'ref': ref,
        'uri': uri,
        'name': name,
        'size': size,
        'mtime': mtime,
      };

  static LocalFileEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ref = _str(raw['ref']).trim();
    final uri = _str(raw['uri']).trim();
    if (ref.isEmpty || uri.isEmpty) return null;
    final name = _str(raw['name']).trim();
    return LocalFileEntry(
      ref: ref,
      uri: uri,
      name: name.isEmpty ? ref : name,
      size: _int(raw['size']),
      mtime: _int(raw['mtime']),
    );
  }
}

/// 解析源配置中的文件清单；非文件模式/损坏项返回空或跳过。
List<LocalFileEntry> parseLocalFileEntries(Map<String, dynamic> cfg) {
  if (cfg['mode'] != 'files') return const [];
  final raw = cfg['files'];
  if (raw is! List) return const [];
  final out = <LocalFileEntry>[];
  final uris = <String>{};
  final refs = <String>{};
  for (final item in raw) {
    final e = LocalFileEntry.fromJson(item);
    if (e == null) continue;
    if (!uris.add(e.uri)) continue;
    var ref = e.ref;
    if (refs.contains(ref.toLowerCase())) {
      ref = uniqueLocalFileRef(ref, refs);
      if (ref.isEmpty) continue;
    } else {
      refs.add(ref.toLowerCase());
    }
    out.add(LocalFileEntry(
      ref: ref,
      uri: e.uri,
      name: e.name,
      size: e.size,
      mtime: e.mtime,
    ));
  }
  return out;
}

/// 生成文件级源配置段（不含 name/fallbacks，由 manager 组合）。
Map<String, dynamic> localFilesConfig(List<LocalFileEntry> files) => {
      'mode': 'files',
      'files': [for (final f in files) f.toJson()],
    };

/// 把新选择的文件合并到既有清单：按 URI 去重，重名 ref 追加 ` (2)`。
List<LocalFileEntry> mergePickedLocalFiles({
  required Iterable<LocalFileEntry> existing,
  required Iterable<OhosPickedFile> picked,
}) {
  final out = <LocalFileEntry>[...existing];
  final uris = {for (final e in out) e.uri};
  final refs = {for (final e in out) e.ref.toLowerCase()};
  for (final p in picked) {
    if (p.uri.isEmpty || !uris.add(p.uri)) continue;
    final name = p.name.trim().isEmpty ? _nameFromUri(p.uri) : p.name.trim();
    final ref = uniqueLocalFileRef(name, refs);
    if (ref.isEmpty) continue;
    out.add(LocalFileEntry(
      ref: ref,
      uri: p.uri,
      name: name,
      size: p.size,
      mtime: p.mtime,
    ));
  }
  return out;
}

/// 生成不与 [used]（小写 ref 集合）冲突的文件名；重名在扩展名前追加 ` (n)`。
///
/// 调用方需把返回值加入 [used]（本函数只在冲突时写入新 ref）。
String uniqueLocalFileRef(String name, Set<String> used) {
  var base = name.trim();
  if (base.isEmpty) return '';
  if (base == '.' || base == '..') base = 'audio';
  final dot = base.lastIndexOf('.');
  final stem = dot > 0 ? base.substring(0, dot) : base;
  final ext = dot > 0 ? base.substring(dot) : '';
  var candidate = base;
  var n = 2;
  while (used.contains(candidate.toLowerCase())) {
    candidate = '$stem ($n)$ext';
    n++;
  }
  used.add(candidate.toLowerCase());
  return candidate;
}

/// 文件级本地源：鸿蒙 6 手机/平板没有系统文件夹选择能力时的兼容形态。
///
/// 只保存用户多选导入的音频文件 URI（document URI，已持久化授权），扫描时
/// 逐 URI stat，播放走 [OhosPlatformBridge.resolveFileUriWithActivation] 的
/// 沙箱路径直连，失败回退 512 KiB 分块 [OhosPlatformBridge.readFileUriRange]。
///
/// 限制：文件清单平铺、不保留目录层级；同目录 `.lrc`/封面不在授权范围；
/// 单次最多选择 500 个（ArkTS 侧限制），单源仍受 20000 首上限保护。
class LocalFileDirectSource implements MusicSource {
  @override
  final String name;
  final List<LocalFileEntry> files;
  final LocalIndex index;

  LocalFileDirectSource({
    required this.name,
    required this.files,
    required this.index,
  });

  late final Map<String, LocalFileEntry> _byRef = {
    for (final f in files) f.ref: f,
  };

  late final Map<String, LocalFileEntry> _byUri = {
    for (final f in files) f.uri: f,
  };

  @override
  String get key => 'local:$name';

  @override
  SourceKind get kind => SourceKind.local;

  @override
  bool get supportsDirect => true;

  @override
  SourceRoute get route => SourceRoute.direct;

  @override
  Future<List<Song>> search(
          {String? query, int page = 1, int size = 100}) async =>
      index.searchSongs(sourceKey: key, query: query, page: page, size: size);

  @override
  Future<ScanSummary> scan(
      {ScanOptions options = const ScanOptions(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async {
    if (token?.cancelled ?? false) {
      return const ScanSummary(added: 0, updated: 0, total: 0, cancelled: true);
    }
    onProgress?.call(const ScanProgress(listing: true, done: 0, total: 0));
    final stats = await _statAll(token);
    if (files.isNotEmpty && (stats.isEmpty || stats.every((s) => !s.ok))) {
      throw StateError('文件授权已失效或文件已被移动，请编辑该源重新选择文件');
    }
    final known = index.scanFingerprint(key);
    final alive = <String>[];
    final toWrite = <DirectSongRow>[];
    var added = 0, updated = 0, unchanged = 0;
    for (final stat in stats) {
      if (token?.cancelled ?? false) break;
      if (!stat.ok) continue;
      final entry = _entryByUri(stat.uri);
      if (entry == null) continue;
      if (options.minSizeBytes > 0 && stat.size < options.minSizeBytes) {
        continue;
      }
      final fp = known[entry.ref];
      final kind = fp == null
          ? _FileOutKind.added
          : (fp.same(stat.size, stat.mtime, null)
              ? _FileOutKind.unchanged
              : _FileOutKind.updated);
      if (kind != _FileOutKind.unchanged && alive.length >= 20000) {
        throw StateError('单源超过 20000 首上限（DEVELOPER.md「客户端扫描与元数据」 大目录保护）');
      }
      alive.add(entry.ref);
      switch (kind) {
        case _FileOutKind.unchanged:
          unchanged++;
          break;
        case _FileOutKind.added:
          added++;
          break;
        case _FileOutKind.updated:
          updated++;
          break;
      }
      if (kind == _FileOutKind.unchanged) continue;
      toWrite.add(_rowFor(entry, stat.size, stat.mtime));
    }
    // 取消时不能把未遍历到的清单项标记为 missing：本轮不提交任何 diff。
    if (token?.cancelled ?? false) {
      return const ScanSummary(
        added: 0,
        updated: 0,
        total: 0,
        cancelled: true,
      );
    }
    await index.upsertSongs(toWrite);
    await index.markMissingExcept(key, alive);
    await index.clearMissing(key);
    return ScanSummary(
      added: added,
      updated: updated,
      unchanged: unchanged,
      total: alive.length,
      cancelled: token?.cancelled ?? false,
    );
  }

  Future<List<OhosFileStat>> _statAll(ScanToken? token) async {
    final uris = [for (final f in files) f.uri];
    if (uris.isEmpty) return const [];
    try {
      // 会话内临时授权可能仍可用；激活失败不阻断 stat，由 stat 的真实
      // 错误码决定文件是否可用（与目录源「先枚举再激活重试」语义一致）。
      await OhosPlatformBridge.ensureUrisActivated(
          token?.cancelled ?? false ? const [] : uris);
      return await OhosPlatformBridge.statFileUris(uris);
    } on PlatformException catch (e) {
      debugPrint('[local-files] stat 失败: $e');
      throw StateError('文件不可读（${e.code}），请编辑该源重新选择文件');
    } on MissingPluginException catch (e) {
      debugPrint('[local-files] stat 桥未装配: $e');
      throw StateError('当前平台不支持文件级本地源');
    }
  }

  LocalFileEntry? _entryByUri(String uri) => _byUri[uri];

  DirectSongRow _rowFor(LocalFileEntry e, int size, int mtime) => DirectSongRow(
        sourceKey: key,
        ref: e.ref,
        title: fallbackTitle(e.ref),
        titleFromMeta: false,
        format: _extOf(e.ref),
        size: size,
        mtime: mtime,
        coverPath: null,
      );

  @override
  Future<String?> cachedFilePath(Song song) => _sandboxPath(song);

  @override
  Future<String?> localSandboxPath(Song song) => _sandboxPath(song);

  Future<String?> _sandboxPath(Song song) async {
    final entry = _byRef[song.sourceRef];
    if (entry == null) return null;
    final path =
        await OhosPlatformBridge.resolveFileUriWithActivation(entry.uri);
    if (path == null) return null;
    return File(path).existsSync() ? path : null;
  }

  @override
  Future<OpenedStream> open(Song song, {IntRange? range}) async {
    final entry = _byRef[song.sourceRef];
    if (entry == null) {
      throw StateError('文件不在该源清单中，请重新选择文件');
    }
    await OhosPlatformBridge.ensureUrisActivated([entry.uri]);
    final len = song.fileSize > 0 ? song.fileSize : entry.size;
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
      stream: _byteStream(entry.uri, start, end),
      totalLength: len,
    );
  }

  Stream<Uint8List> _byteStream(String uri, int start, int end) async* {
    const chunkBytes = 512 * 1024;
    var offset = start;
    while (offset < end) {
      final length = (end - offset) < chunkBytes ? end - offset : chunkBytes;
      yield await OhosPlatformBridge.readFileUriRange(uri, offset, length);
      offset += length;
    }
  }

  @override
  Future<void> cacheSong(Song song, {bool Function()? shouldAbort}) async {}

  @override
  bool get supportsWrite => false;

  @override
  Future<void> uploadFile(String parentRef, String filename,
          Stream<List<int>> bytes, int length) async =>
      throw UnimplementedError('文件级本地源不支持上传');

  @override
  Future<void> uploadSidecar(String parentRef, String filename,
          Stream<List<int>> bytes, int length) async =>
      throw UnimplementedError('文件级本地源不支持上传 sidecar');

  @override
  Future<void> deleteSong(Song song) async =>
      throw UnimplementedError('文件级本地源不支持删除');

  @override
  Future<void> deleteSidecar(String parentRef, String filename) async =>
      throw UnimplementedError('文件级本地源不支持删除 sidecar');

  @override
  Future<void> createFolder(String parentRef, String name) async =>
      throw UnimplementedError('文件级本地源不支持新建文件夹');

  @override
  Future<void> close() async {}

  @override
  DirectStream? directStream(Song song) => null;

  @override
  String? proxyOrigin(Song song) => null;

  @override
  Future<Map<String, String>> proxyAuthHeaders(Song song) async => const {};

  @override
  Future<void> probe(Song song) async {}

  @override
  String displayPath(Song song) =>
      _byRef[song.sourceRef]?.uri ?? song.sourceRef;

  String get configJson => jsonEncode(localFilesConfig(files));
}

enum _FileOutKind { added, updated, unchanged }

String _str(Object? v) => v is String ? v : '';

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return 0;
}

String _nameFromUri(String uri) {
  var s = uri;
  final q = s.indexOf('?');
  if (q >= 0) s = s.substring(0, q);
  final h = s.indexOf('#');
  if (h >= 0) s = s.substring(0, h);
  final i = s.lastIndexOf('/');
  final raw = i >= 0 ? s.substring(i + 1) : s;
  try {
    return Uri.decodeComponent(raw);
  } catch (_) {
    return raw;
  }
}

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
