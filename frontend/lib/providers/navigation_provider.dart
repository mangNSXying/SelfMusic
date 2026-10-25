import 'package:flutter/material.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import '../utils/perf_log.dart';

/// 内容区路由的「最小关注字段」稳定组合（订阅契约，R-4 / T003 / T008）。
///
/// 内容路由（[AppContent]）需要一次订阅多个相关字段才能决定渲染哪个区域。
/// 用 Dart record 承载：record 具备**结构相等**语义，`context.select` 以 `==`
/// 比较所选值——四个字段都不变时不会误触发重建，任一变化才重建。
///
/// 字段：
/// - `section`：六个顶级分组之一；
/// - `settings`：当前设置分区（null=非设置页）；
/// - `sourceKey`：源内浏览 key（null=位于播放源列表）；
/// - `playlistId`：歌单详情 id（null=位于歌单列表）。
typedef NavRouteKey = ({
  NavSection section,
  SettingsItem? settings,
  String? sourceKey,
  int? playlistId,
});

/// 宽屏内容区详情页的目标（专辑/歌手）。
///
/// 只在宽屏进入（窄屏仍走统一拖拽弹层）：内容区整页叠在分组列表之上，底层
/// 列表常驻保活。歌曲列表随目标一起快照，语义与窄屏弹层一致——打开期间后台
/// 解析/扫描不就地刷新，重新进入才取新数据。
sealed class DetailRoute {
  const DetailRoute();
}

class AlbumDetailRoute extends DetailRoute {
  const AlbumDetailRoute(this.album, this.songs);

  final Album album;
  final List<Song> songs;
}

class ArtistDetailRoute extends DetailRoute {
  const ArtistDetailRoute(this.artist, this.songs);

  final Artist artist;
  final List<Song> songs;
}

// 导航状态：驱动首页（全屏播放页）与 AppShell 内容区切换。
//
// ── 订阅契约（R-1 / T003）──────────────────────────────────────────────
// 保留单一 [NavigationProvider]，全局 `notifyListeners()` 继续广播；消费方
// **MUST** 只订阅其渲染所必需的最小字段：
//   `context.select<NavigationProvider, X>((n) => n.<field>)`（多字段用 record，
//   如 [NavRouteKey]，靠结构相等比较）。
// **MUST NOT** 以整对象 `context.watch<NavigationProvider>()` 订阅（除确需全部
// 字段外）——否则每一次导航通知（含区段切换）都会牵连无关控件同帧重建。
// 按值重建：区段变更（[section] 变化）时，[search] / [queueOpen] / [playerView]
// / [settings] / [browsingSourceKey] / [browsingPlaylistId] 不变，订阅这些字段
// 的组件不会重建。
// 跟手高亮：拖拽期逐帧高亮由 [pageOffset]（ValueNotifier）独立驱动。
// 公共方法与字段语义不变（R-6）。
// ───────────────────────────────────────────────────────────────────────
class NavigationProvider extends ChangeNotifier {
  NavSection _section = NavSection.songs;
  String _search = '';
  SettingsItem? _settings;

  /// 播放页为首页（ui-playpage.html 理念）：启动即全屏展示播放页。
  bool _playerView = true;
  String? _browsingSourceKey;
  int? _browsingPlaylistId;

  /// 宽屏详情栈（底 → 顶）：专辑/歌手整页叠在分组列表之上，最多两层。
  final List<DetailRoute> _details = <DetailRoute>[];

  /// 详情栈版本号：进/出栈或清空时 +1，供 [AppContent] 以最小字段订阅
  /// 「详情栈变化」（不 watch 整个导航对象，区段/搜索等通知不牵连重建）。
  int _detailRevision = 0;

  /// 播放队列面板是否展开（宽屏右侧常驻 / 窄屏统一拖拽式窗口的开合镜像，
  /// 窄屏由窗口收起时同步回关闭）。
  bool _queueOpen = false;

  bool _searchFocusPending = false;
  int _sidebarToggleTick = 0;

  /// 滑动过渡新页面的进入方向（(1,0) 右进 / (-1,0) 左进 / (0,±1) 竖向），
  /// 供全局切换器使用。
  Offset _slideOffset = const Offset(1, 0);
  Offset get slideOffset => _slideOffset;

  /// 内容 PageView 的实时页码（double，拖拽中连续变化）。
  ///
  /// 顶栏导航据此跟手同步高亮与条带滚动；用 ValueNotifier 隔离重建，
  /// 避免拖拽中整树 notify 掉帧。
  final ValueNotifier<double> pageOffset = ValueNotifier(3);

