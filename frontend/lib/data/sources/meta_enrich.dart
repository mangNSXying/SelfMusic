import 'dart:typed_data';

import '../../models/song.dart';
import '../local/audio_metadata.dart';
import '../local/local_index.dart';
import 'music_source.dart';

/// 后台元数据补读（播放链路共用）：读文件头部 256KB → 解析 → 回填索引 → 标已读。
///
/// 返回是否解析成功：成功才标已读；头部不可解析（如元数据块超出采样范围）
/// 返回 false 且不标已读，下次再试。取流失败抛异常，由调用方决定重试策略。
Future<bool> enrichSongMeta(
    LocalIndex index, MusicSource src, Song song) async {
  const headMax = 256 * 1024;
  final head = <int>[];
  final opened = await src.open(song, range: const IntRange(0, headMax));
  await for (final chunk in opened.stream) {
    head.addAll(chunk);
    if (head.length >= headMax) break;
  }
  final meta = parseAudioHead(
      Uint8List.fromList(head), song.format ?? '', song.fileSize);
  if (meta == null) return false; // 解析失败：不标已读，留待下次重试
  String? coverPath;
  final cover = meta.cover;
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
