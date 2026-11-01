import 'package:flutter/material.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import '../utils/perf_log.dart';
import '../utils/source_folders.dart';

/// 「歌曲信息」工具页的子页（内容栈 L2）。
enum LibraryInfoPage {
  overview('歌曲信息'),
  meta('元数据信息'),
  artists('歌手信息'),
  formats('格式分布'),
  play('播放数据');

  const LibraryInfoPage(this.label);
  final String label;
}

/// 内容栈里的同一族页面：不同族互斥，进新族会清掉旧族；
/// 全局层（设置 / 歌曲信息）返回 null，可以压在任何族之上。
enum ContentFamily { playlist, source, albumArtist }

/// 内容区路由（底 → 顶由 [NavigationProvider.contentRoutes] 持有）。
///
/// 设置、歌单详情、源内目录、专辑/歌手详情、歌曲信息全部走这一条栈：
/// 返回就是弹一层，不再按类型分支。
sealed class ContentRoute {
  const ContentRoute();

  /// 退出该层时是否清空搜索词（分栏 keepSearch 优先）。
  bool get clearsSearchOnPop => true;

  /// 同一时刻只保留同族层；null = 全局层。
  ContentFamily? get family => null;
}

class SettingsRoute extends ContentRoute {
  const SettingsRoute(this.item);

  final SettingsItem item;

  @override
  bool get clearsSearchOnPop => false;
}

class LibraryInfoRoute extends ContentRoute {
  const LibraryInfoRoute(this.page);

  final LibraryInfoPage page;

  @override
  bool get clearsSearchOnPop => false;
}

/// 关于软件（L2 工具页）：保留侧栏、占内容区。
class AboutRoute extends ContentRoute {
  const AboutRoute();

  @override
  bool get clearsSearchOnPop => false;
}

class PlaylistRoute extends ContentRoute {
  const PlaylistRoute(this.id);

  final int id;

  @override
  ContentFamily get family => ContentFamily.playlist;
}

class SourceBrowseRoute extends ContentRoute {
  const SourceBrowseRoute(this.sourceKey, this.dir);

  final String sourceKey;

  /// 源内相对路径；`''` = 源根。
  final String dir;

  @override
  ContentFamily get family => ContentFamily.source;
}

class AlbumDetailRoute extends ContentRoute {
  const AlbumDetailRoute(this.album, this.songs);

  final Album album;
  final List<Song> songs;

  @override
  ContentFamily get family => ContentFamily.albumArtist;
}

class ArtistDetailRoute extends ContentRoute {
  const ArtistDetailRoute(this.artist, this.songs);

  final Artist artist;
  final List<Song> songs;

  @override
  ContentFamily get family => ContentFamily.albumArtist;
}

/// 导航状态：驱动首页（全屏播放页）与 AppShell 内容区切换。
///
/// ── 层级模型 ─────────────────────────────────────────────────────────
/// L0 首页：播放页（根）；播放器横滑带里的歌单页/歌词页是首页子页。
/// L1 内容基座：六分组 SectionPager（常驻保活）。
/// L2 内容栈：设置 / 歌单详情 / 源内目录 / 专辑·歌手详情 / 歌曲信息。
/// L3 模态浮层：窄屏队列弹层（宽屏队列面板是常驻 chrome，不参与返回）。
/// L4 路由：对话框 / 菜单 / 设置子页 / 窄屏歌曲弹层（Navigator 先 pop）。
///
/// 返回：路由 → 窄屏浮层 → 内容栈 → 内容基座 → 首页子页 → 首页根。
/// 首页展开时返回只作用于首页本身（离场），不会弹掉下面看不见的内容栈。
///
/// ── 订阅契约（R-1 / T003）──────────────────────────────────────────────
/// 保留单一 [NavigationProvider]，全局 `notifyListeners()` 继续广播；消费方
/// **MUST** 只订阅其渲染所必需的最小字段（`context.select`）。内容区路由
/// 订阅 `(section, contentRevision)`，不要 watch 整个导航对象。
/// ───────────────────────────────────────────────────────────────────────
class NavigationProvider extends ChangeNotifier {
  NavSection _section = NavSection.songs;
  String _search = '';

