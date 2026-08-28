class Song {
  final int id;
  final String title;
  final String? artist;
  final int? trackNo;
  final int? year;
  final String? genre;
  final int? duration;
  final String source;
  final String sourceRef;
  final int fileSize;
  final String? format;
  final bool favorite;
  final bool hidden;

  Song({
    required this.id,
    required this.title,
    this.artist,
    this.trackNo,
    this.year,
    this.genre,
    this.duration,
    required this.source,
    required this.sourceRef,
    required this.fileSize,
    this.format,
    this.favorite = false,
    this.hidden = false,
  });

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        id: j['id'] as int,
        title: j['title'] as String? ?? 'Unknown',
        artist: j['artist'] as String?,
        trackNo: j['trackNo'] as int?,
        year: j['year'] as int?,
        genre: j['genre'] as String?,
        duration: j['duration'] as int?,
        source: j['source'] as String? ?? 'local',
        sourceRef: j['sourceRef'] as String? ?? '',
        fileSize: j['fileSize'] as int? ?? 0,
        format: j['format'] as String?,
        favorite: j['favorite'] as bool? ?? false,
        hidden: j['hidden'] as bool? ?? false,
      );
}
