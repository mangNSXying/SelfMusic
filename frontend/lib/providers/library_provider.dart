import 'package:flutter/foundation.dart';
import '../data/sources/music_source.dart';
import '../models/song.dart';
import '../models/album.dart';

class LibraryProvider extends ChangeNotifier {
  final MusicSource source;
  LibraryProvider(this.source);

  List<Song> songs = [];
  List<Album> albums = [];
  bool loading = false;
  String? error;

  Future<void> loadSongs({String? query}) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      songs = await source.fetchSongs(query: query);
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }

  Future<void> loadAlbums({String? query}) async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      albums = await source.fetchAlbums(query: query);
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }
}
