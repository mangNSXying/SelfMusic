import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/player_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../models/song.dart';
import '../../theme/app_theme.dart';
import '../../utils/collection_sort.dart';
import '../../utils/song_search.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/corner_add_button.dart';
import '../../widgets/song_collection_view.dart';
import '../../widgets/song_selection_actions.dart';
import 'shared.dart';

/// 喜欢（收藏）列表：统一来自 play_meta.is_favorite（直连 + 服务器）。
class LikedView extends StatefulWidget {
  const LikedView();

  @override
  State<LikedView> createState() => _LikedViewState();
}

class _LikedViewState extends State<LikedView>
    with AutomaticKeepAliveClientMixin {
  /// 滑动档横滑时保持存活：PageView 离开可视区即销毁 State，重新进入会重跑
  /// 全量收藏查询 + 重排（千首 × 多表查询全压在动画帧），KeepAlive 保留之。
  @override
  bool get wantKeepAlive => true;

  /// 收藏列表缓存：仅在（收藏版本, 设置版本, 元数据版本）变化时查库
  /// （滑动/重绘不重复全量查询）。设置版本同步忽略排除规则的生效：
  /// 忽略音频改动后喜欢页即时过滤（改进.txt 功能6）；元数据版本让编辑
  /// 专辑/歌手后分组即时生效。
  int _favVersion = -1;
  int _favSettingsVer = -1;
  int _favMetaVer = -1;
  List<Song> _favAll = const [];

  /// 排序/过滤结果按 (收藏版本, 设置版本, 元数据版本, 简繁词库版本, 搜索词,
  /// 排序偏好) 缓存：
  /// build 因 AnyChange 重跑时不重排（权重排序每首一次 SQL）。
  (int, int, int, int, String, CollectionSort)? _sortedKey;
  SortedResult _sorted = const SortedResult([], []);

  List<Song> _favoritesOf(DirectSourceManager direct) {
    if (direct.favoriteVersion != _favVersion ||
        direct.settingsVersion != _favSettingsVer ||
        direct.metaVersion != _favMetaVer) {
      _favVersion = direct.favoriteVersion;
      _favSettingsVer = direct.settingsVersion;
      _favMetaVer = direct.metaVersion;
      _favAll = direct.favoriteSongs();
    }
    return _favAll;
  }

  /// 过滤 + 排序，命中缓存直接复用（喜欢页数据不变时 build 重跑 0 次排序/查询）。
  SortedResult _sortSongs(DirectSourceManager direct, String search) {
    final pref = direct.settings.sortFavorites;
    // 先按版本刷新收藏全集，再用刷新后的版本号做缓存键（避免首帧多排一次）。
    final all = _favoritesOf(direct);
    final key = (
      _favVersion,
      _favSettingsVer,
      _favMetaVer,
      zhVariantRevision,
      search,
      pref
    );
    if (_sortedKey == key) return _sorted;
    final filtered = filterSongs(all, search);
    // 权重/播放统计排序批量预取（一次分片查询），不再逐首同步查库。
    final keys = direct.weight.sortKeysOf(filtered,
        factors: pref.isWeight, playSecs: pref.isPlayStat);
    final songs = sortSongs(filtered, pref,
        factorOf: keys.factorOf, playSecOf: keys.playSecOf);
    _sortedKey = key;
    _sorted = SortedResult(_favAll, songs);
    return _sorted;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final direct = context.watch<DirectSourceManager>();
    // 订阅收窄（T011）：喜欢页只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);
    final lib = context.read<LibraryProvider>();
    final res = _sortSongs(direct, search);
    final songs = res.songs;

    return CornerFabLayer(
      content: SongCollectionView(
        songs: songs,
        searching: search.trim().isNotEmpty,
        collectionKey: 'favorites',
        groupMode: direct.settings.groupFavorites,
        onGroupModeChanged: (v) =>
            setState(() => direct.settings.groupFavorites = v),
        sort: direct.settings.sortFavorites,
        onSortChanged: (v) => setState(() => direct.settings.sortFavorites = v),
        sourceOf: (s) => lib.sourceFor(s.sourceKey),
        emptyText: res.raw.isEmpty ? '暂无喜欢的歌曲，去歌曲页点 ♡ 收藏' : '无匹配歌曲',
        countLabel: (n, _) => '共 $n 首歌曲',
        onPlay: (list, i) {
          context.read<PlayerProvider>().playQueue(list,
              index: i, contextKey: PlayerProvider.anchorForLiked());
          context.read<NavigationProvider>().openPlayer();
        },
        onPlayGroup: (list) => context
            .read<PlayerProvider>()
            .playQueue(list, contextKey: PlayerProvider.anchorForLiked()),
        selectionActions: (selected, clear) => [
          ...collectionPlayAddActions(
            context,
            selected,
            clear,
            play: () async {
              context.read<PlayerProvider>().playQueue(selected,
                  contextKey: PlayerProvider.anchorForLiked());
              context.read<NavigationProvider>().openPlayer();
            },
          ),
          ...songSelectionActions(
            context,
            selected,
            clear,
            favorite: FavoriteAction.unlike,
          ),
        ],
      ),
      fab: CornerAddButton(
        tooltip: '去歌曲页收藏',
        onPressed: () =>
            context.read<NavigationProvider>().select(NavSection.songs),
      ),
    );
  }
}
