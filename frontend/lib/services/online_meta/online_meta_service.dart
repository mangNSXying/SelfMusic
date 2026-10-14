import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../data/local/app_settings.dart';
import '../../data/local/audio_metadata.dart';
import '../../data/local/local_index.dart';
import '../../data/sources/music_source.dart';
import '../../models/song.dart';
import 'lrclib_provider.dart';
import 'musicbrainz_cover_provider.dart';
import 'online_meta_models.dart';
import 'string_sim.dart';

/// 在线元数据门面（纯前端）：LRCLIB 歌词 + MB 录音搜索 + CAA 封面。
///
/// 保存口径（设置项 `online_meta_save_mode`，默认 `app_cache`）：
/// - `app_cache`：只写 `song_lyrics` / `covers/<md5>.jpg`（全源安全）；
/// - `sidecar`：额外写回源目录（P0：同名均覆盖）——歌词写同目录 `<stem>.lrc`
///   （自定义歌词目录仅本地有效），封面写同目录 `cover.jpg`（专辑级：同目录
///   多首歌共享一张，杂烩目录后写覆盖先写）；远端源经各源 `uploadFile`
///   直写（播放读链路同路，不经服务端代理，无多余流量）；无真路径
///   （服务端歌/远端未解析）时跳过，不报错。
/// 内嵌回写暂不支持（Dart 无 taglib 等价实现，风险高，UI 置灰说明）；
/// 嵌入引擎落地后，`deleteSidecars` 供“嵌入后删 sidecar”调用。
class OnlineMetaService {
  /// 专辑级封面 sidecar 文件名（与 `sibling_cover` 首个通用候选对齐）。
  static const String kCoverSidecarName = 'cover.jpg';
  final LocalIndex index;
  final AppSettings settings;
  final LrclibProvider lrclib;
  final MusicBrainzCoverProvider mbCover;

  OnlineMetaService({
    required this.index,
    required this.settings,
    LrclibProvider? lrclibProvider,
    MusicBrainzCoverProvider? mbCoverProvider,
    Dio? dio,
  })  : lrclib = lrclibProvider ?? LrclibProvider(dio: dio),
        mbCover = mbCoverProvider ?? MusicBrainzCoverProvider();

  // ---------- 搜索 ----------

  /// 歌词搜索：精确 + 模糊合并去重，按 MusicPlayer2 权重排序。
  Future<List<OnlineLyricCandidate>> searchLyrics(
    Song song, {
    String? titleOverride,
    String? artistOverride,
    String? albumOverride,
  }) async {
    final title = (titleOverride ?? song.title).trim();
    final artist = (artistOverride ?? (song.artist ?? '')).trim();
    final album = (albumOverride ?? (song.albumName ?? '')).trim();
    if (title.isEmpty) return const [];
    final filename = _stemOf(song.sourceRef);

    final merged = <int, OnlineLyricCandidate>{};
    // 精确优先（duration 辅助匹配）。
    try {
      final exact = await lrclib.fetchExact(
        artist: artist,
        track: title,
        album: album.isEmpty ? null : album,
        durationSec: song.duration,
      );
      if (exact != null && exact.hasContent) merged[exact.id] = exact;
    } catch (_) {
      // 精确失败不阻断模糊搜索。
    }
    final kw = artist.isEmpty ? title : '$artist $title';
    try {
      final list = await lrclib.search(
        query: kw,
        track: title,
        artist: artist.isEmpty ? null : artist,
        album: album.isEmpty ? null : album,
      );
      for (final c in list) {
        merged.putIfAbsent(c.id, () => c);
      }
    } catch (_) {
      if (merged.isEmpty) rethrow;
    }

    final out = <OnlineLyricCandidate>[];
    var i = 0;
    for (final c in merged.values) {
      final w = matchWeight(
        title: title,
        artist: artist,
        album: album,
        candidateTitle: c.trackName,
        candidateArtist: c.artistName,
        candidateAlbum: c.albumName,
        filename: filename,
        index: i++,
      );
      // 时长加成：LRCLIB 自带 duration，与本地差 ≤2s 视为强信号。
      var bonus = 0.0;
      if (song.duration != null &&
          song.duration! > 0 &&
          c.durationSec != null &&
          c.durationSec! > 0) {
        final d = (song.duration! - c.durationSec!).abs();
        if (d <= 2) {
          bonus = 0.08;
        } else if (d <= 5) {
          bonus = 0.03;
        } else if (d > 30) {
          bonus = -0.05;
        }
      }
      out.add(c.withWeight(w + bonus));
    }
    out.sort((a, b) => b.matchWeight.compareTo(a.matchWeight));
    return out;
  }