  /// 播放页悬浮层进度（0=完全展示，1=完全隐藏），播放页下拉/迷你栏上滑跟手共用。
  ///
  /// 用 ValueNotifier 逐帧驱动位移，只重建悬浮层；定稿态由 [playerView] 持有。
  final ValueNotifier<double> playerProgress = ValueNotifier(0);

  void setPlayerProgress(double p) {
    playerProgress.value = p.clamp(0.0, 1.0);
  }

  /// 当前区域 key（播放页悬浮层不计入区域）。
  String get areaKey {
    if (_settings != null) return 'settings:${_settings!.name}';
    if (_browsingSourceKey != null) return 'src:$_browsingSourceKey';
    if (_browsingPlaylistId != null) return 'pl:$_browsingPlaylistId';
    return 'sections';
  }

  /// 区域层级：分组区 1 < 源内/歌单详情 2 < 设置 3（播放页为悬浮层，不参与）。
  int get areaLevel {
    if (_settings != null) return 3;
    if (_browsingSourceKey != null || _browsingPlaylistId != null) return 2;
    return 1;
  }

  NavSection get section => _section;
  String get search => _search;

  /// 顶栏搜索提示语（随当前区域变化；搜索词本身仍是同一个 [search]）。
  ///
  /// 各区域对同一搜索词的解释不同（源名/源内歌曲/歌单歌曲/歌曲元数据），
  /// 提示语让用户明确“这次搜索会作用在什么上”。
  String get searchHint {
    if (_settings != null) return '搜索';
    if (_browsingSourceKey != null) return '搜索该源全部曲目';
    if (_browsingPlaylistId != null) return '搜索歌单内歌曲';
    return switch (_section) {
      NavSection.sources => '搜索播放源',
      NavSection.playlists => '搜索歌单 / 歌曲',
      NavSection.albums => '搜索专辑 / 艺术家',
      NavSection.artists => '搜索歌手',
      NavSection.songs || NavSection.liked => '搜索标题 / 艺术家',
    };
  }

  /// 进出详情页时清空搜索词（不额外通知，由调用方统一 notifyListeners）。
  void _clearSearchForDetail() {
    _search = '';
  }

  /// 当前正在浏览的源 key（文件夹式导航）；null 表示位于播放源列表。
  String? get browsingSourceKey => _browsingSourceKey;

  /// 当前打开的设置分区，null 表示非设置页。
  SettingsItem? get settings => _settings;

  /// 是否正在设置页。
  bool get inSettings => _settings != null;

  /// 是否展示播放页。
  bool get playerView => _playerView;

  /// 播放队列面板是否展开。
  bool get queueOpen => _queueOpen;

  /// 宽屏详情栈快照（底 → 顶；最多两层；空=位于分组列表）。
  ///
  /// 返回不可变**快照**而非活动视图：叠层组件要靠新旧两份列表的差异判定
  /// 进出动画（活动视图会让"旧"列表跟着变化，永远看不出差异）。
  List<DetailRoute> get details => List<DetailRoute>.unmodifiable(_details);

  /// 详情栈版本号（订阅收窄用，见 [AppContent]）。
  int get detailRevision => _detailRevision;

  /// 内容区路由的最小关注字段稳定组合（订阅契约读取入口，R-4 / T003 / T008）。
  ///
  /// 供内容路由单次 `context.select` 订阅 [section] + 设置分区 + 源内 key +
  /// 歌单详情 id；不读整对象，避免区段/搜索等无关通知牵连重建。
  NavRouteKey get routeKey => (
        section: _section,
        settings: _settings,
        sourceKey: _browsingSourceKey,
        playlistId: _browsingPlaylistId,
      );

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

