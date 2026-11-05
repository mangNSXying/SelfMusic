import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../providers/library_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/direct_source_manager.dart';
import '../../data/local/app_settings.dart';
import '../../layout/screen_metrics.dart';
import '../../models/album.dart';
import '../../theme/app_theme.dart';
import '../../utils/collection_sort.dart';
import '../../utils/zh_variant.dart';
import '../../widgets/count_header.dart';
import '../../widgets/list_detail_split.dart';
import '../../widgets/row_list.dart';
import '../../widgets/sort_menu_button.dart';
import '../../widgets/square_card.dart';
import '../../widgets/view_mode_toggle.dart';
import 'album_detail.dart';
import 'shared.dart';
import '../content/detail_pages.dart';

class AlbumsView extends StatefulWidget {
  const AlbumsView();

  @override
  State<AlbumsView> createState() => _AlbumsViewState();
}

class _AlbumsViewState extends State<AlbumsView>
    with AutomaticKeepAliveClientMixin, ViewModeState {
  /// 滑动档横滑时保持存活：离开可视区即销毁 State，重新进入会重跑全量专辑查询
  /// 与重排，KeepAlive 保留使来回滑动 0 查询。
  @override
  bool get wantKeepAlive => true;

  @override
  ViewModeSlot get viewModeSlot => ViewModeSlot.albums;

  @override
  AppSettings Function() get appSettings =>
      () => context.read<DirectSourceManager>().settings;

  /// 排序/过滤结果缓存：键 = (专辑全集大小, 简繁词库版本, 搜索词, 排序偏好)，
  /// build 重跑不重排。
  List<Album>? _lastBase;
  (int, int, String, CollectionSort)? _sortedKey;
  List<Album> _sorted = const [];

  List<Album> _filteredSorted(
      List<Album> albums, String search, CollectionSort pref) {
    final key = (albums.length, zhVariantRevision, search, pref);
    if (_sortedKey == key && identical(albums, _lastBase)) return _sorted;
    _lastBase = albums;
    _sortedKey = key;
    return _sorted = sortByCollection(
        _filter(albums, search), pref, (a) => a.album,
        countOf: (a) => a.trackCount);
  }

  @override
  void initState() {
    super.initState();
    // 首帧后再启动加载：startup 会同步 notifyListeners，build 期间触发会报断言。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final lib = context.read<LibraryProvider>();
      if (lib.albums.isEmpty && !lib.loading) {
        lib.startup();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lib = context.watch<LibraryProvider>();
    final direct = context.watch<DirectSourceManager>();
    // 订阅收窄（T011）：专辑页只关注全局搜索词；区段索引变更不重建、不重排。
    final search = context.select<NavigationProvider, String>((n) => n.search);
    final albums =
        _filteredSorted(lib.albums, search, direct.settings.sortAlbums);
    final card = isCard;
    // 大横屏 + 列表模式：左列表 / 右详情。判定走统一判屏口径。
    // 按自身分组判定：离屏缓存期间重建时全局分组可能已是别的页。
    final split = splitDetailActive(context, section: NavSection.albums);
    final nav = context.read<NavigationProvider>();
    // 分栏时左栏高亮「当前详情」：只订阅内容栈版本（卡片模式恒为 -1，不订阅）。
    context
        .select<NavigationProvider, int>((n) => split ? n.contentRevision : -1);
    final topRoute = split && nav.details.isNotEmpty ? nav.details.last : null;
    final activeKey =
        topRoute is AlbumDetailRoute ? topRoute.album.groupKey : null;

    final listPane = Column(
      children: [
        CountHeader(
          count: albums.length,
          unit: '张',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              viewModeToggle(),
              SortMenuButton(
                value: direct.settings.sortAlbums,
                scope: SortScope.collections,
                onChanged: (v) =>
                    setState(() => direct.settings.sortAlbums = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: albums.isEmpty
              ? EmptyHint(onRefresh: lib.loadAlbums)
              : card
                  ? RefreshIndicator(
                      onRefresh: lib.loadAlbums,
                      child: SquareCardGrid(
                        itemCount: albums.length,
                        itemBuilder: (c, i) => AlbumCard(album: albums[i]),
                      ),
                    )
                  : RowList(
                      // 分栏↔整页切换会重建列表：靠 PageStorage 记住滚动位置。
                      key: const PageStorageKey<String>('albums-list'),
                      count: albums.length,
                      onRefresh: lib.loadAlbums,
                      itemBuilder: (c, i) => AlbumListTile(
                        album: albums[i],
                        active: activeKey != null &&
                            albums[i].groupKey == activeKey,
                      ),
                    ),
        ),
      ],
    );

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
              detailKey: activeKey,
              emptyIcon: Icons.album_outlined,
              emptyText: '从左侧选择专辑查看曲目',
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

  List<Album> _filter(List<Album> albums, String q) {
    if (q.trim().isEmpty) return albums;
    final qq = zhSearchFold(q).trim().toLowerCase();
    if (qq.isEmpty) return albums;
    return albums
        .where((a) =>
            zhSearchFold(a.album).toLowerCase().contains(qq) ||
            a.artists.any((e) => zhSearchFold(e).toLowerCase().contains(qq)))
        .toList();
  }
}
