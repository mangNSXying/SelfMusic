import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../providers/direct_source_manager.dart';
import '../providers/library_provider.dart';
import '../providers/navigation_provider.dart';
import '../services/online_music/online_music_models.dart';
import '../services/online_music/online_music_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_toast.dart';

/// 在线音乐搜索（L1）：搜索 sidecar → 下载/校验 → 上传到曲库 → 增量扫描。
class OnlineMusicScreen extends StatefulWidget {
  const OnlineMusicScreen({super.key});

  @override
  State<OnlineMusicScreen> createState() => _OnlineMusicScreenState();
}

class _SourceStatus {
  final String label;
  bool loading;
  int count;
  bool timedOut;
  String? error;

  _SourceStatus(this.label,
      {this.loading = false,
      this.count = 0,
      this.timedOut = false,
      this.error});
}

class _DownloadProgress {
  final String title;
  final String detail;
  final double? value;
  final String? error;

  const _DownloadProgress({
    required this.title,
    required this.detail,
    this.value,
    this.error,
  });
}

class _OnlineMusicScreenState extends State<OnlineMusicScreen> {
  static const List<OnlineSourceInfo> _fallbackSources = [
    OnlineSourceInfo(id: 'QQMusicClient', label: 'QQ音乐', isDefault: true),
    OnlineSourceInfo(id: 'KuwoMusicClient', label: '酷我音乐', isDefault: true),
    OnlineSourceInfo(id: 'MiguMusicClient', label: '咪咕音乐', isDefault: true),
  ];

  final TextEditingController _queryCtrl = TextEditingController();
  final Set<String> _selectedSources = {};
  final List<OnlineTrack> _tracks = [];
  final Map<String, _SourceStatus> _status = {};
  final Set<String> _busyTokens = {};
  final Set<String> _doneTokens = {};

  late AppSettings _settings;
  late OnlineMusicService _service;
  late DirectSourceManager _direct;
  late LibraryProvider _library;

