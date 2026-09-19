import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import '../models/song.dart';
import '../data/sources/music_source.dart';
import '../data/sources/direct_audio_source.dart';
import '../data/local/local_index.dart';
import '../data/local/audio_metadata.dart';
import '../data/local/app_settings.dart';
import '../data/local/song_weight_store.dart';
import '../services/selfmusic_audio_handler.dart';

/// 按源 key 解析播放源的函数：`server` → 服务器代理源；`webdav:<name>` → 对应直连源。
typedef SourceResolver = MusicSource? Function(String sourceKey);

/// 播放模式（stage2.md §3）。
enum PlayMode { sequence, loopList, loopOne, weighted }

/// 睡眠定时模式（播放页「睡眠」弹窗）。
enum SleepTimerKind { time, duration, count, endOfList }

extension PlayModeParse on PlayMode {
  /// 从存储值（settings.md §3.2 `play_mode_default`）解析；未知值回退 sequence。
  static PlayMode fromStored(String? v) => PlayMode.values.firstWhere(
        (m) => m.name == v,
        orElse: () => PlayMode.sequence,
      );
}

/// 全局播放状态：统一持有 AudioPlayer 与播放队列，供播放页与队列面板共享。
///
/// 阶段 2（stage2.md §2/§3/§7）：
/// - 四种播放模式（顺序/列表循环/单曲循环/加权随机）。
/// - 加权随机：每步从队列全量（排除上一首）按 factor 权重采样，不连续同一首。
/// - 事件采集：complete(≥70%)/skip(<70%) → SongWeightStore 调权。
/// - 断点：节流持久化 play_state，启动恢复为暂停态。
class PlayerProvider extends ChangeNotifier {
  static const double completeRatio = 0.7;

  late AudioPlayer player;
  List<Song> _queue = [];
  int _idx = 0;
  Song? _current;
  MusicSource? _curSource;
  SourceResolver? _resolver;
  LocalIndex? _index;
  SongWeightStore? _weight;
  AppSettings? _appSettings;
  void Function(MusicSource src, Song s)? _onTrackStarted;
  String? error;
  SelfMusicAudioHandler? _audioHandler;

  /// 播放时懒补全元数据：正在补全的歌（sourceKey|sourceRef）去重集合。
  final Set<String> _enriching = {};

  /// 关联 audio_service 通知栏处理器（settings.md §3.6）：状态变化时回推媒体信息。
  void attachAudioHandler(SelfMusicAudioHandler handler) {
    _audioHandler = handler;
    handler.attach(this);
  }

  /// 与 [main] 中可选的 audio_service 处理器接线（未启用通知栏控制时为空）。
  void attachAudioHandlerIfAny(SelfMusicAudioHandler? handler) {
    if (handler != null) attachAudioHandler(handler);
  }

  void _syncSystemMedia() => _audioHandler?.sync();

  PlayMode _mode = PlayMode.sequence;
  DateTime? _lastStateSave;
  bool _restored = false;

  Timer? _fadeTimer;
  bool _fadingPause = false;
  AndroidEqualizer? _eq;

  // ---------- 睡眠定时（播放页「睡眠」） ----------

  Timer? _sleepTick;
  SleepTimerKind? _sleepKind;
  DateTime? _sleepUntil;          // 指定时间：目标时刻（可含次日）
  DateTime? _sleepDeadline;       // 指定时长：倒计时截止时刻
  int _sleepCountLeft = 0;        // 指定曲数：剩余曲目数
  bool _sleepPlayThrough = false; // 播放完最后的曲目（到点不中断当前曲）
  bool _sleepPendingStop = false; // play-through 已触发，等当前曲放完暂停

  bool get sleepTimerActive => _sleepKind != null;

  SleepTimerKind? get sleepMode => _sleepKind;

  /// 指定时间模式下目标时刻（null 表示未设置）。
  DateTime? get sleepUntilTime => _sleepUntil;

  /// 指定曲数模式下剩余曲数。
  int get sleepCountLeft => _sleepCountLeft;

  /// 是否「播放完最后的曲目」。
  bool get sleepPlayThrough => _sleepPlayThrough;

  /// 倒计时剩余分钟（指定时长模式，随秒跳变取整）。
  int get sleepMinutes {
    if (_sleepKind == SleepTimerKind.duration && _sleepDeadline != null) {
      final rem = _sleepDeadline!
          .difference(DateTime.now())
          .inMilliseconds;
      return rem <= 0 ? 0 : (rem / 60000).ceil();
    }
    return 0;
  }

