import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../data/sources/scan_worker.dart';
import '../data/sources/smb_direct_source.dart';
import '../data/sources/webdav_direct_source.dart';
import '../data/sources/webdav_url.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';
import '../utils/source_folders.dart';
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
/// - 无搜索词时按 `sourceRef` 推导文件夹钻取（面包屑 + 文件夹行 + 本层歌曲，
///   空文件夹不显示）；点歌播放本层列表，「播全部」保留老平铺行为。
/// - 有搜索词时回落全源平铺搜索（标题/歌手/专辑）。
/// - 直连源：本地索引（扫描后）检索，提供「扫描」按钮建立/刷新本地索引。
class SourceBrowseView extends StatefulWidget {
  final String sourceKey;
  const SourceBrowseView({super.key, required this.sourceKey});

  @override
  State<SourceBrowseView> createState() => _SourceBrowseViewState();
}

class _SourceBrowseViewState extends State<SourceBrowseView> {
  String _query = '';

  /// 当前浏览目录（源内相对路径，`''` = 源根）：文件夹钻取导航状态。
  /// 仅从已索引歌曲的 `sourceRef` 推导，空文件夹不显示。
  String _dir = '';
  bool _scanning = false;
  ScanProgress? _progress;
  StreamSubscription<ScanProgress>? _progressSub;
  final Selection<String> _sel = Selection<String>();

  /// 行级视图数据缓存（R-1）。
  final SongRowCache _rowCache = SongRowCache();

