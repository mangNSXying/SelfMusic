/// 播放条目。服务器模式由 `/library/**` 返回的 JSON 构造；直连模式由本地索引构造。
class Song {
  /// 稳定标识：服务器模式为数据库主键；直连模式为主键或合成负 id。
  final int id;

  /// 源标识（DESIGN §6.2 key）：`server` / `webdav:<name>` / `smb:<name>` / `local:<name>`。
  final String sourceKey;
  final String title;
  final String? artist;
  final String? albumName;

  /// 专辑歌手（可空；展示/分组时回退到 [artist]）。
  final String? albumArtist;
  final int? trackNo;
  final int? year;
  final String? genre;
  final int? duration;

  /// 与 MusicSource 的 raw 类型对应的源名（server/local/webdav/smb），用于展示。
  final String source;
  final String sourceRef;
  final int fileSize;
  final String? format;
  final bool favorite;
  final bool hidden;

  /// 直连模式专有：扫描期解析出的完整可请求 URL（如 WebDAV 原始 href）。
  /// 服务器模式 / 历史行可为 null，由源回落到 base+ref 重建。
  final String? sourceUrl;

  /// 直连模式的封面缓存路径（本地文件），服务器模式为空走网络。
  final String? coverPath;

  /// 直连模式专有：此歌唯一引用 `sourceKey|sourceRef`，供索引化/去重。
  final bool isDirect;

  /// 元数据（歌手/专辑/流派/年份/时长/封面等）是否已完整读取过。
  /// 服务端歌曲由服务端完整下发 → 恒 true；直连歌来自索引 `meta_read` 列，
  /// 极简扫描（无时长）时为 false，后台补读成功后才置 true。
  final bool metaRead;

  Song({
    required this.id,
    required this.sourceKey,
    required this.title,
    this.artist,
    this.albumName,
    this.albumArtist,
    this.trackNo,
    this.year,
    this.genre,
    this.duration,
    required this.source,
    required this.sourceRef,
    required this.fileSize,
    this.format,
    this.favorite = false,
    this.hidden = false,
    this.coverPath,
    this.sourceUrl,
    this.isDirect = false,
    this.metaRead = true,
  });

  factory Song.fromJson(Map<String, dynamic> j) => Song(
        id: j['id'] as int,
        sourceKey: j['sourceKey'] as String? ?? 'server',
        title: j['title'] as String? ?? 'Unknown',
        artist: j['artist'] as String?,
        albumName: j['albumName'] as String?,
        albumArtist: j['albumArtist'] as String?,
        trackNo: j['trackNo'] as int?,
        year: j['year'] as int?,
        genre: j['genre'] as String?,
        duration: j['duration'] as int?,
        source: j['source'] as String? ?? 'local',
        sourceRef: j['sourceRef'] as String? ?? '',
        fileSize: j['fileSize'] as int? ?? 0,
        format: j['format'] as String?,
        favorite: j['favorite'] as bool? ?? false,
        hidden: j['hidden'] as bool? ?? false,
        coverPath: j['coverPath'] as String?,
        sourceUrl: j['sourceUrl'] as String?,
      );

  /// 完整序列化（play_meta 快照 / play_state 断点，stage2.md §7）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceKey': sourceKey,
        'title': title,
        if (artist != null) 'artist': artist,
        if (albumName != null) 'albumName': albumName,
        if (albumArtist != null) 'albumArtist': albumArtist,
        if (trackNo != null) 'trackNo': trackNo,
        if (year != null) 'year': year,
        if (genre != null) 'genre': genre,
        if (duration != null) 'duration': duration,
        'source': source,
        'sourceRef': sourceRef,
        'fileSize': fileSize,
        if (format != null) 'format': format,
        'favorite': favorite,
        'hidden': hidden,
        if (coverPath != null) 'coverPath': coverPath,
        if (sourceUrl != null) 'sourceUrl': sourceUrl,
      };

  /// 直连模式行构造（本地索引读出）。
  factory Song.direct({    required int id,
    required String sourceKey,
    required String title,
    String? artist,
    String? albumName,
    String? albumArtist,
    int? trackNo,
    int? year,
    String? genre,
    int? duration,
    required String source,
    required String sourceRef,
    required int fileSize,
    String? format,
    bool favorite = false,
    String? coverPath,
    String? sourceUrl,
    bool metaRead = true,
  }) =>
      Song(
        id: id,
        sourceKey: sourceKey,
        title: title,
        artist: artist,
        albumName: albumName,
        albumArtist: albumArtist,
        trackNo: trackNo,
        year: year,
        genre: genre,
        duration: duration,
        source: source,
        sourceRef: sourceRef,
        fileSize: fileSize,
        format: format,
        favorite: favorite,
        coverPath: coverPath,
        sourceUrl: sourceUrl,
        isDirect: true,
        metaRead: metaRead,
      );

  /// 拷贝（元数据覆盖/刷新用）。
  Song copyWith({
    int? id,
    String? sourceKey,
    String? title,
    String? artist,
    String? albumName,
    String? albumArtist,
    int? trackNo,
    int? year,
    String? genre,
    int? duration,
    String? source,
    String? sourceRef,
    int? fileSize,
    String? format,
    bool? favorite,
    bool? hidden,
    String? coverPath,
    String? sourceUrl,
    bool? isDirect,
    bool? metaRead,
  }) =>
      Song(
        id: id ?? this.id,
        sourceKey: sourceKey ?? this.sourceKey,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        albumName: albumName ?? this.albumName,
        albumArtist: albumArtist ?? this.albumArtist,
        trackNo: trackNo ?? this.trackNo,
        year: year ?? this.year,
        genre: genre ?? this.genre,
        duration: duration ?? this.duration,
        source: source ?? this.source,
        sourceRef: sourceRef ?? this.sourceRef,
        fileSize: fileSize ?? this.fileSize,
        format: format ?? this.format,
        favorite: favorite ?? this.favorite,
        hidden: hidden ?? this.hidden,
        coverPath: coverPath ?? this.coverPath,
        sourceUrl: sourceUrl ?? this.sourceUrl,
        isDirect: isDirect ?? this.isDirect,
        metaRead: metaRead ?? this.metaRead,
      );

  /// 未读取元数据时标注的占位文案（区别于「读取后发现没有」的留白）。
  static const String unreadLabel = '未读取';

  /// 元数据字段展示值：
  /// - 有值 → 原值（极简扫描可能已拿到部分标签）；
  /// - 未读取且无值 → [unreadLabel]，提示尚未读头补全；
  /// - 已读取且无值 → null，调用方留白（确认真没有该字段）。
  String? metaDisplay(String? v) => v ?? (metaRead ? null : unreadLabel);

  /// 当前歌曲的元数据是否仍为「未读取」。
  bool get metaUnread => !metaRead;
}
