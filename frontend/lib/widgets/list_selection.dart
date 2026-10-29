import '../models/song.dart';

/// 歌曲稳定标识：源内唯一引用（跨源合并列表去重用）。
String songKey(Song s) => '${s.sourceKey}|${s.sourceRef}|${s.id}';

/// 通用多选状态：页面内的选择集合 + 是否处于「选择模式」。
///
/// 泛型 T 通常是 `String`（歌曲稳定键）或 `int`（歌单 id）。
class Selection<T> {
  final Set<T> _selected = {};
  bool active = false;

  bool contains(T item) => _selected.contains(item);

  bool get isEmpty => _selected.isEmpty;

  /// 当前已勾选的所有 key（供批量操作读取）。
  Set<T> get selected => Set.unmodifiable(_selected);

  /// 点击切换勾选（保持选择模式）。
  void toggle(T item) {
    if (!_selected.remove(item)) _selected.add(item);
  }

  /// 长按：进入选择模式并仅选中该项。
  void startWith(T item) {
    active = true;
    _selected
      ..clear()
      ..add(item);
  }

  /// 长按组头/文件夹：进入选择模式并选中整批（组内全部歌曲 / 文件夹子树）。
  void startWithAll(Iterable<T> items) {
    active = true;
    _selected
      ..clear()
      ..addAll(items);
  }

  /// 全选/取消全选（按当前列表整体切换）。
  void setAll(Iterable<T> allItems) {
    final list = allItems.toList();
    if (list.isNotEmpty && list.every(_selected.contains)) {
      for (final x in list) {
        _selected.remove(x);
      }
    } else {
      _selected.addAll(list);
    }
  }

  /// 全选：把给定条目全部加入选择集（保留其他已选条目）。
  void addAll(Iterable<T> items) => _selected.addAll(items);

  /// 全不选：清空选择集，仍停留在多选模式。
  void clearAll() => _selected.clear();

  int get count => _selected.length;

  List<T> of(Iterable<T> allItems) =>
      allItems.where(_selected.contains).toList(growable: false);

  void cancel() {
    active = false;
    _selected.clear();
  }
}

/// 从列表中取出生效选中的歌曲，带便捷版。
List<Song> selectedSongs(Selection<String> sel, Iterable<Song> songs) =>
    songs.where((s) => sel.contains(songKey(s))).toList(growable: false);
