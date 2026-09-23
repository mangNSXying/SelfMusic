import '../models/song.dart';

/// 深层列表：每个歌单一条「仅可修改末尾值」的有界历史栈（隐藏列表）。
///
/// 语义（改进.txt 深层列表功能）：
/// - 歌单内播放：该歌推入末尾（末尾已是它则不动）；
/// - 超过容量（= 歌单当前歌曲总数）代表已播完一轮 → 清空后从当前曲重新开始；
/// - 外部点歌（歌单外/其他源）：替换末尾（不增长）；
/// - 上一首：弹出末尾（当前曲），末尾重新指向前一首并从头播放；
/// - 不影响「下一首」语义（未来播放顺序仍由队列/加权决定）。
class DeepListController {
  /// 容量上限（歌单当前歌曲总数；可由歌单删歌收缩）。
  int capacity;

  final List<Song> _entries;

  DeepListController({required this.capacity, List<Song> entries = const []})
      : _entries = List.of(entries);

  List<Song> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;
  Song? get tail => _entries.isEmpty ? null : _entries.last;

  /// 歌单内播放某歌：末尾已是该歌则不动；超容量清空重来；否则推入末尾。
  void pushPlayed(Song s, {required bool Function(Song a, Song b) same}) {
    if (capacity <= 0) return;
    final t = tail;
    if (t != null && same(t, s)) return;
    if (_entries.length >= capacity) _entries.clear();
    _entries.add(s);
  }

  /// 外部点歌：替换末尾；空列表时直接推入。
  void replaceTail(Song s, {required bool Function(Song a, Song b) same}) {
    final t = tail;
    if (t != null && same(t, s)) return;
    if (_entries.isEmpty) {
      _entries.add(s);
    } else {
      _entries[_entries.length - 1] = s;
    }
  }

  /// 上一首：弹出末尾（当前曲），返回被弹出的歌（空栈返回 null）。
  Song? popTail() => _entries.isEmpty ? null : _entries.removeLast();

  /// 移除某歌的全部引用（歌单删歌联动）。
  void removeRef(Song s, {required bool Function(Song a, Song b) same}) {
    _entries.removeWhere((e) => same(e, s));
  }

  void clear() => _entries.clear();

  List<Map<String, dynamic>> toJson() => [for (final s in _entries) s.toJson()];

  /// 解析持久化条目（容错：非列表/坏行跳过）。
  static List<Song> parseEntries(dynamic raw) {
    if (raw is! List) return const [];
    final out = <Song>[];
    for (final e in raw) {
      if (e is! Map) continue;
      try {
        out.add(Song.fromJson(Map<String, dynamic>.from(e)));
      } catch (_) {
        // 坏行跳过，不影响其余历史。
      }
    }
    return out;
  }
}