  /// 当前定时的可读摘要（用于按钮 tooltip / 弹窗标识）。
  String? get sleepSummaryText => switch (_sleepKind) {
        SleepTimerKind.time => _sleepUntil == null
            ? null
            : '到 ${_fmtTime(_sleepUntil!)} 停止'
                '${_sleepPlayThrough ? '（播完当前曲）' : ''}',
        SleepTimerKind.duration => '$sleepMinutes 分钟后停止'
            '${_sleepPlayThrough ? '（播完当前曲）' : ''}',
        SleepTimerKind.count => '播放 $_sleepCountLeft 首后停止'
            '${_sleepPlayThrough ? '（播完当前曲）' : ''}',
        SleepTimerKind.endOfList => '列表结尾停止',
        null => null,
      };

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// 指定时间：到 [target] 时刻停止（早于当前时间视为次日）。
  void setSleepTime(DateTime target, {bool playThrough = false}) {
    var when = target;
    if (!when.isAfter(DateTime.now())) when = when.add(const Duration(days: 1));
    _setSleepStart();
    _sleepKind = SleepTimerKind.time;
    _sleepUntil = when;
    _sleepPlayThrough = playThrough;
    _startSleepTick();
    notifyListeners();
  }

  /// 指定时长：倒计时 [duration] 后停止。
  void setSleepDuration(Duration duration, {bool playThrough = false}) {
    if (duration.inSeconds <= 0) {
      cancelSleepTimer();
      return;
    }
    _setSleepStart();
    _sleepKind = SleepTimerKind.duration;
    _sleepDeadline = DateTime.now().add(duration);
    _sleepPlayThrough = playThrough;
    _startSleepTick();
    notifyListeners();
  }

  /// 指定曲数：再播放 [count] 首后停止。
  void setSleepCount(int count, {bool playThrough = false}) {
    _setSleepStart();
    _sleepKind = SleepTimerKind.count;
    _sleepCountLeft = count > 0 ? count : 0;
    _sleepPlayThrough = playThrough;
    notifyListeners();
  }

  /// 列表结尾：播完队列最后一首即停止（天然播完）。
  void setSleepEndOfList() {
    _setSleepStart();
    _sleepKind = SleepTimerKind.endOfList;
    _sleepPlayThrough = true;
    notifyListeners();
  }

  void cancelSleepTimer() {
    _clearSleep();
    notifyListeners();
  }

  void _setSleepStart() {
    _sleepTick?.cancel();
    _sleepPendingStop = false;
    _sleepUntil = null;
    _sleepDeadline = null;
    _sleepCountLeft = 0;
  }

  void _clearSleep() {
    _sleepTick?.cancel();
    _sleepTick = null;
    _sleepKind = null;
    _sleepUntil = null;
    _sleepDeadline = null;
    _sleepCountLeft = 0;
    _sleepPlayThrough = false;
    _sleepPendingStop = false;
  }

