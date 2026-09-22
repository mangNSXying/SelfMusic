import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

// 导航状态：驱动首页（全屏播放页）与 AppShell 内容区切换。
class NavigationProvider extends ChangeNotifier {
  NavSection _section = NavSection.songs;
  String _search = '';
  SettingsItem? _settings;

  /// 播放页为首页（ui-playpage.html 理念）：启动即全屏展示播放页。
  bool _playerView = true;
  String? _browsingSourceKey;
  int? _browsingPlaylistId;

  /// 播放队列面板是否展开（宽屏右侧常驻 / 窄屏底部弹层标记）。
  bool _queueOpen = false;

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

  /// 层级返回（底 → 顶）：播放页 < 内容页（含源内/歌单详情） < 队列面板 < 设置页。
  ///
  /// 窄屏侧边抽屉 / 队列弹层是系统路由，返回键由框架先关闭，到不了这里。
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
    if (_browsingPlaylistId != null) {
      _browsingPlaylistId = null;
      notifyListeners();
      return true;
    }
    if (_browsingSourceKey != null) {
      _browsingSourceKey = null;
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
    _section = s;
    _settings = null;
    _playerView = false;
    _browsingSourceKey = null;
    _browsingPlaylistId = null;
    notifyListeners();
  }

  /// 进入播放源内部（文件夹式导航）。
  void enterSource(String key) {
    _slideOffset = const Offset(1, 0);
    _browsingSourceKey = key;
    notifyListeners();
  }

  /// 返回播放源列表（文件夹返回上一级）。
  void exitSource() {
    _slideOffset = const Offset(-1, 0);
    _browsingSourceKey = null;
    notifyListeners();
  }

  /// 当前正在浏览的歌单 id（歌单详情子视图）；null 表示位于歌单列表。
  int? get browsingPlaylistId => _browsingPlaylistId;

  /// 进入歌单详情（原地子视图）：整页从右侧滑入。
  void enterPlaylist(int id) {
    _slideOffset = const Offset(1, 0);
    _browsingPlaylistId = id;
    notifyListeners();
  }

  /// 返回歌单列表：旧页向左滑出。
  void exitPlaylist() {
    _slideOffset = const Offset(-1, 0);
    _browsingPlaylistId = null;
    notifyListeners();
  }

  void openSettings(SettingsItem item) {
    _slideOffset = const Offset(1, 0);
    _settings = item;
    _playerView = false;
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
  /// （手势跟手或 220ms 吸附），避免多处抢改进度。
  void openPlayer() {
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