  /// 录音搜索（封面链第一步）：返回带权重的 MB 候选。
  Future<List<MbRecordingCandidate>> searchRecordings(
    Song song, {
    String? titleOverride,
    String? artistOverride,
  }) async {
    final title = (titleOverride ?? song.title).trim();
    final artist = (artistOverride ?? (song.artist ?? '')).trim();
    if (title.isEmpty) return const [];
    final filename = _stemOf(song.sourceRef);
    final list =
        await mbCover.searchRecording(title: title, artist: artist.isEmpty ? null : artist);
    final out = <MbRecordingCandidate>[];
    for (var i = 0; i < list.length; i++) {
      final c = list[i];
      final w = matchWeight(
        title: title,
        artist: artist,
        album: song.albumName ?? '',
        candidateTitle: c.title,
        candidateArtist: c.artist,
        candidateAlbum: c.releaseTitle ?? '',
        filename: filename,
        index: i,
      );
      // MB 自带检索分（0-100）折 0-0.05 加成。
      final mbBonus = (c.score.clamp(0, 100)) / 100 * 0.05;
      out.add(c.withWeight(w + mbBonus));
    }
    out.sort((a, b) => b.matchWeight.compareTo(a.matchWeight));
    return out;
  }

  /// 按 MB 候选取封面字节（CAA front-500 优先），校验完整性后返回。
  /// 无封面返回 null（CAA 404 常见，不抛错）。
  Future<OnlineCoverCandidate?> fetchCover(MbRecordingCandidate rec) async {
    final mbid = rec.releaseId;
    if (mbid == null || mbid.isEmpty) return null;
    final bytes = await mbCover.fetchFrontBytes(mbid);
    if (bytes == null || bytes.isEmpty) return null;
    if (!isCompleteImageBytes(bytes)) return null;
    return OnlineCoverCandidate(
      releaseMbid: mbid,
      label: rec.releaseTitle ?? rec.title,
      bytes: bytes.toList(),
      matchWeight: rec.matchWeight,
    );
  }

  // ---------- 应用（保存） ----------

  /// 保存歌词：必写 DB；sidecar 模式下本地源额外写 `.lrc`。
  /// 返回 sidecar 实际落盘路径（未写时为 null）。
  Future<({String? sidecarPath, bool sidecarSkipped})> applyLyrics(
    Song song,
    String content, {
    MusicSource? src,
  }) async {
    final text = content.trim();
    if (text.isEmpty) throw StateError('歌词内容为空');
    await index.setLyrics(song.sourceKey, song.sourceRef, content);
    if (settings.onlineMetaSaveMode != OnlineMetaSaveMode.sidecar) {
      return (sidecarPath: null, sidecarSkipped: false);
    }
    final path = await _writeSidecarLrc(song, content, src);
    if (path == null) return (sidecarPath: null, sidecarSkipped: true);
    return (sidecarPath: path, sidecarSkipped: false);
  }

  /// 保存封面：必写 `covers/` 并回填 `cover_path`；sidecar 模式下额外
  /// 写回源目录 `cover.jpg`（专辑级，同名覆盖）。
  /// [src] 为空（服务端歌）或源不支持写时 sidecar 跳过。
  Future<({String? coverPath, String? sidecarPath, bool sidecarSkipped})>
      applyCover(Song song, List<int> bytes, {MusicSource? src}) async {
    if (bytes.isEmpty) throw StateError('封面字节为空');
    final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final path = await index.persistCoverChunked(u8, song.sourceRef);
    if (path == null) throw StateError('封面校验失败（疑似截断/非图片）');
    await index.enrichSong(song.sourceKey, song.sourceRef, coverPath: path);
    if (settings.onlineMetaSaveMode != OnlineMetaSaveMode.sidecar) {
      return (coverPath: path, sidecarPath: null, sidecarSkipped: false);
    }
    final sidecar = await _writeSidecarCover(song, u8, src);
    if (sidecar == null) {
      return (coverPath: path, sidecarPath: null, sidecarSkipped: true);
    }
    return (coverPath: path, sidecarPath: sidecar, sidecarSkipped: false);
  }

  /// 在线标签回填：只写标题/歌手/专辑（null=不改，''=清空），复用扫描保护语义。
  Future<Song?> applyTags(
    Song song, {
    String? title,
    String? artist,
    String? album,
  }) async {
    if (title == null && artist == null && album == null) return null;
    await index.updateSongUserMeta(
      song.sourceKey,
      song.sourceRef,
      title: title,
      artist: artist,
      album: album,
    );
    return index.songByRef(song.sourceKey, song.sourceRef);
  }

  // ---------- sidecar ----------

