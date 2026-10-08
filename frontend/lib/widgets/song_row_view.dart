import '../data/local/app_settings.dart';
import '../models/song.dart';
import '../utils/song_title_format.dart';

/// 行级不可变视图数据（R-1）。
///
/// 列表容器一次性把数据集映射为 `List<SongRowView>` 下发给行组件，行组件以
/// **值参数**渲染、**不再订阅整个 [DirectSourceManager]**、不再每行重复做派生
/// 文本计算与查询。这样任意一次数据通知都不会导致「可见行整屏 rebuild + 逐行
/// 重算」——这是滑动/过渡动画期间 UI 线程长帧的主要来源之一。
///
/// 字段对应 spec.md「行渲染数据」：播放中态、选中态、收藏/不喜欢、标题显示格式、
/// 封面显示路径等低频数据。
class SongRowView {
  const SongRowView({
    required this.songKey,
    required this.titleText,
    required this.subtitleText,
    this.wideInfoText,
    this.coverPath,
    this.playing = false,
    this.selected = false,
    this.favorite = false,
    this.disliked = false,
    this.isFirst = false,
    this.isLast = false,
  });

  /// 稳定行键（`sourceKey|sourceRef|id`，与多选/去重口径一致）。
  final String songKey;

  /// 已按设置格式化的显示标题。
  final String titleText;

  /// 副标题（歌手 · 专辑 · 专辑歌手）。
  final String subtitleText;

  /// 宽行技术信息（格式 · 码率 · 大小）；窄行 / 全缺时为 null。
  final String? wideInfoText;

  /// 封面显示路径（本机缩略图或原图）。
  final String? coverPath;

  final bool playing;
  final bool selected;
  final bool favorite;
  final bool disliked;
  final bool isFirst;
  final bool isLast;

  /// 由列表容器按需计算一行视图数据（派生文本一次算好，避免每帧重算）。
  factory SongRowView.of({
    required Song song,
    required SongTitleFormat titleFormat,
    bool playing = false,
    bool selected = false,
    bool favorite = false,
    bool disliked = false,
    bool isFirst = false,
    bool isLast = false,
    bool wide = false,
  }) =>
      SongRowView(
        songKey: songRowKey(song),
        titleText: formatSongTitle(song, titleFormat),
        subtitleText: subtitleOf(song),
        wideInfoText: wide ? wideInfoOf(song) : null,
        coverPath: song.coverPath,
        playing: playing,
        selected: selected,
        favorite: favorite,
        disliked: disliked,
        isFirst: isFirst,
        isLast: isLast,
      );

  /// 副标题：歌手 · 专辑（· 专辑歌手，仅当与歌手不同时展示，避免冗余）。
  static String subtitleOf(Song song) {
    final artist = song.artist ?? 'Unknown';
    final parts = <String>[artist];
    final album = song.albumName;
    if (album != null && album.isNotEmpty) parts.add(album);
    final albumArtist = song.albumArtist;
    if (albumArtist != null &&
        albumArtist.isNotEmpty &&
        albumArtist != artist) {
      parts.add('专辑歌手：$albumArtist');
    }
    return parts.join(' · ');
  }

  /// 宽行技术信息：`格式 · 码率 · 大小`。
  ///
  /// 全部由 [Song] 现有字段计算：格式为扫描存下的扩展名（大写）；码率 =
  /// fileSize×8 / 时长（无时长则省略）；大小按 MB（不足 1 MB 降为 KB）。
  /// 缺失项跳过，全缺返回 null（只显示时长）。
  static String? wideInfoOf(Song song) {
    final parts = <String>[];
    final fmt = song.format;
    if (fmt != null && fmt.isNotEmpty) parts.add(fmt.toUpperCase());
    final size = song.fileSize;
    final duration = song.duration;
    if (size > 0 && duration != null && duration > 0) {
      parts.add('${(size * 8 / 1024 / duration).round()} kbps');
    }
    if (size > 0) {
      parts.add(size >= 1024 * 1024
          ? '${(size / 1024 / 1024).toStringAsFixed(1)} MB'
          : '${size ~/ 1024} KB');
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// 行键口径与 `widgets/list_selection.dart` 的 [songKey] 一致
///（`sourceKey|sourceRef|id`）；此处独立实现以避免 widgets 内部循环依赖。
String songRowKey(Song s) => '${s.sourceKey}|${s.sourceRef}|${s.id}';

/// 行级视图数据缓存：签名不变时复用整表，避免每次 build 重算 N 行派生文本
/// 与元数据查询（滑动/重绘不重复全量计算）。
///
/// 用法：容器在 `build` 中调用 [resolve]，签名应涵盖所有会影响行内容的低频
/// 状态（列表身份 / 版本号 / 显示格式 / 宽行与否）。
class SongRowCache {
  Object? _signature;
  List<SongRowView>? _rows;

  List<SongRowView> resolve({
    required Object signature,
    required int length,
    required SongRowView Function(int index) build,
  }) {
    final cached = _rows;
    if (cached != null && _signature == signature && cached.length == length) {
      return cached;
    }
    final rows = List<SongRowView>.generate(length, build, growable: false);
    _signature = signature;
    _rows = rows;
    return rows;
  }

  /// 使缓存失效（列表内容被替换时调用）。
  void invalidate() {
    _signature = null;
    _rows = null;
  }
}
