import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 全局导航状态：驱动顶栏下层导航 + 内容区切换，与布局模块解耦。
class NavigationProvider extends ChangeNotifier {
  NavSection _section = NavSection.songs;
  String _search = '';
  SettingsItem? _settings;
  bool _playerView = false;
  String? _browsingSourceKey;
  int? _browsingPlaylistId;

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
