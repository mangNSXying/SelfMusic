import 'package:flutter/widgets.dart';
import '../data/local/app_settings.dart';
import '../models/song.dart';
import '../utils/duration_format.dart';
import '../utils/song_title_format.dart';

/// 表格模式下一行的 9 个单元格文本（已格式化，行组件只负责摆放）。
class SongTableCells {
  final String title;
  final String artist;
  final String album;
  final String source;
  final String format;
  final String bitrate;
  final String size;
  final String duration;

  const SongTableCells({
    required this.title,
    required this.artist,
    required this.album,
    required this.source,
    required this.format,
    required this.bitrate,
    required this.size,
    required this.duration,
  });

  factory SongTableCells.of(
    Song song, {
    required SongTitleFormat titleFormat,
    String? sourceName,
  }) {
    final source = SongRowView.sourceTextOf(song, sourceName: sourceName);
    return SongTableCells(
      title: SongRowView.tableTitleOf(song, titleFormat),
      artist: SongRowView.artistTextOf(song),
      album: SongRowView.albumTextOf(song),
      source: source.isEmpty ? '—' : source,
      format: SongRowView.formatTextOf(song) ?? '—',
      bitrate: SongRowView.bitrateTextOf(song) ?? '—',
      size: SongRowView.sizeTextOf(song) ?? '—',
      duration: SongRowView.durationTextOf(song),
    );
  }
}

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
    this.tableCells,
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

  /// 宽行技术信息（播放源 · 格式 · 码率 · 大小）；窄行 / 全缺时为 null。
  final String? wideInfoText;

  /// 表格模式的 9 列文本；非表格行为 null。
  final SongTableCells? tableCells;

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
    String? sourceName,
    bool playing = false,
    bool selected = false,
    bool favorite = false,
    bool disliked = false,
    bool isFirst = false,
    bool isLast = false,
    bool wide = false,
    bool table = false,
  }) =>
      SongRowView(
        songKey: songRowKey(song),
        titleText: table
            ? tableTitleOf(song, titleFormat)
            : formatSongTitle(song, titleFormat),
        subtitleText: subtitleOf(song),
        wideInfoText:
            !table && wide ? wideInfoOf(song, sourceName: sourceName) : null,
        tableCells: table
            ? SongTableCells.of(
                song,
                titleFormat: titleFormat,
                sourceName: sourceName,
              )
            : null,
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

  /// 表格标题：已有独立歌手列，默认「歌手 - 歌名」会重复，只保留歌名；
  /// 「文件名」设置仍按文件名展示。
  static String tableTitleOf(Song song, SongTitleFormat format) =>
      formatSongTitle(
        song,
        format == SongTitleFormat.fileName
            ? SongTitleFormat.fileName
            : SongTitleFormat.titleOnly,
      );

  static String artistTextOf(Song song) {
    final artist = song.artist?.trim();
    return artist == null || artist.isEmpty ? '—' : artist;
  }

  static String albumTextOf(Song song) {
    final album = song.albumName?.trim();
    return album == null || album.isEmpty ? '—' : album;
  }

  /// 播放源友好名；调用方取不到时回退到 [Song.source]（可能为空）。
  static String sourceTextOf(Song song, {String? sourceName}) {
    final named = sourceName?.trim();
    if (named != null && named.isNotEmpty) return named;
    return song.source.trim();
  }

  static String? formatTextOf(Song song) {
    final fmt = song.format?.trim();
    return fmt == null || fmt.isEmpty ? null : fmt.toUpperCase();
  }

  /// 码率 = fileSize×8 / 时长；缺大小或时长时返回 null。
  static String? bitrateTextOf(Song song) {
    final size = song.fileSize;
    final duration = song.duration;
    if (size <= 0 || duration == null || duration <= 0) return null;
    return '${(size * 8 / 1024 / duration).round()} kbps';
  }

  /// 大小按 MB（不足 1 MB 降为 KB）；未知大小返回 null。
  static String? sizeTextOf(Song song) {
    final size = song.fileSize;
    if (size <= 0) return null;
    return size >= 1024 * 1024
        ? '${(size / 1024 / 1024).toStringAsFixed(1)} MB'
        : '${size ~/ 1024} KB';
  }

  static String durationTextOf(Song song) =>
      formatDuration(song.duration, empty: '—');

  /// 宽行技术信息：`播放源 · 格式 · 码率 · 大小`（缺失项跳过，全缺为 null）。
  static String? wideInfoOf(Song song, {String? sourceName}) {
    final parts = <String>[];
    final src = sourceTextOf(song, sourceName: sourceName);
    if (src.isNotEmpty) parts.add(src);
    final fmt = formatTextOf(song);
    if (fmt != null) parts.add(fmt);
    final bitrate = bitrateTextOf(song);
    if (bitrate != null) parts.add(bitrate);
    final size = sizeTextOf(song);
    if (size != null) parts.add(size);
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// 行键口径与 `widgets/list_selection.dart` 的 [songKey] 一致
///（`sourceKey|sourceRef|id`）；此处独立实现以避免 widgets 内部循环依赖。
String songRowKey(Song s) => '${s.sourceKey}|${s.sourceRef}|${s.id}';

/// 行级视图数据缓存：**按被访问的行（可见行）按需派生并缓存**，不再整表
/// `List<SongRowView>` 一次性生成。
///
/// 历史教训：整表 eager 生成让「首进歌单页」那一帧同步跑完 N 行派生——每行
/// `SongRowView.of` 里的 `weight.metaOf` 冷缓存时是 N 条同步 SELECT，正是
/// 播放页切歌单页「首进愣一下」的卡顿源。改为 [ListView.builder] 访问到哪行
/// 才算哪行；算子缓存后按下标复用，不随 build 重复计算，平滑/滚动语义与
/// 改动前一致（签名涵盖影响行内容的低频状态，变化即作废重算）。
///
/// 用法：容器在 `build` 中先调 [begin] 再在行构建器里用 [rowAt]；签名应涵盖
/// 所有会影响行内容的低频状态（列表身份 / 版本号 / 显示格式 / 宽行与否）。
/// [begin] 可顺带编排一次 post-frame 批量元数据预热（[onWarm]，通常指向
/// `SongWeightStore.warmMetaOf`），让滚动首趟也不逐行冷查库——预热编排统一
/// 在此收口，调用方无需各自维护哨兵与帧调度。
class SongRowCache {
  Object? _signature;
  int _length = 0;
  final Map<int, SongRowView> _rows = {};
  bool _dirty = true;
  VoidCallback? _onWarm;
  bool _warmScheduled = false;

  /// 进入一次构建：签名或长度变化即视为数据失效并清空行缓存；[onWarm] 非空时
  /// 对每次失效编排一次 post-frame 批量预热（首帧之后再执行，不进 build 帧）。
  void begin(Object signature, int length, {VoidCallback? onWarm}) {
    if (!_dirty && _signature == signature && _length == length) {
      return;
    }
    _signature = signature;
    _length = length;
    _dirty = false;
    _rows.clear();
    if (onWarm != null) {
      _onWarm = onWarm;
      if (!_warmScheduled) {
        _warmScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _warmScheduled = false;
          _onWarm?.call();
        });
      }
    }
  }

  /// 取第 [index] 行视图数据；未派生时用 [builder] 计算并缓存。
  SongRowView rowAt(int index, SongRowView Function() builder) =>
      _rows.putIfAbsent(index, builder);

  /// 使缓存失效（调用方数据整体替换时使用）。
  void invalidate() {
    _signature = null;
    _rows.clear();
    _dirty = true;
  }
}
