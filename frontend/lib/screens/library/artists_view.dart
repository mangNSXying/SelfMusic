import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../data/local/app_settings.dart';
import '../../layout/screen_metrics.dart';
import '../../models/artist.dart';
import '../../theme/app_theme.dart';
import '../../utils/collection_sort.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/count_header.dart';
import '../../widgets/list_detail_split.dart';
import '../../widgets/row_list.dart';
import '../../widgets/sort_menu_button.dart';
import '../../widgets/square_card.dart';
import '../../widgets/view_mode_toggle.dart';
import 'artist_entries.dart';
import 'shared.dart';
import '../content/detail_pages.dart';

/// 详情栈里的歌手身份键（歌手页左栏高亮口径）。
///
/// 优先栈顶（列表里刚换的选中项），栈顶是"歌手 → 专辑"的专辑层时回退找歌手层。
String? _activeArtistKey(List<ContentRoute> details) {
  if (details.isEmpty) return null;
  final top = details.last;
  if (top is ArtistDetailRoute) {
    return top.artist.identityKey ?? top.artist.name;
  }
  for (final route in details.reversed) {
    if (route is ArtistDetailRoute) {
      final artist = route.artist;
      return artist.identityKey ?? artist.name;
    }
  }
  return null;
}

class ArtistsView extends StatefulWidget {
  const ArtistsView();

  @override
  State<ArtistsView> createState() => _ArtistsViewState();
}

class _ArtistsViewState extends State<ArtistsView>
    with AutomaticKeepAliveClientMixin, ViewModeState {
  /// 滑动档横滑时保持存活（同专辑页）。
  @override
  bool get wantKeepAlive => true;

  @override
  ViewModeSlot get viewModeSlot => ViewModeSlot.artists;

  @override
  AppSettings Function() get appSettings =>
      () => context.read<DirectSourceManager>().settings;

  /// 排序/过滤结果缓存：键 = (歌手全集大小, 简繁词库版本, 搜索词, 排序偏好)，
  /// build 重跑不重排。
  List<Artist>? _lastBase;
  (int, int, String, CollectionSort)? _sortedKey;
  List<Artist> _sorted = const [];

  List<Artist> _filteredSorted(
      List<Artist> artists, String search, CollectionSort pref) {
    final key = (artists.length, zhVariantRevision, search, pref);
    if (_sortedKey == key && identical(artists, _lastBase)) return _sorted;
    _lastBase = artists;
    _sortedKey = key;
    return _sorted = sortByCollection(
        _filter(artists, search), pref, (a) => a.name,
        countOf: (a) => a.songCount);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.artists.isEmpty && !lib.loading) {
        lib.startup();
      }
    });
    // 身份解析完成后的刷新挂在 LibraryProvider（解析结果落库即重算，不重扫歌曲；
    // 不在歌手页时也能保持新鲜），这里不再重复监听。
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lib = context.watch<LibraryProvider>();
    final direct = context.watch<DirectSourceManager>();
    // 订阅收窄（T011）：歌手页只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);
    final artists =
        _filteredSorted(lib.artists, search, direct.settings.sortArtists);
    final card = isCard;
    // 大横屏 + 列表模式：左列表 / 右详情（歌手 → 专辑两层详情都进右栏）。
    // 按自身分组判定：离屏缓存期间重建时全局分组可能已是别的页。
    final split = splitDetailActive(context, section: NavSection.artists);
    final nav = context.read<NavigationProvider>();
    // 分栏时左栏高亮「当前歌手」（栈里含歌手层即高亮，嵌套专辑时也保持）。
    context
        .select<NavigationProvider, int>((n) => split ? n.contentRevision : -1);
    final activeArtistKey = split ? _activeArtistKey(nav.details) : null;

    final listPane = Column(
      children: [
        CountHeader(
          count: artists.length,
          unit: '位',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              viewModeToggle(),
              SortMenuButton(
                value: direct.settings.sortArtists,
                scope: SortScope.collections,
                onChanged: (v) =>
                    setState(() => direct.settings.sortArtists = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: artists.isEmpty
              ? EmptyHint(onRefresh: lib.loadArtists)
              : card
                  ? RefreshIndicator(
                      onRefresh: lib.loadArtists,
                      child: SquareCardGrid(
                        itemCount: artists.length,
                        itemBuilder: (c, i) => ArtistCard(artist: artists[i]),
                      ),
                    )
                  : RowList(
                      // 分栏↔整页切换会重建列表：靠 PageStorage 记住滚动位置。
                      key: const PageStorageKey<String>('artists-list'),
                      count: artists.length,
                      onRefresh: lib.loadArtists,
                      itemBuilder: (c, i) => ArtistListTile(
                        artist: artists[i],
                        active: activeArtistKey != null &&
                            (artists[i].identityKey ?? artists[i].name) ==
                                activeArtistKey,
                      ),
                    ),
        ),
      ],
    );

    final topRoute = split && nav.details.isNotEmpty ? nav.details.last : null;
    return Column(
      children: [
        if (lib.loading) const LinearProgressIndicator(minHeight: 2),
        if (lib.error != null)
          Padding(
              padding: const EdgeInsets.all(8),
              child:
                  Text(lib.error!, style: const TextStyle(color: Colors.red))),
        Expanded(
          child: ListDetailSplit(
            enabled: split,
            listWidth: ScreenMetrics.of(context).listPaneWidth,
            list: listPane,
            detail: DetailPane(
              detail: topRoute == null ? null : detailPageOf(context, topRoute),
              detailKey: topRoute,
              emptyIcon: Icons.person_outline,
              emptyText: '从左侧选择歌手查看作品',
              duration:
                  direct.settings.playerTransition == PlayerTransition.none
                      ? Duration.zero
                      : kDetailPaneMotion,
            ),
          ),
        ),
      ],
    );
  }

  List<Artist> _filter(List<Artist> artists, String q) {
    if (q.trim().isEmpty) return artists;
    final qq = zhSearchFold(q).trim().toLowerCase();
    if (qq.isEmpty) return artists;
    return artists
        .where((a) => zhSearchFold(a.name).toLowerCase().contains(qq))
        .toList();
  }
}
