/// 在线元数据模型（纯前端，LRCLIB 歌词 + MB/CAA 封面）。
library;

/// LRCLIB 歌词候选（`/api/get` 精确 + `/api/search` 模糊共用）。
class OnlineLyricCandidate {
  final int id;
  final String trackName;
  final String artistName;
  final String albumName;
  final double? durationSec;

  /// 同步歌词（LRC，可空）；为空时用 [plainLyrics]。
  final String? syncedLyrics;
  final String? plainLyrics;
  final bool instrumental;

  /// 匹配权重（调用方按 MusicPlayer2 权重公式填充，用于最佳匹配高亮）。
  final double matchWeight;

  const OnlineLyricCandidate({
    required this.id,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    this.durationSec,
    this.syncedLyrics,
    this.plainLyrics,
    this.instrumental = false,
    this.matchWeight = 0,
  });

  OnlineLyricCandidate withWeight(double w) => OnlineLyricCandidate(
        id: id,
        trackName: trackName,
        artistName: artistName,
        albumName: albumName,
        durationSec: durationSec,
        syncedLyrics: syncedLyrics,
        plainLyrics: plainLyrics,
        instrumental: instrumental,
        matchWeight: w,
      );

  /// 保存用正文：同步优先（播放页可滚动），否则纯文本。
  String get saveContent {
    final s = (syncedLyrics ?? '').trim();
    if (s.isNotEmpty && s.contains('[')) return syncedLyrics!;
    return (plainLyrics ?? '').trim();
  }

  bool get hasContent => saveContent.isNotEmpty;
}

/// MB 录音候选（封面链用：recording -> release MBID）。
class MbRecordingCandidate {
  final String recordingId;
  final String title;
  final String artist;
  final String? releaseId;
  final String? releaseTitle;
  final int score;
  final double matchWeight;

  const MbRecordingCandidate({
    required this.recordingId,
    required this.title,
    required this.artist,
    this.releaseId,
    this.releaseTitle,
    this.score = 0,
    this.matchWeight = 0,
  });

  MbRecordingCandidate withWeight(double w) => MbRecordingCandidate(
        recordingId: recordingId,
        title: title,
        artist: artist,
        releaseId: releaseId,
        releaseTitle: releaseTitle,
        score: score,
        matchWeight: w,
      );
}

/// CAA 封面候选（已下载字节，用于预览+落盘）。
class OnlineCoverCandidate {
  final String? releaseMbid;
  final String label;

  /// 缩略图/原图字节（CAA `/front` 或 `-500` 变体）。
  final List<int> bytes;
  final double matchWeight;

  const OnlineCoverCandidate({
    this.releaseMbid,
    required this.label,
    required this.bytes,
    this.matchWeight = 0,
  });
}
