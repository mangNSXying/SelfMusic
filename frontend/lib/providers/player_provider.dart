import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../data/sources/music_source.dart';
import '../data/sources/direct_audio_source.dart';
import '../data/local/local_index.dart';
import '../data/local/song_weight_store.dart';

/// 按源 key 解析播放源的函数：`server` → 服务器代理源；`webdav:<name>` → 对应直连源。
typedef SourceResolver = MusicSource? Function(String sourceKey);

/// 播放模式（stage2.md §3）。
enum PlayMode { sequence, loopList, loopOne, weighted }

/// 全局播放状态：统一持有 AudioPlayer 与播放队列，供播放页与队列面板共享。
///
/// 阶段 2（stage2.md §2/§3/§7）：
/// - 四种播放模式（顺序/列表循环/单曲循环/加权随机）。
/// - 加权随机：每步从队列全量（排除上一首）按 factor 权重采样，不连续同一首。
/// - 事件采集：complete(≥70%)/skip(<70%) → SongWeightStore 调权。
/// - 断点：节流持久化 play_state，启动恢复为暂停态。
class PlayerProvider extends ChangeNotifier {
  static const double completeRatio = 0.7;

  final AudioPlayer player = AudioPlayer();
  List<Song> _queue = [];
  int _idx = 0;
  Song? _current;
  MusicSource? _curSource;
  SourceResolver? _resolver;
  LocalIndex? _index;
  SongWeightStore? _weight;
  void Function(MusicSource src, Song s)? _onTrackStarted;
  String? error;

  PlayMode _mode = PlayMode.sequence;
  DateTime? _lastStateSave;
  bool _restored = false;

