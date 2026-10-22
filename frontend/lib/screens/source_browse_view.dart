import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../data/sources/scan_worker.dart';
import '../models/song.dart';
import '../providers/direct_source_manager.dart';
import '../providers/library_provider.dart';
import '../providers/player_provider.dart';
import '../providers/navigation_provider.dart';
import '../utils/collection_sort.dart';
import '../utils/song_groups.dart';
import '../utils/source_folders.dart';
import '../widgets/add_to_playlist.dart';
import '../widgets/app_dialog_actions.dart';
import '../widgets/app_toast.dart';
import '../widgets/section_swipe.dart';
import '../widgets/selection_bar.dart';
import '../widgets/song_collection_view.dart';
import '../widgets/toolbar_icon_button.dart';

/// 源内浏览组件：在 AppContent 内容区原地渲染。
///
/// 分类方式（无 / 文件夹（逐级）/ 专辑）与喜欢/歌曲/歌单详情共用
/// [SongCollectionView]：
/// - 文件夹（逐级）：按 `sourceRef` 推导文件夹钻取（面包屑 + 文件夹行 +
///   本层歌曲；应用内新建的空文件夹也会显示）；
/// - 专辑：全源按专辑平铺分组；
/// - 无：全源平铺。
/// - 有搜索词时回落全源平铺搜索（标题/歌手/专辑）。
/// - 直连源：本地索引（扫描后）检索，提供「扫描」按钮建立/刷新本地索引。
class SourceBrowseView extends StatefulWidget {
  final String sourceKey;
  const SourceBrowseView({super.key, required this.sourceKey});

  @override
  State<SourceBrowseView> createState() => _SourceBrowseViewState();
}

