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
/// - `sidecar`：额外尝试写本地同目录 `<stem>.lrc`（仅本地源、非鸿蒙、
///
///   有沙箱真路径时；远端源自动跳过，不报错）。
/// 内嵌回写暂不支持（Dart 无 taglib 等价实现，风险高，UI 置灰说明）。
class OnlineMetaService {
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

  /// 保存封面：经 `persistCoverChunked` 落 `covers/` 并回填 `cover_path`。
  /// 封面 sidecar 暂不写（covers/ 已是跨源唯一口径，避免污染用户目录）。
  Future<String?> applyCover(Song song, List<int> bytes) async {
    if (bytes.isEmpty) throw StateError('封面字节为空');
    final u8 = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final path = await index.persistCoverChunked(u8, song.sourceRef);
    if (path == null) throw StateError('封面校验失败（疑似截断/非图片）');
    await index.enrichSong(song.sourceKey, song.sourceRef, coverPath: path);
    return path;
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

  /// 本地同目录写 `<stem>.lrc`；自定义歌词目录优先。
  /// 返回落盘路径；不可写（远端源/鸿蒙/无路径/写失败）返回 null。
  Future<String?> _writeSidecarLrc(
      Song song, String content, MusicSource? src) async {
    if (src == null) return null;
    if (src.kind != SourceKind.local || !src.supportsWrite) return null;
    try {
      final audioPath = await src.localSandboxPath(song);
      if (audioPath == null || audioPath.isEmpty) return null;
      final customDir = settings.onlineMetaLyricDir.trim();
      late final String target;
      if (customDir.isNotEmpty) {
        final dir = Directory(customDir);
        if (!dir.existsSync()) return null;
        target = p.join(dir.path, '${_safeFileName(_stemOf(song.sourceRef))}.lrc');
      } else {
        final dir = p.dirname(audioPath);
        final stem = p.basenameWithoutExtension(audioPath);
        if (stem.isEmpty) return null;
        target = p.join(dir, '$stem.lrc');
      }
      final f = File(target);
      await f.writeAsString(content, flush: true);
      return target;
    } catch (_) {
      return null;
    }
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
