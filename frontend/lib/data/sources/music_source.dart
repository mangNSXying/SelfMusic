import '../../models/song.dart';
import '../../models/album.dart';

/// 阶段一：Source 抽象。App 双模式基石：ServerProxy 完整可用，其它源桩。
abstract class MusicSource {
  Future<List<Song>> fetchSongs({String? query, int page = 1, int size = 50});
  Future<List<Album>> fetchAlbums({String? query, int page = 1, int size = 50});
  Future<List<Song>> fetchAlbumSongs(int albumId);
  String streamUrl(int songId);
  Map<String, String>? streamHeaders();
}
