import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../models/song.dart';
import '../../utils/collection_sort.dart';
import '../../utils/song_search.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/song_collection_view.dart';
import '../../widgets/song_selection_actions.dart';
import 'shared.dart';

class SongsView extends StatefulWidget {
  const SongsView();

  @override
  State<SongsView> createState() => _SongsViewState();
}

class _SongsViewState extends State<SongsView>
    with AutomaticKeepAliveClientMixin {
  /// 滑动档横滑时保持存活：离开可视区即销毁 State，重新进入会重跑全库查询
  /// （allSongs 全表扫描）与万吨排序，KeepAlive 保留使来回滑动 0 查询。
  @override
  bool get wantKeepAlive => true;

  /// 排序/过滤结果缓存（同喜欢页）：
  /// 键 = (歌曲全集身份, 简繁词库版本, 搜索词, 排序偏好)。build 重跑不重排不重查。
  List<Song>? _lastBase;
  (int, int, String, CollectionSort)? _sortedKey;
  SortedResult _sorted = const SortedResult([], []);

  SortedResult _sortSongs(
      LibraryProvider lib, DirectSourceManager direct, String search) {
    final base = lib.songs;
    final pref = direct.settings.sortSongs;
    final key = (base.length, zhVariantRevision, search, pref);
    if (_sortedKey == key && identical(base, _lastBase)) return _sorted;
    final filtered = filterSongs(base, search);
    // 权重/播放统计排序批量预取（一次分片查询），不再逐首同步查库。
    final keys = direct.weight.sortKeysOf(filtered,
        factors: pref.isWeight, playSecs: pref.isPlayStat);
    final songs = sortSongs(filtered, pref,
        factorOf: keys.factorOf, playSecOf: keys.playSecOf);
    _sortedKey = key;
    _lastBase = base;
    return _sorted = SortedResult(base, songs);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.songs.isEmpty && !lib.loading) {
        lib.startup();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lib = context.watch<LibraryProvider>();
    final direct = context.watch<DirectSourceManager>();

    // 订阅收窄（T011）：歌曲页只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);

    // 依据全局搜索词过滤（喜欢页共用同一匹配函数），再按本页排序偏好排序。
    final songs = _sortSongs(lib, direct, search).songs;

    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child:
                  Text(lib.error!, style: const TextStyle(color: Colors.red))),
        Expanded(
          child: SongCollectionView(
            songs: songs,
            searching: search.trim().isNotEmpty,
            collectionKey: 'songs',
            groupMode: direct.settings.groupSongs,
            onGroupModeChanged: (v) =>
                setState(() => direct.settings.groupSongs = v),
            sort: direct.settings.sortSongs,
            onSortChanged: (v) => setState(() => direct.settings.sortSongs = v),
            sourceOf: (s) => lib.sourceFor(s.sourceKey),
            emptyText: '暂无歌曲',
            emptyPlaceholder: EmptyHint(onRefresh: lib.loadSongs),
            countLabel: (n, _) => '共 $n 首歌曲',
            onRefresh: lib.loadSongs,
            onPlay: (list, i) {
              context.read<PlayerProvider>().playQueue(list,
                  index: i, contextKey: PlayerProvider.anchorForSongs());
              context.read<NavigationProvider>().openPlayer();
            },
            onPlayGroup: (list) => context
                .read<PlayerProvider>()
                .playQueue(list, contextKey: PlayerProvider.anchorForSongs()),
            selectionActions: (selected, clear) => [
              ...collectionPlayAddActions(
                context,
                selected,
                clear,
                play: () async {
                  context.read<PlayerProvider>().playQueue(selected,
                      contextKey: PlayerProvider.anchorForSongs());
                  context.read<NavigationProvider>().openPlayer();
                },
              ),
              ...songSelectionActions(context, selected, clear),
            ],
          ),
        ),
      ],
    );
  }
}
