import '../../models/song.dart';
import '../../models/album.dart';

/// 源的分类。决定直连协议与可用的增强能力。
enum SourceKind { server, local, webdav, smb }

/// 字节范围请求（含起止），用于 Range 起播 / seek。
class IntRange {
  final int start;
  final int? length;
  const IntRange(this.start, [this.length]);

  /// 闭区间 end（含），与 just_audio StreamAudioResponse 语义一致。
  int? get end => length == null ? null : start + length! - 1;
}

/// 一次扫描的汇总（DESIGN §6.4）。
class ScanSummary {
  final int added;
  final int updated;
  final int total;
  const ScanSummary({required this.added, required this.updated, required this.total});
}

/// 打开的音频流（直接流式传输的统一返回结构）。
class OpenedStream {
  final int contentLength;
  final String contentType;
  final Stream<List<int>> stream;
  const OpenedStream({
    required this.contentLength,
    required this.contentType,
    required this.stream,
  });
}

/// Source 抽象（DESIGN §6.2）。播放器只认 [MusicSource]，不感知服务器/直连模式。
///
/// - 服务器模式：[ServerProxySource] 用 `streamUrl` + `streamHeaders` 走 `/stream/{id}`。
/// - 直连模式：实现 `supportsDirect` 并实现 `scan`/`open`，由 PlayerProvider 包装成
///   `StreamAudioSource` 喂给 just_audio（支持 Range seek / 断点）。
abstract class MusicSource {
  /// 稳定标识（DESIGN §6.2 key）：`server` / `webdav:<name>` / `smb:<name>` / `local:<name>`。
  String get key;
  SourceKind get kind;

  // ---------- 服务器模式接口 ----------
  Future<List<Song>> fetchSongs({String? query, int page = 1, int size = 50});
  Future<List<Album>> fetchAlbums({String? query, int page = 1, int size = 50});
  Future<List<Song>> fetchAlbumSongs(int albumId);

  /// 服务器模式的流式 URL；直连源返回 null（由 [open] 提供）。
  String? streamUrl(int songId);
  Map<String, String>? streamHeaders();

  // ---------- 直连模式接口（默认不支持） ----------
  bool get supportsDirect => false;

  /// 建本地索引（增量）。默认抛"不支持直连"。
  Future<ScanSummary> scan() async =>
      throw UnimplementedError('$key 不支持直连扫描');

  /// 打开音频流（支持 Range）。默认抛"不支持直连"。
  Future<OpenedStream> open(Song song, {IntRange? range}) async =>
      throw UnimplementedError('$key 不支持直连播放');

  /// 依据本地索引检索歌曲。
  Future<List<Song>> search({String? query, int page = 1, int size = 100}) async =>
      const [];

  /// 若该歌已离线缓存，返回本地文件路径（供断网播缓存，DESIGN §6.5）；否则 null。
  Future<String?> cachedFilePath(Song song) async => null;

  /// 把直连音频下载缓存到本地（断网可播）。
  Future<void> cacheSong(Song song) async =>
      throw UnimplementedError('$key 不支持直连缓存');

  Future<void> close() async {}
}
