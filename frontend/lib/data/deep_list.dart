import 'dart:convert';

import '../models/song.dart';

/// 深层列表：当前锚定列表一条「仅可修改末尾值」的有界历史栈（隐藏列表）。
///
/// 语义（改进.txt 深层列表功能）：
/// - 锚定列表内播放：该歌推入末尾（末尾已是它则不动）；
/// - 超过容量（= 锚定列表当前歌曲总数）代表已播完一轮 → 清空后从当前曲重新开始；
/// - 外部点歌（其它列表点击歌曲）：替换末尾（不增长），不切换锚定；
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

  /// 容错统计条目数（不解析 Song）：接受 JSON 字符串/已解码 List/`{}` 等。
  /// 断点同步「同歌单取最长」比较用——镜像 `deepListJson`（身份数组）与本机
  /// `entries_json`（Song 数组）同口径计数，坏数据计 0。
  static int countEntries(dynamic raw) {
    if (raw == null) return 0;
    if (raw is List) return raw.length;
    if (raw is String) {
      if (raw.isEmpty) return 0;
      try {
        final d = jsonDecode(raw);
        return d is List ? d.length : 0;
      } catch (_) {
        return 0;
      }
    }
    return 0;
  }

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
