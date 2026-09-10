import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../data/sources/music_source.dart';
import '../data/sources/direct_audio_source.dart';

/// 按源 key 解析播放源的函数：`server` → 服务器代理源；`webdav:<name>` → 对应直连源。
typedef SourceResolver = MusicSource? Function(String sourceKey);

/// 全局播放状态：统一持有 AudioPlayer 与播放队列，供播放页与队列面板共享。
class PlayerProvider extends ChangeNotifier {
  final AudioPlayer player = AudioPlayer();
  List<Song> _queue = [];
  int _idx = 0;
  Song? _current;
  MusicSource? _curSource;
  SourceResolver? _resolver;
  String? error;

  PlayerProvider() {
    player.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed) next();
    });
  }

  /// 关联源解析器（混合队列时按歌曲 sourceKey 逐首选择播放源）。
  void attachSourceResolver(SourceResolver resolver) {
    _resolver = resolver;
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
    _curSource = source;
    error = null;
    notifyListeners();
    await _play(song, source: source);
  }

  Future<void> _play(Song s, {MusicSource? source}) async {
    error = null;
    try {
      final src = _resolver?.call(s.sourceKey) ?? source ?? _curSource;
      if (src != null && src.supportsDirect) {
        await _playDirect(s, src);
      } else {
        String? url;
        Map<String, String>? headers;
        if (src != null) {
          url = src.streamUrl(s.id);
          headers = src.streamHeaders();
        }
        if (url == null) {
          throw StateError('no stream source available');
        }
        await player.setUrl(url, headers: headers);
      }
      await player.play();
      _current = s;
      _curSource = src;
      notifyListeners();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  /// 直连源播放：优先离线缓存文件，否则流式（Range seek / 断点可持续）。
  Future<void> _playDirect(Song s, MusicSource src) async {
    final cached = await src.cachedFilePath(s);
    if (cached != null) {
      await player.setFilePath(cached);
      return;
    }
    await player.setAudioSource(DirectAudioSource(source: src, song: s));
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
      await _play(_queue[_idx], source: _curSource);
    }
  }

  Future<void> prev() async {
    if (_idx > 0) {
      _idx--;
      await _play(_queue[_idx], source: _curSource);
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
