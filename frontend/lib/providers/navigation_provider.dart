import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 全局导航状态：驱动顶栏下层导航 + 内容区切换，与布局模块解耦。
class NavigationProvider extends ChangeNotifier {
  NavSection _section = NavSection.songs;
  String _search = '';
  SettingsItem? _settings;
  bool _playerView = false;

  NavSection get section => _section;
  String get search => _search;

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

  /// 是否为占位页（后端尚无数据接口的导航项）。
  bool get isPlaceholder =>
      _section == NavSection.playlists ||
      _section == NavSection.liked ||
      _section == NavSection.sources ||
      _section == NavSection.artists;
}
