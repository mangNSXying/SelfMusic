import '../data/local/app_settings.dart';
import '../data/local/audio_metadata.dart';
import '../models/song.dart';

/// 按设置格式化歌曲显示标题（仅用于 UI 展示，不写回存储/歌单快照/搜索字段）。
///
/// - 文件名：由 sourceRef 推导（服务端 id 等非路径回退到歌名）；
/// - 歌名：存储的 title，未补读元数据时 fast 扫描值即文件名；
/// - 歌手 - 歌名 / 歌名 - 歌手：无歌手时回退为歌名。
String formatSongTitle(Song s, SongTitleFormat format) {
  final stored =
      s.title.trim().isEmpty ? fallbackTitle(s.sourceRef) : s.title;
  final artist = s.artist?.trim() ?? '';
  return switch (format) {
    SongTitleFormat.fileName =>
      s.sourceRef.contains('/') ? fallbackTitle(s.sourceRef) : stored,
    SongTitleFormat.titleOnly => stored,
    SongTitleFormat.artistTitle =>
      artist.isEmpty ? stored : '$artist - $stored',
    SongTitleFormat.titleArtist =>
      artist.isEmpty ? stored : '$stored - $artist',
  };
}

/// 从设置的当前值格式化（无 settings 时按默认「歌手 - 歌名」）。
String formatSongTitleWith(Song s, AppSettings? settings) =>
    formatSongTitle(s, settings?.songTitleFormat ?? SongTitleFormat.artistTitle);