  /// 播放页为首页（ui-playpage.html 理念）：启动即全屏展示播放页。
  bool _playerView = true;

  /// 首页当前横滑带页：0=歌单页 / 1=播放页 / 2=歌词页（横屏只有 0/1）。
  int _homeBand = 1;

  /// 返回键要求首页横滑带回播放页（PlayerScreen 监听并播放动画）。
  final ValueNotifier<int> homeBandRequests = ValueNotifier<int>(0);

  /// 内容栈（底 → 顶）：设置 / 歌单 / 源内目录 / 专辑·歌手 / 歌曲信息。
  final List<ContentRoute> _content = <ContentRoute>[];

  /// 内容栈版本号：任何进/出栈或同层替换时 +1，供内容区最小字段订阅。
  int _contentRevision = 0;

  /// 播放队列面板是否展开（宽屏右侧常驻 / 窄屏弹层镜像）。
  bool _queueOpen = false;

  bool _searchFocusPending = false;
  int _sidebarToggleTick = 0;

  /// 内容 PageView 的实时页码（double，拖拽中连续变化），顶栏高亮跟随。
  final ValueNotifier<double> pageOffset = ValueNotifier(3);

  /// 播放页悬浮层进度（0=完全展示，1=完全隐藏）。
  final ValueNotifier<double> playerProgress = ValueNotifier(0);

  static const int homePlayerBand = 1;

  void setPlayerProgress(double p) {
    playerProgress.value = p.clamp(0.0, 1.0);
  }

  NavSection get section => _section;
  String get search => _search;

  /// 内容栈快照（底 → 顶）。
  List<ContentRoute> get contentRoutes =>
      List<ContentRoute>.unmodifiable(_content);

  /// 内容栈版本号（订阅收窄用）。
  int get contentRevision => _contentRevision;

  /// 兼容旧调用：详情栈变化即内容栈变化。
  int get detailRevision => _contentRevision;

  ContentRoute? get contentTop => _content.isEmpty ? null : _content.last;

  T? _nearest<T extends ContentRoute>() {
    for (var i = _content.length - 1; i >= 0; i--) {
      final route = _content[i];
      if (route is T) return route;
    }
    return null;
  }

  /// 当前设置分区，null 表示设置页不在栈顶。
  SettingsItem? get settings {
    final top = contentTop;
    return top is SettingsRoute ? top.item : null;
  }

  /// 是否正在设置页（设置必须是栈顶，否则被工具页盖住）。
  bool get inSettings => settings != null;

  /// 当前歌曲信息子页，null 表示不在歌曲信息页（仅看栈顶）。
  LibraryInfoPage? get libraryInfoPage {
    final top = contentTop;
    return top is LibraryInfoRoute ? top.page : null;
  }

  /// 当前工具页标题（歌曲信息 / 关于软件）；null = 非工具页。
  ///
  /// 顶栏据此切换为「菜单 + 返回 + 标题」变体，不显示分组导航与搜索。
  String? get toolPageTitle {
    final top = contentTop;
    if (top is LibraryInfoRoute) return top.page.label;
    if (top is AboutRoute) return '关于软件';
    return null;
  }

  /// 当前正在浏览的源 key（取最近一层源内路由）。
  String? get browsingSourceKey => _nearest<SourceBrowseRoute>()?.sourceKey;

  /// 源内浏览的当前目录（`''` = 源根）。
  String get sourceDir => _nearest<SourceBrowseRoute>()?.dir ?? '';

  /// 当前歌单详情 id（取最近一层歌单路由）。
  int? get browsingPlaylistId => _nearest<PlaylistRoute>()?.id;

  /// 专辑/歌手详情层（内容栈里的子集；供分栏右栏/高亮使用）。
  List<ContentRoute> get details => [
        for (final route in _content)
          if (route is AlbumDetailRoute || route is ArtistDetailRoute) route,
      ];

  bool get playerView => _playerView;

  /// 首页横滑带当前页（0=歌单 / 1=播放 / 2=歌词）。
  int get homeBand => _homeBand;

