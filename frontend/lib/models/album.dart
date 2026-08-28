class Album {
  final int id;
  final String artist;
  final String album;
  final int? year;
  final String? genre;
  final int trackCount;
  final int totalDuration;

  Album({
    required this.id,
    required this.artist,
    required this.album,
    this.year,
    this.genre,
    required this.trackCount,
    required this.totalDuration,
  });

  factory Album.fromJson(Map<String, dynamic> j) => Album(
        id: j['id'] as int,
        artist: j['artist'] as String? ?? 'Unknown',
        album: j['album'] as String? ?? 'Unknown',
        year: j['year'] as int?,
        genre: j['genre'] as String?,
        trackCount: j['trackCount'] as int? ?? 0,
        totalDuration: j['totalDuration'] as int? ?? 0,
      );
}
