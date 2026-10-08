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
import '../widgets/add_to_playlist.dart';
import '../widgets/app_toast.dart';
import '../widgets/section_swipe.dart';
import '../widgets/list_selection.dart';
import '../widgets/row_list.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_list.dart';
import '../widgets/song_row_view.dart';

/// 源内浏览组件（文件夹式导航）：在 AppContent 内容区原地渲染。
///
/// - 直连源：本地索引（扫描后）检索，提供「扫描」按钮建立/刷新本地索引。
class SourceBrowseView extends StatefulWidget {
  final String sourceKey;
  const SourceBrowseView({super.key, required this.sourceKey});

  @override
  State<SourceBrowseView> createState() => _SourceBrowseViewState();
}

class _SourceBrowseViewState extends State<SourceBrowseView> {
  String _query = '';
  bool _scanning = false;
  ScanProgress? _progress;
  StreamSubscription<ScanProgress>? _progressSub;
  final Selection<String> _sel = Selection<String>();

  /// 行级视图数据缓存（R-1）。
  final SongRowCache _rowCache = SongRowCache();

  @override
  void initState() {
    super.initState();
    // 打开直连源即自动触发扫描（增量式，mtime/size 未变则快速跳过），
    // 建立/刷新该源本地索引。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final source =
          context.read<DirectSourceManager>().sourceByKey(widget.sourceKey);
      if (source != null && !_scanning) _scan(source);
    });
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
        AppToast.show(
            summary.cancelled
                ? '扫描已取消'
                : '扫描完成：新增 ${summary.added} 首，共 ${summary.total} 首',
            isError: false);
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
      await player.playQueue(songs,
          index: i,
          source: source,
          contextKey: PlayerProvider.anchorForSource(widget.sourceKey));
    } catch (_) {
      // playQueue 内部捕获音频错误；此处分外异常也保证导航已生效。
    }
  }

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T010）：源内浏览的目标 sourceKey 由 widget 参数承载（父级路由
    // 变更会重建本组件），build 内不读取任何 NavigationProvider 字段；仅方法
    // （exitSource）经 read 调用，故不订阅导航状态、区段变更零重建。
    final nav = context.read<NavigationProvider>();
    final direct = context.watch<DirectSourceManager>();
    // watch：播放指示（标题后的 graphic_eq）要随当前播放曲变化重建。
    final player = context.watch<PlayerProvider>();
    final source = direct.sourceByKey(widget.sourceKey);
    if (source == null) {
      return const Center(child: Text('源不存在'));
    }
    final songs = direct.songsOf(widget.sourceKey, query: _query);
    final count = direct.countOf(widget.sourceKey);

    // 行级视图数据（R-1）：签名涵盖影响行内容的版本号，命中即复用整表。
    final wide = MediaQuery.sizeOf(context).width >= kSongTileWideInfoWidth;
    final rows = _rowCache.resolve(
      signature: (
        widget.sourceKey,
        _query,
        songs.length,
        direct.metaVersion,
        direct.favoriteVersion,
        direct.settingsVersion,
        direct.settings.songTitleFormat,
        wide,
      ),
      length: songs.length,
      build: (i) {
        final s = songs[i];
        final meta = direct.weight.metaOf(s);
        return SongRowView.of(
          song: s,
          titleFormat: direct.settings.songTitleFormat,
          favorite: meta.favorite,
          disliked: meta.frozen,
          wide: wide,
        );
      },
    );

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
            SelectionAction(
              icon: Icons.play_arrow,
              label: '播放选中',
              onPressed: _sel.isEmpty
                  ? null
                  : () => _playSelected(context, source, songs),
            ),
            SelectionAction(
              icon: Icons.playlist_add,
              label: '加入歌单',
              onPressed: _sel.isEmpty
                  ? null
                  : () => _addToPlaylistSelected(songs),
            ),
          ],
        ),
      // 扫描进度：枚举阶段为不确定进度条；探测阶段显示比例与数字。
      if (_scanning)
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
                onChanged: (v) => setState(() => _query = v),
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
            '已索引 $count 首 · ${source.name}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      ),
      const Divider(height: 16),
      if (direct.error != null)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(direct.error!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center),
        ),
      Expanded(
        child: songs.isEmpty
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
                        const Text(
                          '暂无索引曲目，点击"扫描"建立本地索引',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : RowList(
                    count: songs.length,
                    itemBuilder: (c, i) {
                      final s = songs[i];
                      return SongTile(
                        song: s,
                        source: source,
                        row: rows[i],
                        onPlay: () => _play(c, source, songs, i),
                        playing: player.isCurrent(s),
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
