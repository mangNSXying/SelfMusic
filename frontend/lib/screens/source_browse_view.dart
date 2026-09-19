import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../data/sources/scan_worker.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';
import '../services/server_settings.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/app_toast.dart';
import '../widgets/section_swipe.dart';
import '../widgets/list_selection.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_tile.dart';

/// 源内浏览组件（文件夹式导航）：在 AppContent 内容区原地渲染。
///
/// - 直连源：本地索引（扫描后）检索，提供「扫描」按钮建立/刷新本地索引。
/// - 服务端代理源：从后端 /api 拉取整体库（异步），无「扫描」按钮。
class SourceBrowseView extends StatefulWidget {
  final String sourceKey;
  const SourceBrowseView({super.key, required this.sourceKey});

  @override
  State<SourceBrowseView> createState() => _SourceBrowseViewState();
}

class _SourceBrowseViewState extends State<SourceBrowseView> {
  String _query = '';
  bool _scanning = false;
  bool _loading = false;
  List<Song> _songs = [];
  ScanProgress? _progress;
  StreamSubscription<ScanProgress>? _progressSub;
  final Selection<String> _sel = Selection<String>();

  bool get _isProxy =>
      context.read<DirectSourceManager>().isProxy(widget.sourceKey);

  /// 代理模式但「服务端」地址尚未配置。
  bool get _serverUnconfigured =>
      _isProxy && context.read<ServerSettings>().baseUrl.isEmpty;

