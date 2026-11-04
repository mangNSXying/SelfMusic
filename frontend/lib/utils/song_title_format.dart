import '../data/local/app_settings.dart';
import '../data/local/audio_metadata.dart';
import '../models/song.dart';
import 'zh_variant.dart';

/// 按设置格式化歌曲显示标题（仅用于 UI 展示，不写回存储/歌单快照/搜索字段）。
///
/// - 文件名：由 sourceRef 推导（服务端 id 等非路径回退到歌名）；
/// - 歌名：存储的 title，未补读元数据时 fast 扫描值即文件名；
/// - 歌手 - 歌名 / 歌名 - 歌手：无歌手时回退为歌名。
String formatSongTitle(Song s, SongTitleFormat format) {
  final rawTitle =
      s.title.trim().isEmpty ? fallbackTitle(s.sourceRef) : s.title;
  // 文件名格式明确展示文件名，不做简繁转换；其余按存储元数据转换展示。
  final stored = zhDisplay(rawTitle);
  final artist = s.artist?.trim() ?? '';
  final displayArtist = zhDisplay(artist);
  return switch (format) {
    SongTitleFormat.fileName =>
      s.sourceRef.contains('/') ? fallbackTitle(s.sourceRef) : stored,
    SongTitleFormat.titleOnly => stored,
    SongTitleFormat.artistTitle =>
      displayArtist.isEmpty ? stored : '$displayArtist - $stored',
    SongTitleFormat.titleArtist =>
      displayArtist.isEmpty ? stored : '$stored - $displayArtist',
  };
}

/// 从设置的当前值格式化（无 settings 时按默认「歌手 - 歌名」）。
String formatSongTitleWith(Song s, AppSettings? settings) =>
    formatSongTitle(s, settings?.songTitleFormat ?? SongTitleFormat.artistTitle);
