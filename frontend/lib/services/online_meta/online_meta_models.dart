/// 在线元数据模型（纯前端）：LRCLIB / QQ音乐 / 网易云歌词 + MB/CAA 封面。
library;

/// 在来源标识（候选 `source` 字段取值；设置页选择器与之对应）。
class OnlineMetaSource {
  static const String lrclib = 'LRCLIB';
  static const String qq = 'QQ音乐';
  static const String netease = '网易云';
  static const String mbCaa = 'MB→CAA';
}

/// 歌词候选（LRCLIB 精确+模糊 / QQ / 网易搜索共用；QQ/网易搜索不带正文，
/// 经 `ensureLyrics` 懒取后回填 [syncedLyrics]/[plainLyrics]）。
class OnlineLyricCandidate {
  /// 来源内唯一标识：LRCLIB 数字 id / QQ `songmid` / 网易数字 id（字符串化）。
  final String onlineId;

  /// 来源（[OnlineMetaSource] 之一，用于展示与取数路由）。
  final String source;
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
    required this.onlineId,
    required this.source,
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
        onlineId: onlineId,
        source: source,
        trackName: trackName,
        artistName: artistName,
        albumName: albumName,
        durationSec: durationSec,
        syncedLyrics: syncedLyrics,
        plainLyrics: plainLyrics,
        instrumental: instrumental,
        matchWeight: w,
      );

  /// 回填懒取到的歌词正文（QQ/网易搜索后按需取词用）。
  OnlineLyricCandidate withLyrics({String? syncedLyrics, String? plainLyrics}) =>
      OnlineLyricCandidate(
        onlineId: onlineId,
        source: source,
        trackName: trackName,
        artistName: artistName,
        albumName: albumName,
        durationSec: durationSec,
        syncedLyrics: syncedLyrics ?? this.syncedLyrics,
        plainLyrics: plainLyrics ?? this.plainLyrics,
        instrumental: instrumental,
        matchWeight: matchWeight,
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