  @override
  void initState() {
    super.initState();
    if (_isProxy) {
      if (!_serverUnconfigured) _loadProxy();
    } else {
      // 打开直连源即自动触发扫描（增量式，mtime/size 未变则快速跳过），
      // 建立/刷新该源本地索引。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final source = context.read<DirectSourceManager>().sourceByKey(widget.sourceKey);
        if (source != null && !_scanning) _scan(source);
      });
    }
  }

  Future<void> _loadProxy() async {
    if (_serverUnconfigured) return;
    setState(() {
      _loading = true;
      _sel.cancel();
    });
    try {
      final direct = context.read<DirectSourceManager>();
      final songs =
          await direct.fetchSongsFor(widget.sourceKey, query: _query);
      if (mounted) setState(() => _songs = songs);
    } catch (e) {
      AppToast.error(e, '拉取失败');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _scan(MusicSource source) async {
    final lib = context.read<LibraryProvider>();
    final manager = context.read<DirectSourceManager>();
    setState(() {
      _scanning = true;
      _progress = null;
      _sel.cancel();
    });
    _progressSub?.cancel();
    _progressSub = manager.scanProgressStream.listen((p) {
      if (mounted) setState(() => _progress = p);
    });
    try {
      final summary = await manager.scanSource(widget.sourceKey);
      // 扫描后刷新全局合并库，使歌曲/专辑/歌手栏目同步出现该源曲目。
      await lib.loadSongs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(summary.cancelled
                  ? '扫描已取消'
                  : '扫描完成：新增 ${summary.added} 首，共 ${summary.total} 首')),
        );
      }
    } catch (e) {
      AppToast.error(e, '扫描失败');
    } finally {
      _progressSub?.cancel();
      _progressSub = null;
      if (mounted) {
        setState(() {
          _scanning = false;
          _progress = null;
        });
      }
    }
  }

  void _cancel() {
    final manager = context.read<DirectSourceManager>();
    manager.cancelScan(widget.sourceKey);
  }

  void _toggle(String key) => setState(() {
        _sel.active = true;
        _sel.toggle(key);
      });

  Future<void> _playSelected(
      BuildContext c, MusicSource source, List<Song> songs) async {
    final selSongs = selectedSongs(_sel, songs);
    _sel.cancel();
    await _play(c, source, selSongs, 0);
  }

  void _addToPlaylistSelected(List<Song> songs) {
    final selSongs = selectedSongs(_sel, songs);
    _sel.cancel();
    showAddToPlaylistSheetForSongs(context, selSongs);
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _play(
      BuildContext c, MusicSource source, List<Song> songs, int i) async {
    final player = c.read<PlayerProvider>();
    final nav = c.read<NavigationProvider>();
    // 先进播放页（立即切过去），播放是否成功由 toast/红字提示，避免卡在列表里。
    nav.openPlayer();
    try {
      await player.playQueue(songs, index: i, source: source);
    } catch (_) {
      // playQueue 内部捕获音频错误；此处分外异常也保证导航已生效。
    }
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavigationProvider>();
    final direct = context.watch<DirectSourceManager>();
    final source = direct.sourceByKey(widget.sourceKey);
    if (source == null) {
      return const Center(child: Text('源不存在'));
    }
    final isProxy = _isProxy;
    final songs = isProxy
        ? _songs
        : direct.songsOf(widget.sourceKey, query: _query);
    final count = isProxy ? _songs.length : direct.countOf(widget.sourceKey);

    return SectionSwipe(
      child: Column(
        children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回播放源',
                onPressed: nav.exitSource,
              ),
              const SizedBox(width: 4),
              Icon(Icons.folder_outlined,
                  size: 20, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (isProxy)
                TextButton.icon(
                  onPressed: _loading ? null : _loadProxy,
                  icon: const Icon(Icons.sync, size: 18),
                  label: const Text('刷新'),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: _scanning ? null : () => _scan(source),
                      icon: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 18),
                      label: const Text('扫描'),
                    ),
                    if (_scanning)
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: '取消扫描',
                        onPressed: _cancel,
                      ),
                  ],
                ),
            ],
          ),
        ),
        if (_sel.active)
          SelectionBar(
            total: songs.length,
            selectedCount: _sel.of(songs.map(songKey)).length,
            onToggleAll: () =>
                setState(() => _sel.setAll(songs.map(songKey))),
            onCancel: () => setState(_sel.cancel),
            actions: [
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: '播放选中',
                onPressed: _sel.isEmpty
                    ? null
                    : () => _playSelected(context, source, songs),
              ),
              IconButton(
                icon: const Icon(Icons.playlist_add),
                tooltip: '加入歌单',
                onPressed: _sel.isEmpty
                    ? null
                    : () => _addToPlaylistSelected(songs),
              ),
            ],
          ),
        // 扫描进度：枚举阶段为不确定进度条；探测阶段显示比例与数字。
        if (_scanning && !isProxy)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Column(
              children: [
                LinearProgressIndicator(
                  value: _progress?.value,
                ),
                if (_progress != null && !_progress!.listing)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '已处理 ${_progress!.done}/${_progress!.total}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 16),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: '搜索该源曲目（标题/歌手/专辑）',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    setState(() => _query = v);
                    if (isProxy) _loadProxy();
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              isProxy
                  ? '服务端代理 · 共 $count 首'
                  : '已索引 $count 首 · ${source.name}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        const Divider(height: 16),
        if (direct.error != null && !isProxy)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(direct.error!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : songs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.library_music_outlined,
                              size: 64,
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.4)),
                          const SizedBox(height: 12),
                          Text(
                            _serverUnconfigured
                                ? '代理模式需要先配置后端地址\n请到设置 → 「服务端」填写后端地址'
                                : (isProxy
                                    ? '服务端暂无可播放曲目'
                                    : '暂无索引曲目，点击"扫描"建立本地索引'),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: songs.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, indent: 72),
                      itemBuilder: (c, i) {
                        final s = songs[i];
                        return SongTile(
                          song: s,
                          source: source,
                          onPlay: () => _play(c, source, songs, i),
                          selectionMode: _sel.active,
                          selected: _sel.contains(songKey(s)),
                          onSelect: () => _toggle(songKey(s)),
                          onStartSelect: () { setState(() => _sel.startWith(songKey(s))); },
                        );
                      },
                    ),
        ),
        ],
      ),
    );
  }
}