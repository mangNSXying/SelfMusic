import 'package:flutter/material.dart';
import 'package:selfmusic/data/local/app_settings.dart';

/// 集合页「列表/卡片」展示形式的设置槽位：歌单/播放源/专辑/歌手各占一项。
enum ViewModeSlot { playlists, sources, albums, artists }

/// 槽位 ↔ [AppSettings] 属性的映射（此前散在四页的 `_modeOf`/`_setMode` 里）。
extension ViewModeSlotX on ViewModeSlot {
  CollectionViewMode read(AppSettings s) => switch (this) {
        ViewModeSlot.playlists => s.viewModePlaylists,
        ViewModeSlot.sources => s.viewModeSources,
        ViewModeSlot.albums => s.viewModeAlbums,
        ViewModeSlot.artists => s.viewModeArtists,
      };

  void write(AppSettings s, CollectionViewMode v) => switch (this) {
        ViewModeSlot.playlists => s.viewModePlaylists = v,
        ViewModeSlot.sources => s.viewModeSources = v,
        ViewModeSlot.albums => s.viewModeAlbums = v,
        ViewModeSlot.artists => s.viewModeArtists = v,
      };
}

/// 集合页展示形式（列表/卡片）的页面状态，四页共用。
///
/// 此前每页各写一份 `CollectionViewMode? _mode` + `_modeOf(c)` + `_setMode(c, m)`
/// 再各自拼 `ViewModeToggle`（12 行 ×4）。本 mixin 收口翻转逻辑与切换按钮，
/// 页面只需声明 [viewModeSlot]。
///
/// **为什么需要本地覆盖**：切换写的是 SQLite 设置，不触发 provider 通知，
/// 必须 setState 才会立刻换形态；下次进入页面再回落到设置值。
mixin ViewModeState<T extends StatefulWidget> on State<T> {
  /// 绑定到哪个设置项。
  ViewModeSlot get viewModeSlot;

  /// 取设置对象（`DirectSourceManager` 一般已在 build 里 watch 过）。
  AppSettings Function() get appSettings;

  /// 本地覆盖的展示形式；null 表示以设置为准。
  CollectionViewMode? _viewMode;

  bool get isCard => viewModeOf() == CollectionViewMode.card;

  CollectionViewMode viewModeOf() =>
      _viewMode ?? viewModeSlot.read(appSettings());

  /// 切换展示形式：写设置 + 立即重建。
  void setViewMode(CollectionViewMode mode) {
    viewModeSlot.write(appSettings(), mode);
    setState(() => _viewMode = mode);
  }

  /// 头栏右侧的列表/卡片切换按钮（四页同一形态）。
  Widget viewModeToggle() => ViewModeToggle(
        card: isCard,
        onChanged: (card) => setViewMode(
            card ? CollectionViewMode.card : CollectionViewMode.list),
      );
}

class ViewModeToggle extends StatelessWidget {
  /// 当前是否卡片形态。
  final bool card;
  final ValueChanged<bool> onChanged;

  const ViewModeToggle({
    super.key,
    required this.card,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: card ? '切换为列表' : '切换为卡片',
      iconSize: 20,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(card ? Icons.view_list : Icons.grid_view),
      onPressed: () => onChanged(!card),
    );
  }
}
