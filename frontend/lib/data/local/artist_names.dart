/// 歌手处理.txt：歌手名的归一化与「括号人直解」解析（纯 Dart，无 io/flutter 依赖，
/// 写隔离 isolate 与解析服务共用）。NFKC 把全角（ＣＶ/（）： 等）折成半角，
/// 因此括号与冒号一律以 ASCII 处理。
library;

import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// 归一化后的歌手名：NFKC + 去首尾空白 + 空白折叠。
/// 括号内容保留（「纱路（CV:内田真礼）」仍是展示字符串的主体）。
String normalizeArtistName(String raw) {
  var t = raw.trim();
  if (t.isEmpty) return t;
  final n = unorm.nfkc(t);
  return n.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 聚合用的歌手键（canonical_key）：不做任何归一化，原样返回。
/// 同歌手的不同大小写/全半角/撇号写法会各自成身份，不自动合并；
/// 合并必须经 MusicBrainz mbid（人工绑定 / alias 命中）归并。
/// （归一化带来的 ABBA/abba、`Petit Rabbit’s`/`Petit Rabbit's` 误并已按
/// 需求移除，避免不同真实身份被错误的字符折叠捏合成一个。）
String artistCanonicalKey(String raw) => raw;

/// 「歌手名 × 声优」拆分结果：基名与括号内人物名。
/// 例：`纱路（CV:内田真礼）` → base=`纱路`，cvName=`内田真礼`。
/// 无显式声优注记时 cvName 为 null（整串视为基名，括号原样保留）。
class ArtistNamePart {
  final String base;
  final String? cvName;
  const ArtistNamePart({required this.base, this.cvName});

  bool get hasCv => cvName != null && cvName!.isNotEmpty;
}

/// 拆分歌手原串：仅当最后一个括号组内容形如 `CV:xxx` 才解出人物名；
/// 其余括号（feat./from 作品名等）原样保留，不误判。
ArtistNamePart splitArtistPart(String raw) {
  final norm = normalizeArtistName(raw);
  final matches =
      RegExp(r'\(([^()]*)\)').allMatches(norm).toList();
  for (final mm in matches.reversed) {
    final cv = _cvNameIn(mm.group(1) ?? '');
    if (cv != null) {
      final base = norm.replaceRange(mm.start, mm.end, '').trim();
      return ArtistNamePart(base: base.isEmpty ? norm : base, cvName: cv);
    }
  }
  return ArtistNamePart(base: norm);
}

/// `CV:内田真礼` → `内田真礼`；不匹配返回 null（NFKC 后冒号已是 ASCII）。
String? _cvNameIn(String inner) {
  final m = RegExp(r'^cv\s*:\s*(.+)$', caseSensitive: false)
      .firstMatch(inner.trim());
  if (m == null) return null;
  final v = m.group(1)!.trim();
  return v.isEmpty ? null : v;
}