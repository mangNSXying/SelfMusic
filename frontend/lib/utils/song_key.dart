/// 歌曲身份键：`(sourceKey, sourceRef)` 的规范编码。
///
/// 全应用（缓存 / 播放 / 权重 / 同步 / 选择集）统一用这一个分隔符与顺序；
/// 不要再用 `|` 或临时拼接。
library;

import '../models/song.dart';

/// `sourceKey\u0000sourceRef`。
String songKeyOf(String sourceKey, String sourceRef) =>
    '$sourceKey\u0000$sourceRef';

extension SongKeyExt on Song {
  /// 该歌曲的身份键（等价于 [songKeyOf]）。
  String get uid => songKeyOf(sourceKey, sourceRef);
}
