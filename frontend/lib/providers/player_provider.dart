import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../data/sources/music_source.dart';

/// 全局播放状态：统一持有 AudioPlayer 与播放队列，供播放页与队列面板共享。
class PlayerProvider extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  List<Song> _queue = [];
  int _idx = 0;
  Song? _current;
  String? error;

  PlayerProvider() {
    player.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed) next();
    });
  }

  List<Song> get queue => List.unmodifiable(_queue);
  Song? get current => _current;
  bool get hasCurrent => _current != null;
  Duration get position => player.position;
  Duration? get duration => player.duration;
  bool get playing => player.playing;

  /// 载入一个播放队列并从 [index] 开始播放。
  Future<void> playQueue(List<Song> songs, {int index = 0, MusicSource? source}) async {
    if (songs.isEmpty) return;
    _queue = List.of(songs);
    _idx = index.clamp(0, _queue.length - 1);
    final song = _queue[_idx];
    _current = song;
    error = null;
    notifyListeners();
    await _play(song, source: source);
  }

  Future<void> _play(Song s, {MusicSource? source}) async {
    error = null;
    try {
      String? url;
      Map<String, String>? headers;
      if (source != null) {
        url = source.streamUrl(s.id);
        headers = source.streamHeaders();
      }
      if (url == null) {
        // 无可用 source 时（如队列面板直接操作）无法取流，交给播放页处理。
        throw StateError('no stream source available');
      }
      await player.setUrl(url, headers: headers);
      await player.play();
      _current = s;
      notifyListeners();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  Future<void> playAt(int index, {MusicSource? source}) async {
    if (index < 0 || index >= _queue.length) return;
    _idx = index;
    await _play(_queue[_idx], source: source);
  }

  Future<void> playSong(Song s, {List<Song>? queue, int? index, MusicSource? source}) async {
    if (queue != null && queue.isNotEmpty) {
      _queue = List.of(queue);
      _idx = index ?? _queue.indexWhere((x) => x.id == s.id).clamp(0, _queue.length - 1);
      await _play(_queue[_idx], source: source);
    } else {
      error = null;
      await _play(s, source: source);
    }
  }

  Future<void> next() async {
    if (_idx + 1 < _queue.length) {
      _idx++;
      await _play(_queue[_idx]);
    }
  }

  Future<void> prev() async {
    if (_idx > 0) {
      _idx--;
      await _play(_queue[_idx]);
    }
  }

  Future<void> toggle() async {
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
    notifyListeners();
  }

  Future<void> seek(Duration d) => player.seek(d);

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }
}
