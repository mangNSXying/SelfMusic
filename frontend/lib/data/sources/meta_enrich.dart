import 'dart:typed_data';

import '../../models/song.dart';
import '../local/audio_metadata.dart';
import '../local/local_index.dart';
import 'music_source.dart';

/// 后台元数据补读（播放链路共用）：读文件头部 256KB → 解析 → 回填索引 → 标已读。
///
/// 成功（取到头部，无论是否解析出字段）返回 true；取流失败抛异常，
/// 调用方决定是否重试（播放失败不标已读，下次播放再试）。
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
  String? coverPath;
  final cover = meta?.cover;
  if (cover != null && cover.isNotEmpty) {
    coverPath = index.persistCover(cover, song.sourceRef);
  }
  index.enrichSong(song.sourceKey, song.sourceRef,
      duration: meta?.duration,
      genre: meta?.genre,
      trackNo: meta?.trackNo,
      year: meta?.year,
      coverPath: coverPath);
  return true;
}
