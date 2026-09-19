import 'package:flutter/foundation.dart';
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
  bool backToPrevious() {
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

  void select(NavSection s) {
    _section = s;
    _settings = null;
    _playerView = false;
    _browsingSourceKey = null;
    _browsingPlaylistId = null;
    notifyListeners();
  }

  /// 进入播放源内部（文件夹式导航）。
  void enterSource(String key) {
    _browsingSourceKey = key;
    notifyListeners();
  }

  /// 返回播放源列表（文件夹返回上一级）。
  void exitSource() {
    _browsingSourceKey = null;
    notifyListeners();
  }

  /// 当前正在浏览的歌单 id（歌单详情子视图）；null 表示位于歌单列表。
  int? get browsingPlaylistId => _browsingPlaylistId;

  /// 进入歌单详情（原地子视图）。
  void enterPlaylist(int id) {
    _browsingPlaylistId = id;
    notifyListeners();
  }

  /// 返回歌单列表。
  void exitPlaylist() {
    _browsingPlaylistId = null;
    notifyListeners();
  }

  void openSettings(SettingsItem item) {
    _settings = item;
    _playerView = false;
    notifyListeners();
  }

  /// 返回上一级（设置页回到上一个导航 section）。
  void closeSettings() {
    _settings = null;
    notifyListeners();
  }

  /// 打开展示播放页。
  void openPlayer() {
    _playerView = true;
    _settings = null;
    notifyListeners();
  }

  /// 退出播放页回到上一导航分区。
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
}
