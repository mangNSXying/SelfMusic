import 'package:dio/dio.dart';
import '../../models/song.dart';
import '../../models/album.dart';
import 'music_source.dart';

class ServerProxySource extends MusicSource {
  final Dio dio;
  final String baseUrl;
  final String Function()? tokenProvider;

  /// 稳定标识：全局服务端源为 `'server'`；按源代理模式传入如 `'webdav:<name>'`。
  @override
  final String key;
  @override
  final String name;

  ServerProxySource({
    required this.dio,
    required this.baseUrl,
    this.key = 'server',
    this.name = 'server',
    this.tokenProvider,
  });

  @override
  SourceKind get kind => SourceKind.server;

  @override
  String streamUrl(int songId) => '$baseUrl/api/v1/stream/$songId';
  @override
  Future<List<Song>> fetchSongs({String? query, int page = 1, int size = 50}) async {
    final resp = await dio.get('/api/v1/library/songs', queryParameters: {
      if (query != null && query.isNotEmpty) 'q': query,
      'page': page,
      'size': size,
    });
    final data = resp.data['data'];
    final content = (data is Map ? data['content'] : data) as List;
    return content
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .map((s) => _withSourceKey(s))
        .toList();
  }

  Song _withSourceKey(Song s) =>
      s.sourceKey == key ? s : _copyWithSourceKey(s, key);

  Song _copyWithSourceKey(Song s, String key) => Song(
        id: s.id,
        sourceKey: key,
        title: s.title,
        artist: s.artist,
        albumName: s.albumName,
        trackNo: s.trackNo,
        year: s.year,
        genre: s.genre,
        duration: s.duration,
        source: s.source,
        sourceRef: s.sourceRef,
        fileSize: s.fileSize,
        format: s.format,
        favorite: s.favorite,
        hidden: s.hidden,
        coverPath: s.coverPath,
        sourceUrl: s.sourceUrl,
      );

  @override
  Future<List<Album>> fetchAlbums({String? query, int page = 1, int size = 50}) async {
    final resp = await dio.get('/api/v1/library/albums', queryParameters: {
      if (query != null && query.isNotEmpty) 'q': query,
      'page': page,
      'size': size,
    });
    final data = resp.data['data'];
    final content = (data is Map ? data['content'] : data) as List;
    return content.map((e) => Album.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<Song>> fetchAlbumSongs(int albumId) async {
    final resp = await dio.get('/api/v1/library/albums/$albumId');
    final data = resp.data['data'] as Map<String, dynamic>;
    final songs = data['songs'] as List;
    return songs.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Map<String, String>? streamHeaders() {
    final t = tokenProvider?.call();
    if (t == null || t.isEmpty) return null;
    return {'Authorization': 'Bearer $t'};
  }
}
