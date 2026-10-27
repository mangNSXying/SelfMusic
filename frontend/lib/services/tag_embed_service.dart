/// 内嵌编排器（纯前端直连源，不经服务端）：远端 GET 整首→本地改→验签→
/// PUT 覆盖→复验→清 sidecar→刷指纹；本地同目录 tmp+rename 原子替换。
///
/// 前置：直连歌 + 源 supportsWrite + DB 有歌词或封面；同曲在播由调用方经
/// [embedSong] 的 `beforeWrite` 钩子在写盘前自动暂停（写完后恢复）。失败
/// 一律抛错（调用方 toast），源文件只在“改完且验签通过”后才被触碰；
/// PUT 失败/复验失败用本地 .bak 还原。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../data/local/app_settings.dart';
import '../data/local/audio_metadata.dart';
import '../data/local/audio_tag_writer.dart';
import '../data/local/local_index.dart';
import '../data/sources/music_source.dart';
import '../models/song.dart';
import 'online_meta/online_meta_service.dart';

/// 嵌入阶段（进度对话框展示用）。
enum EmbedPhase {
  downloading('下载原文件'),
  embedding('写入标签'),
  verifying('验签'),
  uploading('上传回源'),
  verifyingRemote('复验'),
  cleaning('清理');

  const EmbedPhase(this.label);
  final String label;
}

/// 进度回调：[fraction] 为 0~1（改/验阶段为 null，表示不定）。
typedef EmbedProgressCallback = void Function(
    EmbedPhase phase, double? fraction);

class TagEmbedService {
  final LocalIndex index;
  final AppSettings settings;

  TagEmbedService({required this.index, required this.settings});