  @override
  void didUpdateWidget(covariant SourceBrowseView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sourceKey != oldWidget.sourceKey) {
      _dir = '';
      _query = '';
      _sel.cancel();
    }
  }

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

  /// 上传音频到当前文件夹：选文件 → 流式 PUT → 增量扫描刷新。
  Future<void> _upload(MusicSource source) async {
    if (!source.supportsWrite) {
      AppToast.show('该源不支持上传', isError: true);
      return;
    }
    final manager = context.read<DirectSourceManager>();
    final lib = context.read<LibraryProvider>();
    try {
      final picked = await openFile();
      if (!mounted) return;
      if (picked == null) return;
      final name = picked.name;
      if (!RegExp(r'\.(mp3|flac|m4a|aac|ogg|wav|aif|aiff|aifc)$',
              caseSensitive: false)
          .hasMatch(name)) {
        if (mounted) AppToast.show('仅支持上传音频文件', isError: true);
        return;
      }
      final f = File(picked.path);
      final len = await f.length();
      if (len <= 0) {
        if (mounted) AppToast.show('文件为空，无法上传', isError: true);
        return;
      }
      if (mounted) AppToast.show('正在上传 $name…', isError: false);
      await manager.uploadAudio(widget.sourceKey, name, f.openRead(), len,
          parentRef: _dir);
      if (!mounted) return;
      await lib.loadSongs();
      if (mounted) {
        setState(() {});
        AppToast.show('上传完成：$name', isError: false);
      }
    } catch (e) {
      AppToast.error(e, '上传失败');
    }
  }

  /// 在当前文件夹下新建文件夹。
  Future<void> _mkdir(MusicSource source) async {
    if (!source.supportsWrite) {
      AppToast.show('该源不支持新建文件夹', isError: true);
      return;
    }
    final controller = TextEditingController();
    final where = _dir.isEmpty ? '源根目录' : '/$_dir';
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('新建文件夹'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('位置：$where',
                style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(controller: controller, autofocus: true,
                decoration: const InputDecoration(hintText: '文件夹名')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(c).pop(controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await context.read<DirectSourceManager>().createFolder(
          widget.sourceKey, name,
          parentRef: _dir);
      if (mounted) AppToast.show('已创建文件夹：$name', isError: false);
    } catch (e) {
      AppToast.error(e, '创建失败');
    }
  }

  void _enter(String path) => setState(() {
        _dir = normalizeDir(path);
        _sel.cancel();
      });

  void _up() => setState(() {
        _dir = parentDirOf(_dir);
        _sel.cancel();
      });

  void _go(String path) => setState(() {
        _dir = normalizeDir(path);
        _sel.cancel();
      });

  /// 该源的「源内相对路径」剥离前缀：WebDAV 以 base 路径为源根，
  /// SMB 以 `rootPath` 为源根（兼容含 root 前缀的 legacy 行），
  /// 本地/SFTP 本就是相对路径无需剥离。
  String _stripPrefix(MusicSource source) {
    final s = source;
    if (s is WebdavDirectSource) {
      return webdavPathOf(webdavNormalizeBase(s.baseUrl));
    }
    if (s is SmbDirectSource) return s.rootPath;
    return '';
  }

  /// 播放某文件夹下全部歌曲（递归含深层），与单曲点播同锚点，
  /// 深层列表/融合队列机制不变。
  Future<void> _playFolder(BuildContext c, MusicSource source,
      List<Song> allSongs, List<String> rels, String folderPath) async {
    final list = [
      for (var i = 0; i < allSongs.length; i++)
        if (normalizeDir(rels[i]).startsWith('${normalizeDir(folderPath)}/'))
          allSongs[i],
    ];
    if (list.isEmpty || !c.mounted) return;
    await _play(c, source, list, 0);
  }

  /// 播放该源全部歌曲（文件夹视图下保留老平铺行为的入口）。
  Future<void> _playAll(BuildContext c, MusicSource source,
      List<Song> allSongs) async {
    if (allSongs.isEmpty) return;
    await _play(c, source, allSongs, 0);
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
    final searching = _query.trim().isNotEmpty;
    // 文件夹视图用全量索引分组；搜索时沿用旧平铺检索。
    final List<Song> allSongs =
        searching ? const [] : direct.songsOf(widget.sourceKey);
    final List<Song> querySongs =
        searching ? direct.songsOf(widget.sourceKey, query: _query) : const [];
    final strip = _stripPrefix(source);
    final rels = [
      for (final s in allSongs) displayRelRef(s.sourceRef, stripPrefix: strip),
    ];
    final grouped =
        searching ? null : groupSourceSongs(rels, _dir);
    final folders = grouped?.folders ?? const <SourceFolder>[];
    final List<Song> displaySongs = searching
        ? querySongs
        : [for (final i in grouped!.songIndices) allSongs[i]];
    final count = direct.countOf(widget.sourceKey);

    // 行级视图数据（R-1）：签名涵盖影响行内容的版本号，命中即复用（懒求值）。
    final wide = MediaQuery.sizeOf(context).width >= kSongTileWideInfoWidth;
    _rowCache.begin(
      (
        widget.sourceKey,
        _dir,
        _query,
        displaySongs.length,
        direct.metaVersion,
        direct.favoriteVersion,
        direct.settingsVersion,
        direct.settings.songTitleFormat,
        wide,
      ),
      displaySongs.length,
      onWarm: () => direct.weight.warmMetaOf(displaySongs),
    );
    final titleText = !searching && _dir.isNotEmpty
        ? baseNameOf(_dir)
        : source.name;

    return SectionSwipe(
    child: Column(
      children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: _dir.isEmpty ? '返回播放源' : '返回上一级',
              onPressed: _dir.isEmpty ? nav.exitSource : _up,
            ),
            const SizedBox(width: 4),
            Icon(Icons.folder_outlined,
                size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                titleText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (source.supportsWrite)
                  IconButton(
                    icon: const Icon(Icons.upload_file_outlined),
                    tooltip: '上传音频到当前文件夹',
                    onPressed: _scanning ? null : () => _upload(source),
                  ),
                if (source.supportsWrite)
                  IconButton(
                    icon: const Icon(Icons.create_new_folder_outlined),
                    tooltip: '在当前文件夹新建',
                    onPressed: _scanning ? null : () => _mkdir(source),
                  ),
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
          total: displaySongs.length,
          selectedCount: _sel.of(displaySongs.map(songKey)).length,
          onToggleAll: () =>
              setState(() => _sel.setAll(displaySongs.map(songKey))),
          onCancel: () => setState(_sel.cancel),
          actions: [
            SelectionAction(
              icon: Icons.play_arrow,
              label: '播放选中',
              onPressed: _sel.isEmpty
                  ? null
                  : () => _playSelected(context, source, displaySongs),
            ),
            SelectionAction(
              icon: Icons.playlist_add,
              label: '加入歌单',
              onPressed: _sel.isEmpty
                  ? null
                  : () => _addToPlaylistSelected(displaySongs),
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
                  hintText: '搜索该源全部曲目（标题/歌手/专辑）',
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
      if (!searching && _dir.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                InkWell(
                  onTap: () => _go(''),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(source.name,
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.primary)),
                  ),
                ),
                for (var i = 0;
                    i < splitSourceRef(_dir).length;
                    i++) ...[
                  Text(' / ',
                      style: Theme.of(context).textTheme.bodySmall),
                  InkWell(
                    onTap: i == splitSourceRef(_dir).length - 1
                        ? null
                        : () => _go(splitSourceRef(_dir)
                            .sublist(0, i + 1)
                            .join('/')),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      child: Text(
                        splitSourceRef(_dir)[i],
                        style: i == splitSourceRef(_dir).length - 1
                            ? Theme.of(context).textTheme.bodyMedium
                            : TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                searching
                    ? '搜索到 ${displaySongs.length} 首'
                    : _dir.isEmpty
                        ? '已索引 $count 首 · ${source.name}'
                        : '本层 ${displaySongs.length} 首 · '
                            '${folders.length} 个文件夹 · 共 $count 首',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            if (!searching &&
                (folders.isNotEmpty || _dir.isNotEmpty))
              TextButton.icon(
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('播全部'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: allSongs.isEmpty
                    ? null
                    : () => _playAll(context, source, allSongs),
              ),
          ],
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
        child: (folders.isEmpty && displaySongs.isEmpty)
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
                          searching
                              ? '该源内没有匹配的歌曲'
                              : _dir.isEmpty
                                  ? '暂无索引曲目，点击"扫描"建立本地索引'
                                  : '该文件夹暂无歌曲',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : RowList(
                    count: folders.length + displaySongs.length,
                    itemBuilder: (c, i) {
                      if (i < folders.length) {
                        final f = folders[i];
                        final scheme = Theme.of(c).colorScheme;
                        return ListTile(
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: ShapeDecoration(
                              color: scheme.primary.withValues(alpha: 0.10),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                            ),
                            child: Icon(Icons.folder,
                                color: scheme.primary, size: 24),
                          ),
                          title: Text(
                            f.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text('${f.total} 首',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.play_arrow),
                                tooltip: '播放该文件夹',
                                onPressed: () => _playFolder(
                                    c, source, allSongs, rels, f.path),
                              ),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () => _enter(f.path),
                        );
                      }
                      final si = i - folders.length;
                      final s = displaySongs[si];
                      return SongTile(
                        song: s,
                        source: source,
                        row: _rowCache.rowAt(si, () {
                          final meta = direct.weight.metaOf(s);
                          return SongRowView.of(
                            song: s,
                            titleFormat: direct.settings.songTitleFormat,
                            favorite: meta.favorite,
                            disliked: meta.frozen,
                            wide: wide,
                          );
                        }),
                        onPlay: () => _play(c, source, displaySongs, si),
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