  /// PlayerScreen 横滑翻页时上报；只影响返回判定，不广播重建。
  void reportHomeBand(int band) {
    final next = band.clamp(0, 2);
    if (next == _homeBand) return;
    _homeBand = next;
  }

  /// 播放队列面板是否展开。
  bool get queueOpen => _queueOpen;

  /// 顶栏搜索提示语（随当前区域变化）。
  String get searchHint {
    final top = contentTop;
    if (top is SettingsRoute || top is LibraryInfoRoute || top is AboutRoute) {
      return '搜索';
    }
    if (top is SourceBrowseRoute) return '搜索该源全部曲目';
    if (top is PlaylistRoute) return '搜索歌单内歌曲';
    return switch (_section) {
      NavSection.sources => '搜索播放源',
      NavSection.playlists => '搜索歌单 / 歌曲',
      NavSection.albums => '搜索专辑 / 艺术家',
      NavSection.artists => '搜索歌手',
      NavSection.songs || NavSection.liked => '搜索标题 / 艺术家',
    };
  }

  void _clearSearchForDetail() {
    _search = '';
  }

  void _notifyContent() {
    _contentRevision++;
    notifyListeners();
  }

  void openQueue() {
    _queueOpen = true;
    notifyListeners();
  }

  void closeQueue() {
    if (!_queueOpen) return;
    _queueOpen = false;
    notifyListeners();
  }

  void toggleQueue() {
    _queueOpen = !_queueOpen;
    notifyListeners();
  }

  bool get searchFocusPending => _searchFocusPending;

  void requestSearchFocus() {
    _searchFocusPending = true;
    notifyListeners();
  }

  bool consumeSearchFocusRequest() {
    if (!_searchFocusPending) return false;
    _searchFocusPending = false;
    return true;
  }

  int get sidebarToggleTick => _sidebarToggleTick;

  void requestSidebarToggle() {
    _sidebarToggleTick++;
    notifyListeners();
  }

  /// 统一返回：只作用于「当前呈现的表面」。
  ///
  /// - 首页展开：首页子页 → 播放页；播放页根 → false（调用方转后台/不动作）。
  /// - 内容区：内容栈弹一层；栈空 → 展开首页。
  /// - 窄屏队列浮层 / 路由由调用方在此之前处理（见 main.dart / app_shortcuts）。
  /// - [keepSearch]：分栏时搜索框是左栏过滤器，退右栏不清词。
  bool backToPrevious({bool keepSearch = false}) {
    if (_playerView) {
      if (_homeBand != homePlayerBand) {
        _homeBand = homePlayerBand;
        homeBandRequests.value++;
        notifyListeners();
        return true;
      }
      return false;
    }
    if (_content.isNotEmpty) {
      _popContent(keepSearch: keepSearch);
      return true;
    }
    _showHome();
    return true;
  }

  void _showHome() {
    _playerView = true;
    _homeBand = homePlayerBand;
    homeBandRequests.value++;
    notifyListeners();
  }

  void _popContent({bool keepSearch = false}) {
    final top = _content.last;
    // 搜索态下目录不可见：返回直接退出整个源内。
    if (top is SourceBrowseRoute && _search.trim().isNotEmpty) {
      _content.removeWhere((route) => route is SourceBrowseRoute);
      if (!keepSearch) _clearSearchForDetail();
      _notifyContent();
      return;
    }
    _content.removeLast();
    if (!keepSearch && top.clearsSearchOnPop) _clearSearchForDetail();
    _notifyContent();
  }

  /// 切换顶级分组：清空内容栈（含设置/工具页），保留分组间搜索词语义。
  void select(NavSection s) {
    final hadDetail = _content.any((route) =>
        route is! SettingsRoute &&
        route is! LibraryInfoRoute &&
        route is! AboutRoute);
    if (hadDetail) _clearSearchForDetail();
    final changed = _content.isNotEmpty || _section != s || _playerView;
    _content.clear();
    _section = s;
    _playerView = false;
    if (!changed) return;
    _notifyContent();
  }

