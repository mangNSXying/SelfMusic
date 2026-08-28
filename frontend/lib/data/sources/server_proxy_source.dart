import 'package:dio/dio.dart';
import '../../models/song.dart';
import '../../models/album.dart';
import 'music_source.dart';

class ServerProxySource implements MusicSource {
  final Dio dio;
  final String baseUrl;
  final String Function()? tokenProvider;

  ServerProxySource({required this.dio, required this.baseUrl, this.tokenProvider});

  @override
  Future<List<Song>> fetchSongs({String? query, int page = 1, int size = 50}) async {
    final resp = await dio.get('/api/v1/library/songs', queryParameters: {
      if (query != null && query.isNotEmpty) 'q': query,
      'page': page,
      'size': size,
    });
    final data = resp.data['data'];
    final content = (data is Map ? data['content'] : data) as List;
    return content.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }

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
  String streamUrl(int songId) => '$baseUrl/api/v1/stream/$songId';

  @override
  Map<String, String>? streamHeaders() {
    final t = tokenProvider?.call();
    if (t == null || t.isEmpty) return null;
    return {'Authorization': 'Bearer $t'};
  }
}
