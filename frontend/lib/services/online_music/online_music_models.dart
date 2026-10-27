/// 在线音乐 sidecar 的数据模型。
class OnlineSourceInfo {
  final String id;
  final String label;
  final bool isDefault;

  const OnlineSourceInfo({
    required this.id,
    required this.label,
    this.isDefault = false,
  });

  factory OnlineSourceInfo.fromJson(Map<String, dynamic> json) {
    return OnlineSourceInfo(
      id: (json['id'] as String?) ?? '',
      label: (json['label'] as String?) ?? '',
      isDefault: json['default'] == true,
    );
  }
}

class OnlineTrack {
  final String token;
  final String source;
  final String sourceLabel;
  final String title;
  final String artist;
  final String album;
  final int durationS;
  final String ext;
  final int sizeBytes;
  final bool lossless;
  final bool hasLyric;

  const OnlineTrack({
    required this.token,
    required this.source,
    required this.sourceLabel,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationS,
    required this.ext,
    required this.sizeBytes,
    required this.lossless,
    required this.hasLyric,
  });

  factory OnlineTrack.fromJson(Map<String, dynamic> json) {
    return OnlineTrack(
      token: (json['track_token'] as String?) ?? '',
      source: (json['source'] as String?) ?? '',
      sourceLabel: (json['source_label'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      artist: (json['artist'] as String?) ?? '',
      album: (json['album'] as String?) ?? '',
      durationS: (json['duration_s'] as num?)?.toInt() ?? 0,
      ext: (json['ext'] as String?) ?? '',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      lossless: json['lossless'] == true,
      hasLyric: json['has_lyric'] == true,
    );
  }
}

sealed class OnlineSearchEvent {
  const OnlineSearchEvent();
}

class OnlineSourceStart extends OnlineSearchEvent {
  final String source;
  final String sourceLabel;

  const OnlineSourceStart(this.source, this.sourceLabel);
}

class OnlineSourceDone extends OnlineSearchEvent {
  final String source;
  final int count;
  final bool timedOut;

  const OnlineSourceDone(this.source, this.count, this.timedOut);
}

class OnlineSourceError extends OnlineSearchEvent {
  final String source;
  final String message;

  const OnlineSourceError(this.source, this.message);
}

class OnlineTrackEvent extends OnlineSearchEvent {
  final OnlineTrack track;

  const OnlineTrackEvent(this.track);
}

class OnlineSearchDone extends OnlineSearchEvent {
  final int count;

  const OnlineSearchDone(this.count);
}

class OnlineFetchJob {
  final String id;
  final String status;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final String source;
  final String sourceLabel;
  final String title;
  final String artist;
  final String album;
  final String filename;
  final String ext;
  final int sizeBytes;
  final double durationS;
  final int sampleRate;
  final int channels;
  final int bitDepth;
  final int bitrate;
  final String error;
  final bool hasLyric;

  const OnlineFetchJob({
    required this.id,
    required this.status,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    required this.source,
    required this.sourceLabel,
    required this.title,
    required this.artist,
    required this.album,
    required this.filename,
    required this.ext,
    required this.sizeBytes,
    required this.durationS,
    required this.sampleRate,
    required this.channels,
    required this.bitDepth,
    required this.bitrate,
    required this.error,
    required this.hasLyric,
  });

  bool get isReady => status == 'ready';
  bool get isError => status == 'error';

  factory OnlineFetchJob.fromJson(Map<String, dynamic> json) {
    return OnlineFetchJob(
      id: (json['job_id'] as String?) ?? '',
      status: (json['status'] as String?) ?? 'queued',
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      downloadedBytes: (json['downloaded_bytes'] as num?)?.toInt() ?? 0,
      totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
      source: (json['source'] as String?) ?? '',
      sourceLabel: (json['source_label'] as String?) ?? '',
      title: (json['title'] as String?) ?? '',
      artist: (json['artist'] as String?) ?? '',
      album: (json['album'] as String?) ?? '',
      filename: (json['filename'] as String?) ?? '',
      ext: (json['ext'] as String?) ?? '',
      sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
      durationS: (json['duration_s'] as num?)?.toDouble() ?? 0,
      sampleRate: (json['sample_rate'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 0,
      bitDepth: (json['bit_depth'] as num?)?.toInt() ?? 0,
      bitrate: (json['bitrate'] as num?)?.toInt() ?? 0,
      error: (json['error'] as String?) ?? '',
      hasLyric: json['has_lyric'] == true,
    );
  }
}

class OnlineMusicException implements Exception {
  final String message;
  final int? statusCode;

  const OnlineMusicException(this.message, {this.statusCode});

  @override
  String toString() => message;
}