  /// 源内父目录（`sourceRef` 去末段；无斜杠即源根 `''`）。
  static String _parentOf(String ref) {
    final slash = ref.lastIndexOf('/');
    if (slash <= 0) return '';
    return ref.substring(0, slash);
  }

  /// 歌词 sidecar 写回源目录：自定义歌词目录（仅本地）优先，否则歌曲同目录
  /// `<stem>.lrc`。同名覆盖（P0）。返回展示用路径；不可写返回 null。
  Future<String?> _writeSidecarLrc(
      Song song, String content, MusicSource? src) async {
    if (src == null || !src.supportsWrite) return null;
    try {
      // 自定义歌词目录仅本地有效（远端无意义）。
      final customDir = settings.onlineMetaLyricDir.trim();
      if (customDir.isNotEmpty && src.kind == SourceKind.local) {
        final dir = Directory(customDir);
        if (!dir.existsSync()) return null;
        final leaf = '${_safeFileName(_stemOf(song.sourceRef))}.lrc';
        final audioPath = await src.localSandboxPath(song);
        if (audioPath == null || audioPath.isEmpty) return null;
        final f = File(p.join(dir.path, leaf));
        await f.writeAsString(content, flush: true);
        return f.path;
      }
      if (src.kind == SourceKind.local) {
        final audioPath = await src.localSandboxPath(song);
        if (audioPath == null || audioPath.isEmpty) return null;
        final dir = p.dirname(audioPath);
        final stem = p.basenameWithoutExtension(audioPath);
        if (stem.isEmpty) return null;
        final f = File(p.join(dir, '$stem.lrc'));
        await f.writeAsString(content, flush: true);
        return f.path;
      }
      // 远端：经源上传口直写同目录（覆盖语义由各源 PUT/截断保证）。
      final parent = _parentOf(song.sourceRef);
      final leaf = '${_stemOf(song.sourceRef)}.lrc';
      if (leaf == '.lrc') return null;
      final bytes = Uint8List.fromList(utf8.encode(content));
      await src.uploadSidecar(
          parent, leaf, Stream.value(bytes), bytes.length);
      return parent.isEmpty ? leaf : '$parent/$leaf';
    } catch (_) {
      return null;
    }
  }

  /// 封面 sidecar 写回源目录 `cover.jpg`（专辑级，同名覆盖）。
  /// 返回展示用路径；不可写返回 null。
  Future<String?> _writeSidecarCover(
      Song song, Uint8List bytes, MusicSource? src) async {
    if (src == null || !src.supportsWrite) return null;
    try {
      if (src.kind == SourceKind.local) {
        final audioPath = await src.localSandboxPath(song);
        if (audioPath == null || audioPath.isEmpty) return null;
        final f = File(p.join(p.dirname(audioPath), kCoverSidecarName));
        await f.writeAsBytes(bytes, flush: true);
        return f.path;
      }
      final parent = _parentOf(song.sourceRef);
      await src.uploadSidecar(parent, kCoverSidecarName,
          Stream.value(bytes), bytes.length);
      return parent.isEmpty
          ? kCoverSidecarName
          : '$parent/$kCoverSidecarName';
    } catch (_) {
      return null;
    }
  }

  /// 嵌入后删除 sidecar（嵌入引擎调用点；P4）。
  ///
  /// 删歌曲同目录 `<stem>.lrc` + `cover.jpg`（`.LRC` 大写变体一并尝试），
  /// 不存在按幂等成功。DB（`song_lyrics`/`covers/`）与 `user_edited` 保留。
  /// 返回实际删掉的展示路径。
  Future<List<String>> deleteSidecars(Song song, MusicSource? src) async {
    if (src == null || !src.supportsWrite) return const [];
    final parent = _parentOf(song.sourceRef);
    final stem = _stemOf(song.sourceRef);
    final deleted = <String>[];
    for (final leaf in ['$stem.lrc', '$stem.LRC', kCoverSidecarName]) {
      if (leaf == '.lrc' || leaf == '.LRC') continue;
      try {
        await src.deleteSidecar(parent, leaf);
        deleted.add(parent.isEmpty ? leaf : '$parent/$leaf');
      } catch (_) {
        // 幂等删除已在各源实现（404/不存在即成功）；其余错误跳过该文件。
      }
    }
    return deleted;
  }

  static String _stemOf(String ref) {
    final slash = ref.lastIndexOf('/');
    final dot = ref.lastIndexOf('.');
    final base = slash < 0 ? ref : ref.substring(slash + 1);
    if (dot <= slash) return base;
    final stem = ref.substring(slash + 1, dot);
    return stem.isEmpty ? base : stem;
  }

  static String _safeFileName(String s) {
    final v = s.trim();
    if (v.isEmpty) return 'unknown';
    return v.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }
}