  PlayerProvider() {
    player.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed) {
        final finished = _current;
        if (finished != null) {
          _emitWeight(finished, completed: true,
              position: player.duration ?? Duration.zero);
        }
        _advance();
      }
    });
    player.positionStream.listen(_maybeSaveState);
  }

  /// 关联源解析器（混合队列时按歌曲 sourceKey 逐首选择播放源）。
  void attachSourceResolver(SourceResolver resolver) {
    _resolver = resolver;
  }

  /// 关联本地索引（断点持久化/恢复）与权重存储（事件调权）。
  void attachPersistence({
    required LocalIndex index,
    required SongWeightStore weight,
    void Function(MusicSource src, Song s)? onTrackStarted,
  }) {
    _index = index;
    _weight = weight;
    _onTrackStarted = onTrackStarted;
  }

  List<Song> get queue => List.unmodifiable(_queue);
  Song? get current => _current;
  bool get hasCurrent => _current != null;
  Duration get position => player.position;
  Duration? get duration => player.duration;
  bool get playing => player.playing;
  PlayMode get mode => _mode;

  /// 当前歌曲权重因子（无存储时为空；用于播放页展示，可选）。
  double? get currentWeightFactor {
    final s = _current;
    final w = _weight;
    if (s == null || w == null) return null;
    return w.factorOf(s);
  }

  void setMode(PlayMode m) {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
  }

  // ---------- 队列装载 ----------

  /// 载入一个播放队列并从 [index] 开始播放。
  Future<void> playQueue(List<Song> songs,
      {int index = 0, MusicSource? source}) async {
    if (songs.isEmpty) return;
    final start = index.clamp(0, songs.length - 1);
    _leaveFor(songs[start]);
    _queue = List.of(songs);
    _idx = start;
    error = null;
    notifyListeners();
    await _play(_queue[_idx], source: source);
  }

  Future<void> playAt(int index, {MusicSource? source}) async {
    if (index < 0 || index >= _queue.length) return;
    _leaveFor(_queue[index]);
    _idx = index;
    await _play(_queue[_idx], source: source);
  }

  Future<void> playSong(Song s,
      {List<Song>? queue, int? index, MusicSource? source}) async {
    if (queue != null && queue.isNotEmpty) {
      _queue = List.of(queue);
      final found = _queue.indexWhere((x) => _same(x, s));
      final i = index ??
          (found < 0 ? _idx.clamp(0, _queue.length - 1) : found);
      _leaveFor(_queue[i]);
      _idx = i;
      await _play(_queue[_idx], source: source);
    } else {
      error = null;
      await _play(s, source: source);
    }
  }

  Future<void> _play(Song s, {MusicSource? source, bool play = true}) async {
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
      if (play) await player.play();
      _current = s;
      _curSource = src;
      _saveState(player.position);
      if (src != null) _onTrackStarted?.call(src, s);
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

  // ---------- 前进/后退 ----------

  Future<void> next() {
    _leaveFor(null);
    return _advance();
  }

  Future<void> _advance() async {
    if (_queue.isEmpty || _current == null) return;
    if (_mode == PlayMode.weighted) {
      await _playWeighted();
      return;
    }
    if (_mode == PlayMode.loopOne) {
      await _replay();
      return;
    }
    if (_mode == PlayMode.loopList) {
      _idx = (_idx + 1) % _queue.length;
      await _play(_queue[_idx], source: _curSource);
      return;
    }
    if (_idx + 1 < _queue.length) {
      _idx++;
      await _play(_queue[_idx], source: _curSource);
    }
  }

  Future<void> prev() {
    _leaveFor(null);
    if (_queue.isEmpty || _current == null) return Future.value();
    if (_mode == PlayMode.loopOne) return _replay();
    if (_mode == PlayMode.loopList) {
      _idx = (_idx - 1 + _queue.length) % _queue.length;
      return _play(_queue[_idx], source: _curSource);
    }
    if (_idx > 0) {
      _idx--;
      return _play(_queue[_idx], source: _curSource);
    }
    return Future.value();
  }

  /// 单曲循环：同一首重播。
  Future<void> _replay() async {
    await player.seek(Duration.zero);
    await player.play();
  }

  /// 加权随机下一首（stage2.md §2.2）：从队列全量排除上一首按 factor 采样。
  Future<void> _playWeighted() async {
    if (_queue.isEmpty) return;
    final prev = _current;
    var candidates =
        _queue.where((s) => prev == null || !_same(s, prev)).toList();
    if (candidates.isEmpty) candidates = List.of(_queue);
    final weights = <double>[];
    var total = 0.0;
    for (final s in candidates) {
      final f = _weight?.factorOf(s) ?? SongWeightStore.defaultFactor;
      weights.add(f);
      total += f;
    }
    var rnd = Random().nextDouble() * total;
    var picked = candidates.first;
    for (var i = 0; i < candidates.length; i++) {
      rnd -= weights[i];
      if (rnd <= 0) {
        picked = candidates[i];
        break;
      }
    }
    _idx = _queue.indexWhere((s) => _same(s, picked));
    if (_idx < 0) _idx = 0;
    await _play(picked, source: _curSource);
  }

  // ---------- 事件采集（stage2.md §2.3） ----------

  void _emitWeight(Song s, {required bool completed, required Duration position}) {
    final w = _weight;
    if (w == null) return;
    final dur = player.duration;
    final ratio = (dur != null && dur.inMilliseconds > 0)
        ? position.inMilliseconds / dur.inMilliseconds
        : 0.0;
    if (completed) {
      if (ratio >= completeRatio) {
        w.onCompleted(s);
      } else {
        w.onSkipped(s);
      }
      return;
    }
    // 手动切歌：<70% 记为 skip 降权；≥70% 视为已听完，不调权。
    if (ratio < completeRatio) {
      w.onSkipped(s);
    }
  }

  /// 手动离开当前歌前调用（避免对同一首重复判定）。
  void _leaveFor(Song? target) {
    final c = _current;
    if (c == null) return;
    if (target != null && _same(c, target)) return;
    _emitWeight(c, completed: false, position: player.position);
  }

  // ---------- 播放控制 ----------

  Future<void> toggle() async {
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
    notifyListeners();
  }

  Future<void> seek(Duration d) => player.seek(d);

  // ---------- 断点（stage2.md §7） ----------

  void _maybeSaveState(Duration pos) {
    final now = DateTime.now();
    if (_lastStateSave == null ||
        now.difference(_lastStateSave!) >= const Duration(seconds: 2)) {
      _lastStateSave = now;
      _saveState(pos);
    }
  }

  void _saveState(Duration pos) {
    final idx = _index;
    if (idx == null || _queue.isEmpty || _current == null) return;
    idx.savePlayState(
      jsonEncode(_queue.map((s) => s.toJson()).toList()),
      _idx,
      pos.inMilliseconds,
    );
  }

  /// 启动恢复：装载上次队列与位置，暂停态不自动播放。
  Future<void> restoreIfAny() async {
    final idx = _index;
    if (idx == null || _restored) return;
    _restored = true;
    final st = idx.getPlayState();
    if (st == null || st.queueJson.isEmpty) return;
    try {
      final list = (jsonDecode(st.queueJson) as List)
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
      if (list.isEmpty) {
        idx.clearPlayState();
        return;
      }
      _queue = list;
      _idx = st.idx.clamp(0, _queue.length - 1);
      _current = _queue[_idx];
      error = null;
      await _play(_current!, play: false);
      await player.seek(Duration(milliseconds: st.positionMs));
      notifyListeners();
    } catch (e) {
      error = '断点恢复失败：$e';
      notifyListeners();
    }
  }

  void clearResumeState() => _index?.clearPlayState();

  bool _same(Song a, Song b) =>
      a.sourceKey == b.sourceKey && a.sourceRef == b.sourceRef;

  @override
  void dispose() {
    _saveState(player.position);
    player.dispose();
    super.dispose();
  }
}