  /// 层级返回（底 → 顶）：播放页 < 内容页（含源内/歌单/详情页） < 队列面板 < 设置页。
  ///
  /// 窄屏侧边抽屉是系统路由，返回键由框架先关闭，到不了这里；窄屏队列窗口
  /// 是根悬浮层（非路由），返回键经此逐级回退关闭。
  /// 返回 true 表示已消费（停留在上一级），false 表示已在最底层（调用方可退出）。
  /// 回退统一从左侧滑入（抽屉关闭感）。
  bool backToPrevious() {
    _slideOffset = const Offset(-1, 0);
    if (_settings != null) {
      _settings = null;
      notifyListeners();
      return true;
    }
    if (_queueOpen) {
      _queueOpen = false;
      notifyListeners();
      return true;
    }
    if (_details.isNotEmpty) {
      exitDetail();
      return true;
    }
    if (_browsingPlaylistId != null) {
      _browsingPlaylistId = null;
      _clearSearchForDetail();
      notifyListeners();
      return true;
    }
    if (_browsingSourceKey != null) {
      _browsingSourceKey = null;
      _clearSearchForDetail();
      notifyListeners();
      return true;
    }
    if (!_playerView) {
      _playerView = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  void select(NavSection s, {Offset slideOffset = const Offset(1, 0)}) {
    _slideOffset = slideOffset;
    // 离开源内/歌单详情/宽屏详情页时清空搜索：这些页面的搜索对象与顶级
    // 分区不同，继续带着旧词会让新页面看起来“莫名其妙被过滤”。六个顶级
    // 分区之间切换则保留搜索词（全局筛选语义）。
    if (_browsingSourceKey != null ||
        _browsingPlaylistId != null ||
        _details.isNotEmpty) {
      _clearSearchForDetail();
    }
    _section = s;
    _settings = null;
    _playerView = false;
    _browsingSourceKey = null;
    _browsingPlaylistId = null;
    _clearDetails();
    notifyListeners();
  }

  /// 进入播放源内部（文件夹式导航）。
  void enterSource(String key) {
    _slideOffset = const Offset(1, 0);
    _clearSearchForDetail();
    _browsingSourceKey = key;
    _clearDetails();
    notifyListeners();
  }

  /// 返回播放源列表（文件夹返回上一级）。
  void exitSource() {
    _slideOffset = const Offset(-1, 0);
    _browsingSourceKey = null;
    _clearSearchForDetail();
    notifyListeners();
  }

  /// 当前正在浏览的歌单 id（歌单详情子视图）；null 表示位于歌单列表。
  int? get browsingPlaylistId => _browsingPlaylistId;

  /// 进入歌单详情（原地子视图）：整页从右侧滑入。
  void enterPlaylist(int id) {
    _slideOffset = const Offset(1, 0);
    _clearSearchForDetail();
    _browsingPlaylistId = id;
    _clearDetails();
    notifyListeners();
  }

  /// 返回歌单列表：旧页向左滑出。
  void exitPlaylist() {
    _slideOffset = const Offset(-1, 0);
    _browsingPlaylistId = null;
    _clearSearchForDetail();
    notifyListeners();
  }

  /// 宽屏进入专辑详情页（内容区整页叠层，底层列表保活）。
  void enterAlbum(Album album, List<Song> songs) {
    _slideOffset = const Offset(1, 0);
    _clearSearchForDetail();
    _pushDetail(AlbumDetailRoute(album, songs));
  }

  /// 宽屏进入歌手详情页（内容区整页叠层，底层列表保活）。
  void enterArtist(Artist artist, List<Song> songs) {
    _slideOffset = const Offset(1, 0);
    _clearSearchForDetail();
    _pushDetail(ArtistDetailRoute(artist, songs));
  }

  /// 关闭栈顶详情页（回到上一层详情/分组列表）。
  void exitDetail() {
    if (_details.isEmpty) return;
    _slideOffset = const Offset(-1, 0);
    _details.removeLast();
    _detailRevision++;
    _clearSearchForDetail();
    notifyListeners();
  }

  void _pushDetail(DetailRoute route) {
    // 只保留最近两层：主流程是「歌手 → 专辑」，成员身份链不无限堆叠。
    if (_details.length >= 2) _details.removeAt(0);
    _details.add(route);
    _detailRevision++;
    notifyListeners();
  }

  /// 离开分组区时清空详情栈（详情层只属于分组区）。
  void _clearDetails() {
    if (_details.isEmpty) return;
    _details.clear();
    _detailRevision++;
  }

  void openSettings(SettingsItem item) {
    _slideOffset = const Offset(1, 0);
    _settings = item;
    _playerView = false;
    _clearDetails();
    notifyListeners();
  }

  /// 返回上一级（设置页回到上一个导航 section）。
  void closeSettings() {
    _slideOffset = const Offset(-1, 0);
    _settings = null;
    notifyListeners();
  }

  /// 打开展示播放页（上滑/点按进入：新页从底部升起）。
  ///
  /// 只置意图位；进度动画由 Root 的 [PlayerSheetAnimator] 统一驱动
  /// （手势跟手或 300ms 吸附），避免多处抢改进度。
  void openPlayer() {
    // 临时埋点（播放页打开卡顿定位）：用户意图时刻（点按/上滑松手/选歌播放均走这里）。
    perfLog('player.open intent');
    _slideOffset = const Offset(0, 1);
    _playerView = true;
    _settings = null;
    notifyListeners();
  }

  /// 退出播放页回到上一导航分区（下滑返回：新页从顶部降下）。
  void closePlayer() {
    _slideOffset = const Offset(0, -1);
    _playerView = false;
    notifyListeners();
  }

  /// 更新全局搜索词（各区域按 [searchHint] 的语义解释；进出详情页时自动清空）。
  void setSearch(String q) {
    if (q == _search) return;
    _search = q;
    notifyListeners();
  }

  void clearSearch() {
    _search = '';
    notifyListeners();
  }
}