  /// 该歌是否有可嵌入内容（DB 歌词非空，或封面文件存在且完整）。
  /// 返回 null 表示无内容。
  Future<({String? lyrics, Uint8List? coverBytes})?> embeddableContent(
      Song song) async {
    final rawLyrics = index.lyricsOf(song.sourceKey, song.sourceRef);
    final lyrics =
        (rawLyrics != null && rawLyrics.trim().isNotEmpty) ? rawLyrics : null;
    Uint8List? cover;
    final path = index.songByRef(song.sourceKey, song.sourceRef)?.coverPath ??
        song.coverPath;
    if (path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          if (isCompleteImageBytes(bytes)) cover = bytes;
        }
      } catch (_) {}
    }
    if (lyrics == null && cover == null) return null;
    return (lyrics: lyrics, coverBytes: cover);
  }

  static String parentOf(String ref) {
    final slash = ref.lastIndexOf('/');
    if (slash <= 0) return '';
    return ref.substring(0, slash);
  }

  static String leafOf(String ref) {
    final slash = ref.lastIndexOf('/');
    return slash < 0 ? ref : ref.substring(slash + 1);
  }

  /// 执行嵌入（见文件头流程）。[shouldAbort] 在下载循环与落盘前轮询
  /// （PUT 一旦发起不再中断，取消在整传完成后还原处理）。
  /// [beforeWrite] 在**触碰源文件之前**（本地 rename / 远端 PUT 前）等待，
  /// 供调用方暂停正在播放的同曲；恢复由调用方在流程结束后自行处理。
  Future<void> embedSong(
    Song song,
    MusicSource src, {
    EmbedProgressCallback? onProgress,
    bool Function()? shouldAbort,
    Future<void> Function()? beforeWrite,
  }) async {
    void checkAborted() {
      if (shouldAbort?.call() ?? false) {
        throw const PreloadAbortedException();
      }
    }

    if (!song.isDirect) throw StateError('服务端歌曲没有文件，无法嵌入');
    if (!src.supportsWrite) throw StateError('该源不支持写入，无法嵌入');
    final content = await embeddableContent(song);
    if (content == null) {
      throw StateError('没有可嵌入的内容（歌词与封面均无）');
    }
    final isLocal = src.kind == SourceKind.local;

    // 工作目录：本地用目标同目录（rename 原子性要求同 fs），远端用系统 tmp。
    final stageDir = isLocal
        ? p.dirname(await _requireLocalPath(src, song))
        : Directory.systemTemp.path;
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final tmpIn = p.join(stageDir, '.selfmusic-embed-$stamp-in.tmp');
    final tmpOut = p.join(stageDir, '.selfmusic-embed-$stamp-out.tmp');
    final bak = p.join(stageDir, '.selfmusic-embed-$stamp.bak');
    try {
      // ---- 1. 取原文件 + 备份
      if (isLocal) {
        final orig = await _requireLocalPath(src, song);
        await File(orig).copy(bak);
        await File(orig).copy(tmpIn);
      } else {
        onProgress?.call(EmbedPhase.downloading, 0);
        final opened = await src.open(song);
        final total = opened.totalLength ?? song.fileSize;
        final sink = File(tmpIn).openWrite();
        var got = 0;
        try {
          await for (final chunk in opened.stream) {
            checkAborted();
            sink.add(chunk);
            got += chunk.length;
            if (total > 0) {
              onProgress?.call(
                  EmbedPhase.downloading, (got / total).clamp(0.0, 1.0));
            }
          }
        } finally {
          await sink.close();
        }
        if (total > 0 && got < total) {
          throw StateError('下载被截断（$got/$total 字节），已放弃');
        }
        await File(tmpIn).copy(bak);
      }
      checkAborted();
      // ---- 2. 改
      onProgress?.call(EmbedPhase.embedding, null);
      final r = await embedAudioTags(
        srcPath: tmpIn,
        dstPath: tmpOut,
        format: formatOf(song),
        lyrics: content.lyrics,
        coverBytes: content.coverBytes,
      );
      // ---- 3. 验（读侧全路径重读 tmp 产物）
      onProgress?.call(EmbedPhase.verifying, null);
      await _verifyEmbedded(tmpOut, song,
          wantLyrics: r.lyricsEmbedded, wantCover: r.coverEmbedded);
      checkAborted();
      // ---- 4. 落盘（写前钩子：调用方在此暂停正在播放的同曲并等落地）
      await beforeWrite?.call();
      checkAborted();
      if (isLocal) {
        final orig = await _requireLocalPath(src, song);
        await File(tmpOut).rename(orig);
      } else {
        onProgress?.call(EmbedPhase.uploading, 0);
        final parent = parentOf(song.sourceRef);
        final leaf = leafOf(song.sourceRef);
        final bytes = await File(tmpOut).readAsBytes();
        var sent = 0;
        // PUT 一旦发起就不得中途掐断（半截上传会给源站留坏文件且无法
        // 事后还原）；取消请求在整传完成后统一处理：回传备份还原。
        Stream<List<int>> chunks() async* {
          while (sent < bytes.length) {
            final n = (bytes.length - sent) < 1048576
                ? bytes.length - sent
                : 1048576;
            yield bytes.sublist(sent, sent + n);
            sent += n;
            onProgress?.call(
                EmbedPhase.uploading, (sent / bytes.length).clamp(0.0, 1.0));
          }
        }

        await src.uploadFile(parent, leaf, chunks(), bytes.length);
        if (shouldAbort?.call() ?? false) {
          // 整传完成后才发现取消：回传原文件，保持源站与取消前一致。
          await _restoreRemote(src, parent, leaf, bak);
          throw const PreloadAbortedException();
        }
        // ---- 5. 复验：头+尾确认新标签已生效；失败还原备份。
        onProgress?.call(EmbedPhase.verifyingRemote, null);
        if (!await _remoteOk(src, song, await File(tmpOut).length(),
            wantLyrics: r.lyricsEmbedded, wantCover: r.coverEmbedded)) {
          await _restoreRemote(src, parent, leaf, bak);
          throw StateError('上传后复验失败，已还原原文件');
        }
      }
      // ---- 6. 收尾：删 sidecar + 刷指纹
      onProgress?.call(EmbedPhase.cleaning, null);
      final online = OnlineMetaService(index: index, settings: settings);
      await online.deleteSidecars(song, src);
      await _deleteCustomLyricSidecar(song, src);
      if (isLocal) {
        final st = await File(await _requireLocalPath(src, song)).stat();
        await index.updateFileFingerprint(song.sourceKey, song.sourceRef,
            st.size, st.modified.millisecondsSinceEpoch ~/ 1000);
      } else {
        await index.updateFileFingerprint(song.sourceKey, song.sourceRef,
            await File(tmpOut).length(),
            DateTime.now().millisecondsSinceEpoch ~/ 1000);
      }
    } finally {
      for (final t in [tmpIn, tmpOut, bak]) {
        try {
          final f = File(t);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  Future<String> _requireLocalPath(MusicSource src, Song song) async {
    final path = await src.localSandboxPath(song);
    if (path == null || path.isEmpty) throw StateError('本地文件不可达');
    return path;
  }

  /// 远端还原：把本地备份整文件回传（复验失败 / 上传后取消共用）。
  Future<void> _restoreRemote(
      MusicSource src, String parent, String leaf, String bak) async {
    final bakBytes = await File(bak).readAsBytes();
    await src.uploadFile(parent, leaf, Stream.value(bakBytes), bakBytes.length);
  }

  /// 验签：读侧全路径重读嵌入产物（标题/时长 sanity + 歌词/封面 presence）。
  Future<void> _verifyEmbedded(String path, Song song,
      {required bool wantLyrics, required bool wantCover}) async {
    final fmt = formatOf(song);
    final f = File(path);
    final size = await f.length();
    Future<Uint8List> readRange(int start, int length) async {
      final raf = await f.open();
      try {
        await raf.setPosition(start);
        final out = BytesBuilder();
        var rest = length;
        while (rest > 0) {
          final c = await raf.read(rest > 65536 ? 65536 : rest);
          if (c.isEmpty) break;
          out.add(c);
          rest -= c.length;
        }
        return out.takeBytes();
      } finally {
        await raf.close();
      }
    }

    final meta = await readAudioMeta(
        readRange: readRange, format: fmt, fileSize: size);
    if (meta == null) throw StateError('嵌入后文件无法解析，拒绝覆盖');
    if (wantLyrics && (meta.lyrics == null || meta.lyrics!.trim().isEmpty)) {
      throw StateError('嵌入后验签失败：歌词未写入');
    }
    if (wantCover && (meta.cover == null || meta.cover!.isEmpty)) {
      throw StateError('嵌入后验签失败：封面未写入');
    }
    if ((meta.title == null || meta.title!.isEmpty) && meta.duration == null) {
      throw StateError('嵌入后验签失败：文件已损坏（标题/时长全无）');
    }
  }

  /// 复验（远端 PUT 后）：直接复用读侧全路径（头阶梯＋尾），与本地验签
  /// 同口径——固定 256KB 头会在新封面较大时截断误判。
  Future<bool> _remoteOk(MusicSource src, Song song, int fileSize,
      {required bool wantLyrics, required bool wantCover}) async {
    try {
      Future<Uint8List> readRange(int start, int length) async {
        final probe = await src.open(song, range: IntRange(start, length));
        final buf = <int>[];
        await for (final chunk in probe.stream) {
          buf.addAll(chunk);
          if (buf.length >= length) break;
        }
        return Uint8List.fromList(buf);
      }

      final meta = await readAudioMeta(
          readRange: readRange, format: formatOf(song), fileSize: fileSize);
      if (meta == null) return false;
      if (wantLyrics && (meta.lyrics == null || meta.lyrics!.trim().isEmpty)) {
        return false;
      }
      if (wantCover && (meta.cover == null || meta.cover!.isEmpty)) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _deleteCustomLyricSidecar(Song song, MusicSource src) async {
    try {
      final dir = settings.onlineMetaLyricDir.trim();
      if (dir.isEmpty || src.kind != SourceKind.local) return;
      final stem = leafOf(song.sourceRef);
      final dot = stem.lastIndexOf('.');
      final base = dot > 0 ? stem.substring(0, dot) : stem;
      for (final leaf in ['$base.lrc', '$base.LRC']) {
        try {
          final f = File(p.join(dir, leaf));
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 嵌入引擎支持的容器（与 [embedAudioTags] 的 switch 对齐）。
  static const Set<String> kEmbedFormats = {
    'mp3', 'flac', 'wav', 'aiff', 'aif', 'aifc', 'm4a', 'mp4',
  };

  static String formatOf(Song song) {
    final ref = song.sourceRef;
    final dot = ref.lastIndexOf('.');
    final fromRef = dot >= 0 ? ref.substring(dot + 1).toLowerCase() : '';
    final f = (song.format ?? '').toLowerCase();
    return f.isNotEmpty ? f : fromRef;
  }

  /// 该歌容器是否支持标签内嵌（保存前预检；不支持的退化为仅应用缓存）。
  static bool supportsFormat(Song song) =>
      kEmbedFormats.contains(formatOf(song));
}
