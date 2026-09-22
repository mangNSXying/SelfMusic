import 'dart:typed_data';

import '../../models/song.dart';
import '../local/audio_metadata.dart';
import '../local/local_index.dart';
import 'music_source.dart';
import 'sibling_cover.dart';

/// 后台元数据补读（播放链路共用）：头部直读 → 解析 → 回填索引 → 标已读。
///
/// 读序（[readAudioMeta] 统一实现）：
/// 1. 头部 256KB；大内嵌封面按 `coverReadHint` 补读整段标签/块（上限 8MB）；
/// 2. m4a moov-at-end / ogg·opus 时长按 `tailReadHint` 尾读（m4a 逐级增大）；
/// 3. 仍无封面 → 同目录图片回退（同名图片优先，其次 cover/folder 等）。
///
/// 返回是否解析成功：成功才标已读；未识别容器（无法解析）返回 false 且不标已读。
/// 取流失败抛异常，由调用方决定重试策略。
/// [fullRead] 仅播放链路懒补读开启：正在播放歌曲的封面读到满，不截断。
Future<bool> enrichSongMeta(
    LocalIndex index, MusicSource src, Song song,
    {bool fullRead = false}) async {
  final meta = await readAudioMeta(
    readRange: (start, length) => _readRange(src, song, start, length),
    format: song.format ?? '',
    fileSize: song.fileSize,
    fullRead: fullRead,
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
  index.enrichSong(song.sourceKey, song.sourceRef,
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
      index.setLyrics(song.sourceKey, song.sourceRef, lyrics);
    }
  }
  return true;
}

/// 打开 [start, start+length) 范围并读满（流长度不足时返回实际全部）。
Future<Uint8List> _readRange(
    MusicSource src, Song song, int start, int length) async {
  final bytes = <int>[];
  final opened = await src.open(song, range: IntRange(start, length));
  await for (final chunk in opened.stream) {
    bytes.addAll(chunk);
    if (bytes.length >= length) break;
  }
  return Uint8List.fromList(bytes);
}
