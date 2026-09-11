// ignore_for_file: experimental_member_use
import 'package:just_audio/just_audio.dart';

import '../../models/song.dart';
import 'music_source.dart';

/// 将直连源的字节流包装为 just_audio 的 [StreamAudioSource]，
/// 支持 Range 起播 / seek（每次 seek 重建一次范围请求）。
///
/// NOTE：just_audio 的 [StreamAudioSource.request] 中 [end] 为**开区间**（不含）。
class DirectAudioSource extends StreamAudioSource {
  final MusicSource source;
  final Song song;

  DirectAudioSource({required this.source, required this.song});

  @override
  Duration? get duration => song.duration != null && song.duration! > 0
      ? Duration(seconds: song.duration!)
      : null;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final full = start == null && end == null;
    final opened = await source.open(
      song,
      range: full
          ? null
          : IntRange(start ?? 0, end == null ? null : (end - (start ?? 0))),
    );
    final contentLength = full ? opened.contentLength : (end != null ? (end - (start ?? 0)) : opened.contentLength);
    return StreamAudioResponse(
      sourceLength: song.fileSize > 0 ? song.fileSize : null,
      contentLength: contentLength,
      offset: start,
      stream: opened.stream,
      contentType: opened.contentType,
    );
  }
}
