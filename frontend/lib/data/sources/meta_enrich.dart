import 'dart:typed_data';

import '../../models/song.dart';
import '../local/audio_metadata.dart';
import '../local/local_index.dart';
import 'music_source.dart';
import 'sibling_cover.dart';

/// 后台元数据补读（播放链路共用）：头部直读 → 解析 → 回填索引 → 标已读。
///
/// 读序（[readAudioMeta] 统一实现，fullRead 完整读取）：
/// 1. 头部采样不足以拿到完整元数据时，从头完整读取整个文件（不截断）——
///    大内嵌封面、PICTURE 在 VORBIS_COMMENT 之前等块序异常也能完整解析；
/// 2. 尾部信息（m4a moov-at-end / ogg·opus 时长 / mp3 ID3v1）在完整数据上补全；
/// 3. 仍无封面 → 同目录图片回退（同名图片优先，其次 cover/folder 等）。
///
/// 返回是否解析成功：成功才标已读；未识别容器（无法解析）返回 false 且不标已读。
/// 取流失败抛异常，由调用方决定重试策略。
Future<bool> enrichSongMeta(
    LocalIndex index, MusicSource src, Song song) async {
  final meta = await readAudioMeta(
    readRange: (start, length) => _readRange(src, song, start, length),
    format: song.format ?? '',
    fileSize: song.fileSize,
    fullRead: true,
  );
  if (meta == null) return false; // 未识别容器：不标已读，留待后续重试
  var cover = meta.cover;
  if (cover == null || cover.isEmpty) {
    cover = await fetchSiblingImage(src, song);
  }
  String? coverPath;
  if (cover != null && cover.isNotEmpty) {
    coverPath = index.persistCover(cover, song.sourceRef);
  }
  await index.enrichSong(song.sourceKey, song.sourceRef,
      title: meta.title,
      artist: meta.artist,
      album: meta.album,
      albumArtist: meta.albumArtist,
      duration: meta.duration,
      genre: meta.genre,
      trackNo: meta.trackNo,
      year: meta.year,
      coverPath: coverPath);
  // 内嵌歌词：仅在尚无歌词记录（或仅有「无歌词」标记）时写入，避免覆盖同名 .lrc/用户内容。
  final lyrics = meta.lyrics?.trim();
  if (lyrics != null && lyrics.isNotEmpty) {
    final existing = index.lyricsOf(song.sourceKey, song.sourceRef);
    if (existing == null || existing.isEmpty) {
      await index.setLyrics(song.sourceKey, song.sourceRef, lyrics);
    }
  }
  return true;
}

/// 打开 [start, start+length) 范围并读满（流长度不足时返回实际全部）。
/// 用 [BytesBuilder] 累积：完整读取可能达到整个文件大小，避免 `List<int>`
/// 在超大文件上的高额内存开销。
Future<Uint8List> _readRange(
    MusicSource src, Song song, int start, int length) async {
  final buf = BytesBuilder(copy: false);
  final opened = await src.open(song, range: IntRange(start, length));
  await for (final chunk in opened.stream) {
    buf.add(chunk);
    if (buf.length >= length) break;
  }
  return buf.takeBytes();
}