  /// 进入播放源内部（文件夹式导航的源根）。
  void enterSource(String key, {bool keepSearch = false}) {
    _playerView = false;
    if (!keepSearch) _clearSearchForDetail();
    _content.removeWhere((route) =>
        route.family != null && route.family != ContentFamily.source);
    _content.removeWhere((route) => route is SourceBrowseRoute);
    _content.add(SourceBrowseRoute(key, ''));
    _notifyContent();
  }

  /// 返回播放源列表（退出整个源内，含所有目录层）。
  void exitSource({bool keepSearch = false}) {
    final had = _content.any((route) => route is SourceBrowseRoute);
    if (!had) return;
    _content.removeWhere((route) => route is SourceBrowseRoute);
    if (!keepSearch) _clearSearchForDetail();
    _notifyContent();
  }

  /// 更新源内当前目录：按路径前缀重建源内路由层（每层一条）。
  ///
  /// 共同前缀的路由对象保留（State/滚动位置不重建），退回/前进都走这里。
  void setSourceDir(String dir) {
    final current = _nearest<SourceBrowseRoute>();
    if (current == null) return;
    final next = normalizeDir(dir);
    if (next == current.dir) return;

    final existing = <SourceBrowseRoute>[
      for (final route in _content)
        if (route is SourceBrowseRoute && route.sourceKey == current.sourceKey)
          route,
    ];
    final dirs = <String>[''];
    var acc = '';
    for (final seg in next.split('/').where((s) => s.isNotEmpty)) {
      acc = acc.isEmpty ? seg : '$acc/$seg';
      dirs.add(acc);
    }
    var common = 0;
    while (common < existing.length &&
        common < dirs.length &&
        existing[common].dir == dirs[common]) {
      common++;
    }
    final insertAt = _content.indexWhere((route) => route is SourceBrowseRoute);
    _content.removeWhere((route) => route is SourceBrowseRoute);
    _content.insertAll(insertAt < 0 ? _content.length : insertAt, [
      for (var i = 0; i < common; i++) existing[i],
      for (var i = common; i < dirs.length; i++)
        SourceBrowseRoute(current.sourceKey, dirs[i]),
    ]);
    _notifyContent();
  }

  /// 进入歌单详情（整页子视图 / 分栏右栏）。
  void enterPlaylist(int id, {bool keepSearch = false}) {
    _playerView = false;
    if (!keepSearch) _clearSearchForDetail();
    _content.removeWhere((route) =>
        route.family != null && route.family != ContentFamily.playlist);
    _content.removeWhere((route) => route is PlaylistRoute);
    _content.add(PlaylistRoute(id));
    _notifyContent();
  }

  /// 返回歌单列表。
  void exitPlaylist({bool keepSearch = false}) {
    final had = _content.any((route) => route is PlaylistRoute);
    if (!had) return;
    _content.removeWhere((route) => route is PlaylistRoute);
    if (!keepSearch) _clearSearchForDetail();
    _notifyContent();
  }

  /// 宽屏/分栏进入专辑详情。
  ///
  /// [root] = true：从分组列表点选（分栏左栏）——清掉旧详情层再压入这一层。
  /// 详情内部的嵌套入口用 false，压在上一层之上。
  void enterAlbum(Album album, List<Song> songs,
      {bool keepSearch = false, bool root = false}) {
    _playerView = false;
    _content.removeWhere((route) =>
        route.family != null && route.family != ContentFamily.albumArtist);
    if (root) {
      _content.removeWhere(
          (route) => route is AlbumDetailRoute || route is ArtistDetailRoute);
    }
    final top = contentTop;
    if (!root &&
        top is AlbumDetailRoute &&
        top.album.groupKey == album.groupKey) {
      return;
    }
    if (!keepSearch) _clearSearchForDetail();
    _content.add(AlbumDetailRoute(album, songs));
    _notifyContent();
  }