  List<OnlineSourceInfo> _sources = _fallbackSources;
  CancelToken? _searchCancel;
  bool _initialized = false;
  bool _searching = false;
  String? _error;
  int _generation = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _settings = context.read<DirectSourceManager>().settings;
    _service = context.read<OnlineMusicService>();
    _direct = context.read<DirectSourceManager>();
    _library = context.read<LibraryProvider>();
    _selectedSources
      ..clear()
      ..addAll(_parseSources(_settings.onlineMusicSources));
    _loadSources();
  }

  Set<String> _parseSources(String raw) =>
      raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();

  bool get _configured =>
      _settings.onlineMusicEnabled && _settings.onlineMusicBaseUrl.isNotEmpty;

  Future<void> _loadSources() async {
    if (!_configured) return;
    try {
      final sources = await _service.fetchSources();
      if (!mounted || sources.isEmpty) return;
      setState(() {
        _sources = sources;
        final available = sources.map((s) => s.id).toSet();
        _selectedSources.retainWhere(available.contains);
        if (_selectedSources.isEmpty) {
          _selectedSources.addAll(
            sources.where((s) => s.isDefault).map((s) => s.id),
          );
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '无法连接 sidecar：$e');
    }
  }

  String _labelFor(String source) {
    for (final item in _sources) {
      if (item.id == source) return item.label;
    }
    return source.replaceAll('MusicClient', '');
  }

  void _openSettings() {
    final nav = context.read<NavigationProvider>();
    Navigator.of(context).pop();
    nav.openSettings(SettingsItem.online);
  }

  Future<void> _search() async {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty) return;
    if (_selectedSources.isEmpty) {
      AppToast.show('请至少选择一个音乐源', isError: true);
      return;
    }
    FocusScope.of(context).unfocus();
    _searchCancel?.cancel('new-search');
    final cancel = CancelToken();
    _searchCancel = cancel;
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _tracks.clear();
      _status.clear();
      _error = null;
      for (final source in _selectedSources) {
        _status[source] = _SourceStatus(_labelFor(source), loading: true);
      }
    });
    try {
      final stream = _service.search(
        query: query,
        sources: _selectedSources.toList(),
        limit: 10,
        cancelToken: cancel,
      );
      await for (final event in stream) {
        if (!mounted || generation != _generation) return;
        switch (event) {
          case OnlineSourceStart():
            setState(() {
              _status[event.source] =
                  _SourceStatus(event.sourceLabel, loading: true);
            });
          case OnlineSourceDone():
            setState(() {
              final old = _status[event.source];
              _status[event.source] = _SourceStatus(
                old?.label ?? _labelFor(event.source),
                count: event.count,
                timedOut: event.timedOut,
              );
            });
          case OnlineSourceError():
            setState(() {
              final old = _status[event.source];
              _status[event.source] = _SourceStatus(
                old?.label ?? _labelFor(event.source),
                error: event.message,
              );
            });
          case OnlineTrackEvent():
            setState(() {
              if (!_tracks.any((t) => t.token == event.track.token)) {
                _tracks.add(event.track);
              }
            });
          case OnlineSearchDone():
            setState(() => _searching = false);
        }
      }
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      if (mounted && generation == _generation) {
        setState(() => _error = '搜索失败：$e');
      }
    } on OnlineMusicException catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = '搜索失败：$e');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _searching = false);
        _searchCancel = null;
      }
    }
  }

  void _stopSearch() {
    _generation++;
    _searchCancel?.cancel('user-stop');
    setState(() => _searching = false);
  }

  List<OnlineTrack> get _visibleTracks {
    final maxBytes = _settings.onlineMusicMaxSizeMb * 1024 * 1024;
    var list = _tracks.where((track) {
      if (maxBytes <= 0 || track.sizeBytes <= 0) return true;
      return track.sizeBytes <= maxBytes;
    }).toList();
    if (_settings.onlineMusicPreferLossless) {
      list = List<OnlineTrack>.from(list)
        ..sort((a, b) {
          if (a.lossless == b.lossless) return 0;
          return a.lossless ? -1 : 1;
        });
    }
    return list;
  }

  int get _hiddenBySize {
    final maxBytes = _settings.onlineMusicMaxSizeMb * 1024 * 1024;
    if (maxBytes <= 0) return 0;
    return _tracks
        .where((t) => t.sizeBytes > 0 && t.sizeBytes > maxBytes)
        .length;
  }

  String? _resolveTargetSourceKey() {
    final writable =
        _direct.sources.where((source) => source.supportsWrite).toList();
    if (writable.isEmpty) return null;
    final configured = _settings.onlineMusicTargetSource;
    if (configured.isNotEmpty &&
        writable.any((source) => source.key == configured)) {
      return configured;
    }
    final fallback = writable.first.key;
    _settings.onlineMusicTargetSource = fallback;
    return fallback;
  }

  String _safeUploadName(String raw, String ext, String fallbackTitle) {
    var name = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (name.isEmpty) {
      name = '${fallbackTitle.isEmpty ? '未知曲目' : fallbackTitle}.$ext';
    }
    if (name.length > 180) {
      final suffix = p.extension(name);
      name = '${name.substring(0, 150).trim()}$suffix';
    }
    return name;
  }

  Future<void> _download(OnlineTrack track) async {
    if (_busyTokens.contains(track.token) ||
        _doneTokens.contains(track.token)) {
      return;
    }
    final sourceKey = _resolveTargetSourceKey();
    if (sourceKey == null) {
      AppToast.show('请先在「播放源」中添加支持写入的源', isError: true);
      return;
    }
    final progress = ValueNotifier<_DownloadProgress>(const _DownloadProgress(
      title: '正在准备',
      detail: '正在向 sidecar 请求下载…',
    ));
    BuildContext? dialogContext;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) {
        dialogContext = c;
        return AlertDialog(
          title: const Text('下载到曲库'),
          content: SizedBox(
            width: 320,
            child: ValueListenableBuilder<_DownloadProgress>(
              valueListenable: progress,
              builder: (_, value, __) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value.title,
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: value.value),
                  const SizedBox(height: 8),
                  Text(value.detail,
                      style: Theme.of(context).textTheme.bodySmall),
                  if (value.error != null) ...[
                    const SizedBox(height: 8),
                    Text(value.error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            ValueListenableBuilder<_DownloadProgress>(
              valueListenable: progress,
              builder: (_, value, __) => value.error == null
                  ? const SizedBox.shrink()
                  : TextButton(
                      onPressed: () {
                        if (dialogContext != null && dialogContext!.mounted) {
                          Navigator.of(dialogContext!).pop();
                        }
                      },
                      child: const Text('关闭'),
                    ),
            ),
          ],
        );
      },
    ));
    setState(() => _busyTokens.add(track.token));
    Directory? tempDir;
    try {
      var job = await _service.createFetch(track.token);
      final deadline = DateTime.now().add(const Duration(minutes: 8));
      while (true) {
        job = await _service.fetchStatus(job.id);
        if (job.isReady) break;
        if (job.isError) {
          throw OnlineMusicException(
              job.error.isEmpty ? 'sidecar 下载失败' : job.error);
        }
        if (DateTime.now().isAfter(deadline)) {
          throw const OnlineMusicException('下载超时，请重试');
        }
        progress.value = _progressFromJob(job, track);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      final maxBytes = _settings.onlineMusicMaxSizeMb * 1024 * 1024;
      if (maxBytes > 0 && job.sizeBytes > maxBytes) {
        throw OnlineMusicException('文件 ${_fmtBytes(job.sizeBytes)} 超过单曲大小上限');
      }

      final tmp = await getTemporaryDirectory();
      tempDir = Directory(p.join(tmp.path, 'selfmusic_online', job.id));
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
      await tempDir.create(recursive: true);
      final filename = _safeUploadName(job.filename, job.ext, job.title);
      final savePath = p.join(tempDir.path, filename);
      progress.value = _DownloadProgress(
        title: '正在取回文件',
        detail: '$filename（${_fmtBytes(job.sizeBytes)}）',
        value: 0,
      );
      await _service.downloadFile(
        job.id,
        savePath,
        onProgress: (received, total) {
          final totalBytes = total > 0 ? total : job.sizeBytes;
          progress.value = _DownloadProgress(
            title: '正在取回文件',
            detail: '$filename（${_fmtBytes(received)}'
                '${totalBytes > 0 ? ' / ${_fmtBytes(totalBytes)}' : ''}）',
            value:
                totalBytes > 0 ? (received / totalBytes).clamp(0.0, 1.0) : null,
          );
        },
      );

      final folder = _settings.onlineMusicTargetFolder;
      progress.value = const _DownloadProgress(
        title: '正在上传到曲库',
        detail: '写入目标播放源…',
      );
      await _direct.ensureFolder(sourceKey, folder);
      final audio = File(savePath);
      final length = await audio.length();
      await _direct.uploadAudio(sourceKey, filename, audio.openRead(), length,
          parentRef: folder, scan: false);

      final lyric = await _service.fetchLyric(job.id).catchError((_) => null);
      if (lyric != null && lyric.trim().isNotEmpty) {
        final lrcName = '${p.basenameWithoutExtension(filename)}.lrc';
        final bytes = utf8.encode(lyric);
        try {
          await _direct.uploadSidecar(
            sourceKey,
            lrcName,
            Stream<List<int>>.value(bytes),
            bytes.length,
            parentRef: folder,
          );
        } catch (_) {
          // 歌词 sidecar 失败不影响音频入库；播放时会回退内嵌歌词。
        }
      }

      progress.value = const _DownloadProgress(
        title: '正在刷新曲库',
        detail: '增量扫描目标播放源…',
      );
      var scanFailed = false;
      try {
        await _direct.scanSource(sourceKey);
      } catch (_) {
        // 文件已上传成功；扫描可能被「仅 Wi-Fi 扫描」等门控拦下。
        scanFailed = true;
      }
      if (!scanFailed) {
        try {
          await _library.loadSongs();
        } catch (_) {
          // 扫描已完成；列表刷新失败不影响入库结果。
        }
      }
      progress.value = _DownloadProgress(
        title: scanFailed ? '已上传，待扫描' : '已入库',
        detail: scanFailed ? '文件已写入曲库；请在播放源页手动扫描或等待自动扫描' : '可以在曲库中播放了',
        value: 1,
      );
      if (mounted) {
        setState(() => _doneTokens.add(track.token));
        AppToast.show(
          scanFailed ? '已上传，等待扫描：${track.title}' : '已入库：${track.title}',
          isError: false,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (dialogContext != null && dialogContext!.mounted) {
        Navigator.of(dialogContext!).pop();
      }
    } catch (e) {
      final message = e.toString().replaceFirst('OnlineMusicException: ', '');
      progress.value = _DownloadProgress(
        title: '入库失败',
        detail: '可以关闭窗口后重试',
        error: message,
      );
      if (mounted) AppToast.error(e, '入库失败');
    } finally {
      if (mounted) setState(() => _busyTokens.remove(track.token));
      try {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  _DownloadProgress _progressFromJob(OnlineFetchJob job, OnlineTrack track) {
    final detail = job.totalBytes > 0
        ? '${_fmtBytes(job.downloadedBytes)} / ${_fmtBytes(job.totalBytes)}'
        : '等待 sidecar…';
    return switch (job.status) {
      'queued' => _DownloadProgress(
          title: '排队中',
          detail: '${track.title} · $detail',
        ),
      'downloading' => _DownloadProgress(
          title: '正在下载',
          detail: '${track.title} · $detail',
          value: job.progress,
        ),
      'verifying' => const _DownloadProgress(
          title: '正在校验音频',
          detail: 'ffmpeg 解码校验中…',
          value: 0.98,
        ),
      _ => _DownloadProgress(
          title: '处理中',
          detail: job.status,
          value: job.progress,
        ),
    };
  }

  static String _fmtBytes(int bytes) {
    if (bytes <= 0) return '未知大小';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  static String _fmtDuration(int seconds) {
    if (seconds <= 0) return '--:--';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _searchCancel?.cancel('dispose');
    _queryCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('在线搜索'),
        actions: [
          IconButton(
            tooltip: '在线音乐设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _configured ? _buildContent() : _buildSetup(context),
      ),
    );
  }

  Widget _buildSetup(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 56, color: cs.outline),
            const SizedBox(height: 16),
            const Text('在线音乐未启用', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              '需要先运行 online-music sidecar，并在设置中填写 sidecar 地址和 token。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('去设置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final tracks = _visibleTracks;
    final hidden = _hiddenBySize;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryCtrl,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    hintText: '搜索在线歌曲（歌名 / 歌手）',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: _searching ? _stopSearch : _search,
                icon: Icon(_searching ? Icons.stop : Icons.search),
                label: Text(_searching ? '停止' : '搜索'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final source in _sources)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(source.label),
                    selected: _selectedSources.contains(source.id),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _selectedSources.add(source.id);
                        } else {
                          _selectedSources.remove(source.id);
                        }
                        _settings.onlineMusicSources =
                            _selectedSources.join(',');
                      });
                    },
                  ),
                ),
            ],
          ),
        ),
        if (_status.isNotEmpty)
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final entry in _status.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Chip(
                      visualDensity: VisualDensity.compact,
                      avatar: entry.value.loading
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child:
                                  CircularProgressIndicator(strokeWidth: 1.5),
                            )
                          : null,
                      label: Text(
                        entry.value.error != null
                            ? '${entry.value.label}：失败'
                            : '${entry.value.label}：${entry.value.loading ? '…' : '${entry.value.count} 首'}'
                                '${entry.value.timedOut ? '（超时）' : ''}',
                        style: TextStyle(
                          fontSize: 11,
                          color: entry.value.error != null
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                Icon(Icons.error_outline,
                    size: 16, color: Theme.of(context).colorScheme.error),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '已隐藏 $hidden 首超过大小上限的结果（可在设置中调整）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        const SizedBox(height: 4),
        Expanded(
          child: tracks.isEmpty
              ? _buildEmpty()
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: tracks.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, index) => _buildTrack(tracks[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    if (_searching) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在搜索…'),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.music_note_outlined,
              size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 8),
          Text(
            _tracks.isEmpty && _status.isEmpty ? '输入关键词搜索在线音乐' : '没有符合条件的结果',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildTrack(OnlineTrack track) {
    final busy = _busyTokens.contains(track.token);
    final done = _doneTokens.contains(track.token);
    final sourceLabel =
        track.sourceLabel.isEmpty ? _labelFor(track.source) : track.sourceLabel;
    final details = [
      if (track.artist.isNotEmpty) track.artist,
      if (track.album.isNotEmpty && track.album != 'NULL') track.album,
      _fmtDuration(track.durationS),
      track.ext.toUpperCase(),
      _fmtBytes(track.sizeBytes),
      sourceLabel,
      if (track.lossless) '无损',
    ].join(' · ');
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        child: Icon(track.lossless ? Icons.album : Icons.music_note, size: 20),
      ),
      title: Text(
        track.title.isEmpty ? '未知曲目' : track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: SizedBox(
        width: 96,
        child: busy
            ? const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : done
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Icon(Icons.check_circle, size: 18, color: Colors.green),
                      SizedBox(width: 4),
                      Text('已入库', style: TextStyle(fontSize: 12)),
                    ],
                  )
                : FilledButton.tonalIcon(
                    onPressed: () => _download(track),
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('下载', style: TextStyle(fontSize: 12)),
                  ),
      ),
    );
  }
}