  /// 时间/时长模式：每秒检查到期；时长模式剩余分钟变化时刷新 UI。
  void _startSleepTick() {
    _sleepTick?.cancel();
    var shown = sleepMinutes;
    _sleepTick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_sleepPendingStop) {
        t.cancel();
        return;
      }
      final kind = _sleepKind;
      if (kind == SleepTimerKind.time) {
        final until = _sleepUntil;
        if (until != null && !DateTime.now().isBefore(until)) {
          t.cancel();
          unawaited(_stopForSleep(atBoundary: false));
        }
      } else if (kind == SleepTimerKind.duration) {
        final dl = _sleepDeadline;
        if (dl != null && !DateTime.now().isBefore(dl)) {
          t.cancel();
          unawaited(_stopForSleep(atBoundary: false));
        } else {
          final m = sleepMinutes;
          if (m != shown) {
            shown = m;
            notifyListeners();
          }
        }
      }
    });
  }

  /// 到期执行：play-through 时等当前曲放完；否则立即暂停。
  Future<void> _stopForSleep({required bool atBoundary}) async {
    if (player.playing && _sleepPlayThrough && !atBoundary && !_sleepPendingStop) {
      _sleepPendingStop = true;
      _sleepTick?.cancel();
      notifyListeners();
      return;
    }
    _clearSleep();
    await _pauseNowForSleep();
  }

  Future<void> _pauseNowForSleep() async {
    if (player.playing) await _fadeOutThenPause();
    notifyListeners();
    _syncSystemMedia();
  }

  /// 曲目自然播放结束时被调用：返回 true 表示由睡眠定时接管（不再自动切歌）。
  bool _handleTrackCompletedSleep() {
    if (_sleepPendingStop) {
      _sleepPendingStop = false;
      _clearSleep();
      unawaited(_pauseNowForSleep());
      return true;
    }
    final kind = _sleepKind;
    if (kind == SleepTimerKind.count) {
      if (_sleepCountLeft > 0) _sleepCountLeft--;
      if (_sleepCountLeft <= 0) {
        _clearSleep();
        unawaited(_pauseNowForSleep());
        return true;
      }
      notifyListeners();
      return false;
    }
    if (kind == SleepTimerKind.endOfList &&
        _idx == _queue.length - 1 &&
        _current != null) {
      _clearSleep();
      unawaited(_pauseNowForSleep());
      return true;
    }
    return false;
  }

  PlayerProvider() {
    player = _buildPlayer();
    _setupPlayerStreams();
  }

  /// 按用户设置构造播放器：均衡器（Android 原生 AndroidEqualizer）与音频焦点开关
  /// 均需在构造时注入（settings.md §3.2/§3.6），设置变动时经 [applyAudioConfig] 重建。
  AudioPlayer _buildPlayer() {
    final s = _appSettings;
    final eqEnabled = !kIsWeb && Platform.isAndroid && (s?.equalizerEnabled ?? false);
    _eq = eqEnabled ? AndroidEqualizer() : null;
    return AudioPlayer(
      handleInterruptions: s?.audioFocusEnabled ?? true,
      audioPipeline: _eq != null
          ? AudioPipeline(androidAudioEffects: [_eq!])
          : null,
    );
  }

  void _setupPlayerStreams() {
    player.playerStateStream.listen((st) {
      if (st.processingState == ProcessingState.completed) {
        final finished = _current;
        if (finished != null) {
          _emitWeight(finished, completed: true,
              position: player.duration ?? Duration.zero);
        }
        if (_handleTrackCompletedSleep()) return;
        _advance();
      }
    });
    player.positionStream.listen(_maybeSaveState);
  }

  /// 应用音频相关设置（均衡器/音频焦点/淡入淡出开关变化）：重建播放器并恢复当前曲目。
  Future<void> applyAudioConfig() async {
    if (_current == null) {
      _fadeTimer?.cancel();
      await player.dispose();
      player = _buildPlayer();
      _setupPlayerStreams();
      notifyListeners();
      return;
    }
    final pos = player.position;
    final wasPlaying = player.playing;
    final current = _current!;
    final source = _curSource;
    _fadeTimer?.cancel();
    await player.dispose();
    player = _buildPlayer();
    _setupPlayerStreams();
    await _play(current, source: source, play: wasPlaying);
    try {
      await player.seek(pos);
    } catch (_) {}
    notifyListeners();
  }

  // ---------- 淡入淡出（settings.md §3.2） ----------

  bool get _fadeOn => _appSettings?.fadeEnabled ?? false;

  Duration get _fadeDuration => Duration(
      milliseconds: _appSettings?.fadeDurationMs ?? 2000);

  /// 淡入：从 0 渐变到 1（关闭时直接置 1）。
  void _fadeIn() {
    _fadeTimer?.cancel();
    if (!_fadeOn) {
      player.setVolume(1.0);
      return;
    }
    final dur = _fadeDuration.inMilliseconds;
    final start = DateTime.now();
    player.setVolume(0.0);
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 16), (t) async {
      final el = DateTime.now().difference(start).inMilliseconds;
      final p = dur <= 0 ? 1.0 : (el / dur).clamp(0.0, 1.0);
      await player.setVolume(p);
      if (p >= 1.0) t.cancel();
    });
  }

  /// 淡出后真正暂停（关闭淡入淡出时直接暂停）。
  Future<void> _fadeOutThenPause() async {
    if (!_fadeOn) {
      await player.pause();
      return;
    }
    _fadeTimer?.cancel();
    _fadingPause = true;
    final dur = _fadeDuration.inMilliseconds;
    final start = DateTime.now();
    player.setVolume(1.0);
    await Future.delayed(const Duration(milliseconds: 16));
    while (true) {
      final el = DateTime.now().difference(start).inMilliseconds;
      final v = (1.0 - el / dur).clamp(0.0, 1.0);
      await player.setVolume(v);
      if (v <= 0.0) break;
      await Future.delayed(const Duration(milliseconds: 16));
    }
    await player.pause();
    await player.setVolume(1.0);
    _fadingPause = false;
  }

  // ---------- 均衡器（settings.md §3.2，仅 Android） ----------

  /// 应用存储的频段增益（播放器装载完成、效果激活后调用）。
  Future<void> _applyEqualizerBands() async {
    final eq = _eq;
    final s = _appSettings;
    if (eq == null || s == null || !s.equalizerEnabled) return;
    try {
      final params = await eq.parameters;
      final bands = s.eqBands;
      for (var i = 0; i < bands.length && i < params.bands.length; i++) {
        final gain = bands[i]
            .clamp(params.minDecibels.toDouble(), params.maxDecibels.toDouble());
        await params.bands[i].setGain(gain);
      }
      await eq.setEnabled(true);
    } catch (_) {
      // 平台不支持 / 尚未激活时静默跳过。
    }
  }

  /// 单个频段增益写入（UI 拖动即时生效）；同时持久化。
  Future<void> setEqBand(int index, double db) async {
    final s = _appSettings;
    if (s == null) return;
    final bands = s.eqBands;
    bands[index] = db;
    s.eqBands = bands;
    final params = _eq == null ? null : await _eq!.parameters;
    if (params != null && index < params.bands.length) {
      try {
        var gain = db;
        if (gain < params.minDecibels) gain = params.minDecibels;
        if (gain > params.maxDecibels) gain = params.maxDecibels;
        await params.bands[index].setGain(gain);
      } catch (_) {}
    }
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

  /// 关联用户设置：套用默认播放模式（settings.md §3.2 `play_mode_default`），
  /// 之后每次切模式写回。
  void attachAppSettings(AppSettings settings) {
    _appSettings = settings;
    final m = PlayModeParse.fromStored(settings.playModeDefault);
    if (_mode != m) _mode = m;
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
    final s = _appSettings;
    if (s != null && s.playModeDefault != m.name) {
      s.playModeDefault = m.name;
    }
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
    // 睡眠定时处于「等当前曲放完」的挂起态时，手动切歌视为用户接管：取消定时。
    if (_sleepPendingStop) {
      _clearSleep();
      notifyListeners();
    }
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
      if (play) {
        await player.play();
        _fadeIn();
      }
      unawaited(_applyEqualizerBands());
      _current = s;
      _curSource = src;
      _saveState(player.position);
      if (src != null) _onTrackStarted?.call(src, s);
      // 最小扫描的歌没存额外元数据（时长/流派/年份/封面），播放时懒补全。
      if (src != null && src.supportsDirect && s.duration == null) {
        unawaited(_enrichLazily(s, src));
      }
      notifyListeners();
      _syncSystemMedia();
    } catch (e) {
      error = e.toString();
      notifyListeners();
    }
  }

  /// 直连源播放：优先离线缓存文件，其次原生 URL（Range/seek 更稳），
  /// 最后回落到自建字节流 [DirectAudioSource]。
  Future<void> _playDirect(Song s, MusicSource src) async {
    final cached = await src.cachedFilePath(s);
    if (cached != null) {
      await player.setFilePath(cached);
      return;
    }
    final direct = src.directStream(s);
    if (direct != null) {
      await player.setUrl(direct.url, headers: direct.headers);
      return;
    }
    await player.setAudioSource(DirectAudioSource(source: src, song: s));
  }

  /// 懒补全：播放后把解析出的完整元数据（时长/流派/曲目/年份/封面）回填索引。
  /// 从头读取（本地直读 / WebDAV Range GET），失败静默不影响播放。
  Future<void> _enrichLazily(Song s, MusicSource src) async {
    final idx = _index;
    if (idx == null) return;
    final k = '${s.sourceKey}\u0000${s.sourceRef}';
    if (_enriching.contains(k)) return;
    _enriching.add(k);
    try {
      const headMax = 256 * 1024;
      final head = <int>[];
      final opened = await src.open(s, range: const IntRange(0, headMax));
      await for (final chunk in opened.stream) {
        head.addAll(chunk);
        if (head.length >= headMax) break;
      }
      final meta = parseAudioHead(
          Uint8List.fromList(head), s.format ?? '', s.fileSize);
      String? coverPath;
      final cover = meta?.cover;
      if (cover != null && cover.isNotEmpty) {
        coverPath = idx.persistCover(cover, s.sourceRef);
      }
      idx.enrichSong(s.sourceKey, s.sourceRef,
          duration: meta?.duration,
          genre: meta?.genre,
          trackNo: meta?.trackNo,
          year: meta?.year,
          coverPath: coverPath);
    } catch (_) {
      // 后台补全失败不影响播放。
    } finally {
      _enriching.remove(k);
    }
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
    if (_fadingPause) return;
    if (player.playing) {
      await _fadeOutThenPause();
    } else {
      await player.play();
      _fadeIn();
    }
    notifyListeners();
    _syncSystemMedia();
  }

  /// 通知栏「播放」回调（settings.md §3.6）。
  Future<void> resumeFromNotifier() async {
    await player.play();
    _fadeIn();
    notifyListeners();
    _syncSystemMedia();
  }

  /// 通知栏「暂停/停止」回调（settings.md §3.6）。
  Future<void> pauseFromNotifier() async {
    await _fadeOutThenPause();
    notifyListeners();
    _syncSystemMedia();
  }

  Future<void> seek(Duration d) async {
    await player.seek(d);
    _syncSystemMedia();
  }

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
      _syncSystemMedia();
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
    _fadeTimer?.cancel();
    _sleepTick?.cancel();
    _saveState(player.position);
    player.dispose();
    super.dispose();
  }
}