  /// 宽屏/分栏进入歌手详情。
  ///
  /// 已存在的同一歌手不再叠层：回退到那一层（成员链成环也不会无限堆栈）。
  void enterArtist(Artist artist, List<Song> songs,
      {bool keepSearch = false, bool root = false}) {
    _playerView = false;
    _content.removeWhere((route) =>
        route.family != null && route.family != ContentFamily.albumArtist);
    if (root) {
      _content.removeWhere(
          (route) => route is AlbumDetailRoute || route is ArtistDetailRoute);
    } else {
      final key = artist.identityKey ?? artist.name;
      var index = -1;
      for (var i = _content.length - 1; i >= 0; i--) {
        final route = _content[i];
        if (route is ArtistDetailRoute &&
            (route.artist.identityKey ?? route.artist.name) == key) {
          index = i;
          break;
        }
      }
      if (index >= 0) {
        if (index == _content.length - 1) return;
        if (!keepSearch) _clearSearchForDetail();
        _content.removeRange(index + 1, _content.length);
        _notifyContent();
        return;
      }
    }
    if (!keepSearch) _clearSearchForDetail();
    _content.add(ArtistDetailRoute(artist, songs));
    _notifyContent();
  }

  /// 列表视图切到卡片时关闭当前分栏详情（歌单/源内/专辑/歌手），保留全局层。
  void closeSplitDetail({bool keepSearch = true}) {
    final hasDetail = _content.any((route) => route.family != null);
    if (!hasDetail) return;
    _content.removeWhere((route) => route.family != null);
    if (!keepSearch) _clearSearchForDetail();
    _notifyContent();
  }

  /// 关闭栈顶的专辑/歌手详情（回到上一层详情/分组列表）。
  void exitDetail({bool keepSearch = false}) {
    final top = contentTop;
    if (top is! AlbumDetailRoute && top is! ArtistDetailRoute) return;
    _content.removeLast();
    if (!keepSearch) _clearSearchForDetail();
    _notifyContent();
  }

  /// 打开设置分区：同分区替换，其他情况压在内容栈顶。
  void openSettings(SettingsItem item) {
    _playerView = false;
    final top = contentTop;
    if (top is SettingsRoute) {
      if (top.item == item) return;
      _content[_content.length - 1] = SettingsRoute(item);
      _notifyContent();
      return;
    }
    _content.add(SettingsRoute(item));
    _notifyContent();
  }

  /// 关闭设置页（仅当设置是栈顶）。
  void closeSettings() {
    final top = contentTop;
    if (top is! SettingsRoute) return;
    _content.removeLast();
    _notifyContent();
  }

  /// 打开歌曲信息工具页（L2 内容栈，保留侧栏）。
  void openLibraryInfo(LibraryInfoPage page) {
    _playerView = false;
    final top = contentTop;
    if (top is LibraryInfoRoute) {
      if (top.page == page) return;
      if (page == LibraryInfoPage.overview) {
        // 从明细回总览：收掉整个歌曲信息子栈，避免总览叠总览。
        _content.removeWhere((route) => route is LibraryInfoRoute);
        _content.add(const LibraryInfoRoute(LibraryInfoPage.overview));
        _notifyContent();
        return;
      }
      _content.add(LibraryInfoRoute(page));
      _notifyContent();
      return;
    }
    _content.removeWhere((route) => route is LibraryInfoRoute);
    _content.add(LibraryInfoRoute(page));
    _notifyContent();
  }

  /// 打开关于软件（L2 工具页，保留侧栏）。
  void openAbout() {
    _playerView = false;
    final top = contentTop;
    if (top is AboutRoute) return;
    _content.removeWhere((route) => route is AboutRoute);
    _content.add(const AboutRoute());
    _notifyContent();
  }

  /// 打开展示播放页（上滑/点按进入：新页从底部升起）。
  ///
  /// 首页是根：打开首页不弹内容栈、不关设置；关掉首页后原内容原样还在。
  void openPlayer() {
    perfLog('player.open intent');
    _playerView = true;
    _homeBand = homePlayerBand;
    homeBandRequests.value++;
    notifyListeners();
  }

  /// 退出播放页回到内容区（下滑返回）。
  void closePlayer() {
    _playerView = false;
    notifyListeners();
  }

  void setSearch(String q) {
    if (q == _search) return;
    _search = q;
    notifyListeners();
  }

  void clearSearch() {
    _search = '';
    notifyListeners();
  }

  @override
  void dispose() {
    homeBandRequests.dispose();
    super.dispose();
  }
}