class _SourceBrowseViewState extends State<SourceBrowseView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  /// 当前浏览目录（源内相对路径，`''` = 源根）：逐级模式导航状态。
  String _dir = '';
  bool _scanning = false;
  ScanProgress? _progress;
  StreamSubscription<ScanProgress>? _progressSub;

  /// 源歌曲查询缓存：仅源/搜索词/元数据版本/设置版本变化时重查。
  (String, String, int, int)? _songsKey;
  List<Song> _cachedSongs = const [];

  /// 排序缓存：歌曲列表身份 + 排序偏好 + 影响权重的版本号。
  List<Song>? _sortedBase;
  (CollectionSort, int, int, int)? _sortedKey;
  List<Song> _sortedSongs = const [];

  /// 源内相对路径（与 [_sortedSongs] 平行）缓存。
  List<Song>? _relsBase;
  String? _relsSourceKey;
  int? _relsSourceRev;
  List<String> _rels = const [];

  @override
  void didUpdateWidget(covariant SourceBrowseView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sourceKey != oldWidget.sourceKey) {
      _dir = '';
      _query = '';
      _searchCtrl.clear();
      _songsKey = null;
      _sortedBase = null;
      _relsBase = null;
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
      if (source != null && !_scanning) _scan();
    });
  }

  Future<void> _scan() async {
    final lib = context.read<LibraryProvider>();
    final manager = context.read<DirectSourceManager>();
    setState(() {
      _scanning = true;
      _progress = null;
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

  /// 上传/新建只在「文件夹（逐级）」模式下有明确目标目录。
  bool _requireFolderMode() {
    final mode = context.read<DirectSourceManager>().settings.groupSource;
    if (mode == SongGroupMode.folder) return true;
    AppToast.show('请先切换到「文件夹（逐级）」模式，再上传/新建', isError: true);
    return false;
  }

  /// 上传音频到当前文件夹：选文件 → 流式 PUT → 增量扫描刷新。
  Future<void> _upload(MusicSource source) async {
    if (!source.supportsWrite) {
      AppToast.show('该源不支持上传', isError: true);
      return;
    }
    if (!_requireFolderMode()) return;
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
      if (mounted) AppToast.show('上传完成：$name', isError: false);
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
    if (!_requireFolderMode()) return;
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
            Text('位置：$where', style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: '文件夹名')),
          ],
        ),
        actions: appDialogActions(
          c,
          confirmLabel: '确定',
          onCancel: () => Navigator.of(c).pop(),
          onConfirm: () => Navigator.of(c).pop(controller.text.trim()),
        ),
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      // 新建成功后 manager 会记录该空文件夹并 notify，逐级视图立刻显示。
      await context.read<DirectSourceManager>().createFolder(
            widget.sourceKey,
            name,
            parentRef: _dir,
          );
      if (mounted) AppToast.show('已创建文件夹：$name', isError: false);
    } catch (e) {
      AppToast.error(e, '创建失败');
    }
  }

  void _up() => setState(() => _dir = parentDirOf(_dir));

  void _go(String path) => setState(() => _dir = normalizeDir(path));

  /// 播放该源全部歌曲（文件夹视图下保留老平铺行为的入口）。
  Future<void> _playAll(
      BuildContext c, MusicSource source, List<Song> allSongs) async {
    if (allSongs.isEmpty) return;
    await _play(c, source, allSongs, 0);
  }

  void _addToPlaylistSelected(List<Song> songs, VoidCallback clear) {
    if (songs.isEmpty) return;
    clear();
    showAddToPlaylistSheetForSongs(context, songs);
  }

  @override
  void dispose() {
    _progressSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _play(
      BuildContext c, MusicSource source, List<Song> songs, int i) async {
    if (songs.isEmpty) return;
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

  /// 查当前源歌曲（搜索词非空时走全源检索），按版本缓存。
  List<Song> _songsOf(DirectSourceManager direct, String query) {
    final key = (
      widget.sourceKey,
      query,
      direct.metaVersion,
      direct.settingsVersion,
    );
    if (_songsKey == key) return _cachedSongs;
    _songsKey = key;
    _cachedSongs =
        direct.songsOf(widget.sourceKey, query: query.isEmpty ? null : query);
    return _cachedSongs;
  }

  /// 按播放源页的排列偏好排序（默认排序保持索引原序）。
  List<Song> _sorted(DirectSourceManager direct, List<Song> songs) {
    final pref = direct.settings.sortSourceSongs;
    final key = (
      pref,
      direct.metaVersion,
      direct.favoriteVersion,
      direct.settingsVersion,
    );
    if (identical(_sortedBase, songs) && _sortedKey == key) {
      return _sortedSongs;
    }
    final keys = direct.weight
        .sortKeysOf(songs, factors: pref.isWeight, playSecs: pref.isPlayStat);
    _sortedBase = songs;
    _sortedKey = key;
    _sortedSongs = sortSongs(songs, pref,
        factorOf: keys.factorOf, playSecOf: keys.playSecOf);
    return _sortedSongs;
  }

  /// 源内相对路径（WebDAV/SMB 需先剥 base 前缀），与歌曲列表平行。
  List<String> _relsOf(
      DirectSourceManager direct, List<Song> songs, MusicSource source) {
    if (identical(_relsBase, songs) &&
        _relsSourceKey == source.key &&
        _relsSourceRev == direct.sourcesRevision) {
      return _rels;
    }
    _relsBase = songs;
    _relsSourceKey = source.key;
    _relsSourceRev = direct.sourcesRevision;
    final strip = stripPrefixForSource(source);
    _rels = [
      for (final s in songs) displayRelRef(s.sourceRef, stripPrefix: strip),
    ];
    return _rels;
  }

  @override
  Widget build(BuildContext context) {
    // 订阅收窄（T010）：源内浏览的目标 sourceKey 由 widget 参数承载（父级路由
    // 变更会重建本组件），build 内不读取任何 NavigationProvider 字段；仅方法
    // （exitSource）经 read 调用，故不订阅导航状态、区段变更零重建。
    final nav = context.read<NavigationProvider>();
    final direct = context.watch<DirectSourceManager>();
    final source = direct.sourceByKey(widget.sourceKey);
    if (source == null) {
      return const Center(child: Text('源不存在'));
    }
    final settings = direct.settings;
    final mode = settings.groupSource;
    final searching = _query.trim().isNotEmpty;
    final songs = _sorted(direct, _songsOf(direct, _query.trim()));
    final rels = _relsOf(direct, songs, source);
    final total = direct.countOf(widget.sourceKey);
    // 只有「文件夹（逐级）」模式（且非搜索）才是按目录浏览：专辑/无为全源
    // 视图，不显示目录标题/面包屑，返回键直接退出播放源。
    final inFolder =
        !searching && mode == SongGroupMode.folder && _dir.isNotEmpty;
    final titleText = inFolder ? baseNameOf(_dir) : source.name;

    return SectionSwipe(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 窄屏：上传/新建文件夹收进三点菜单，把宽度留给标题与
                // 「播放 / 扫描」两个主操作；宽屏直接平铺工具图标。
                final compact = constraints.maxWidth < 520;
                final playable = !searching && songs.isNotEmpty;
                // 源里还没有歌时，扫描才是这一页唯一的主操作。
                final scanPrimary = songs.isEmpty && !searching;
                final scanIcon = _scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 18);

                final scanButton = scanPrimary
                    ? FilledButton.icon(
                        onPressed: _scanning ? null : _scan,
                        icon: scanIcon,
                        label: const Text('扫描'),
                      )
                    : OutlinedButton.icon(
                        onPressed: _scanning ? null : _scan,
                        icon: scanIcon,
                        label: const Text('扫描'),
                      );

                final writeActions = !source.supportsWrite
                    ? const <Widget>[]
                    : compact
                        ? <Widget>[
                            ToolbarPopupMenuButton<String>(
                              tooltip: '更多操作',
                              icon: Icons.more_vert,
                              onSelected: (v) {
                                if (_scanning) return;
                                if (v == 'upload') {
                                  unawaited(_upload(source));
                                } else if (v == 'mkdir') {
                                  unawaited(_mkdir(source));
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'upload',
                                  child: Row(
                                    children: [
                                      Icon(Icons.upload_file_outlined),
                                      SizedBox(width: 12),
                                      Text('上传音频到当前文件夹'),
                                    ],
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'mkdir',
                                  child: Row(
                                    children: [
                                      Icon(Icons.create_new_folder_outlined),
                                      SizedBox(width: 12),
                                      Text('在当前文件夹新建'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ]
                        : <Widget>[
                            ToolbarIconButton(
                              icon: Icons.upload_file_outlined,
                              tooltip: '上传音频到当前文件夹',
                              onPressed:
                                  _scanning ? null : () => _upload(source),
                            ),
                            ToolbarIconButton(
                              icon: Icons.create_new_folder_outlined,
                              tooltip: '在当前文件夹新建',
                              onPressed:
                                  _scanning ? null : () => _mkdir(source),
                            ),
                          ];

                return Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: inFolder ? '返回上一级' : '返回播放源',
                      onPressed: inFolder ? _up : nav.exitSource,
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.folder_outlined,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        titleText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (playable) ...[
                      FilledButton.icon(
                        onPressed: () => _playAll(context, source, songs),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('播放'),
                      ),
                      const SizedBox(width: 8),
                    ],
                    scanButton,
                    const SizedBox(width: 4),
                    ...writeActions,
                    if (_scanning)
                      ToolbarIconButton(
                        icon: Icons.close,
                        tooltip: '取消扫描',
                        onPressed: _cancel,
                      ),
                  ],
                );
              },
            ),
          ),
          // 扫描进度：枚举阶段为不确定进度条；探测阶段显示比例与数字。
          if (_scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Column(
                children: [
                  LinearProgressIndicator(value: _progress?.value),
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
                    controller: _searchCtrl,
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
          if (inFolder)
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
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Text(source.name,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.primary)),
                      ),
                    ),
                    for (var i = 0; i < splitSourceRef(_dir).length; i++) ...[
                      Text(' / ', style: Theme.of(context).textTheme.bodySmall),
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
                                    color:
                                        Theme.of(context).colorScheme.primary),
                          ),
                        ),
                      ),
                    ],
                  ],
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
            child: SongCollectionView(
              songs: songs,
              searching: searching,
              collectionKey: 'source:${widget.sourceKey}',
              groupMode: mode,
              onGroupModeChanged: (v) =>
                  setState(() => settings.groupSource = v),
              sort: settings.sortSourceSongs,
              onSortChanged: (v) =>
                  setState(() => settings.sortSourceSongs = v),
              folderLabel: '文件夹（逐级）',
              folderNavigation: FolderNavigation.recursive,
              folderPaths: rels,
              extraFolders: settings.sourceCreatedFolders(widget.sourceKey),
              dir: _dir,
              onDirChanged: (d) => setState(() => _dir = normalizeDir(d)),
              sourceOf: (_) => source,
              emptyText: searching
                  ? '该源内没有匹配的歌曲'
                  : (mode == SongGroupMode.folder && _dir.isNotEmpty)
                      ? '该文件夹暂无歌曲'
                      : '暂无索引曲目，点击"扫描"建立本地索引',
              countLabel: (n, folders) {
                if (searching) return '搜索到 $n 首';
                if (mode == SongGroupMode.folder) {
                  if (_dir.isEmpty) return '已索引 $total 首 · ${source.name}';
                  return '本层 $n 首 · $folders 个文件夹 · 共 $total 首';
                }
                if (mode == SongGroupMode.album) {
                  return '共 $total 首 · $folders 个专辑';
                }
                return '已索引 $total 首 · ${source.name}';
              },
              onRefresh: _scan,
              onPlay: (list, i) => _play(context, source, list, i),
              onPlayGroup: (list) => _play(context, source, list, 0),
              selectionActions: (selected, clear) => [
                SelectionAction(
                  icon: Icons.play_arrow,
                  label: '播放选中',
                  onPressed: selected.isEmpty
                      ? null
                      : () {
                          clear();
                          _play(context, source, selected, 0);
                        },
                ),
                SelectionAction(
                  icon: Icons.playlist_add,
                  label: '加入歌单',
                  onPressed: selected.isEmpty
                      ? null
                      : () => _addToPlaylistSelected(selected, clear),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
