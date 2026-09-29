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

/// 歌手原串 → 聚合身份键（canonical_key）：CV 注记按「角色|人物」（不同拼写仍
/// 各自成身份，经 mbid 合流）；其余取整串原样。
String artistCanonicalOf(String raw) {
  final p = splitArtistPart(raw);
  if (p.hasCv) {
    final b = p.base.isEmpty ? p.cvName! : '${p.base}|${p.cvName}';
    return artistCanonicalKey(b);
  }
  return artistCanonicalKey(raw);
}

/// 合作串拆分（「A & B」「A feat. B」）：识别 [&]/[＆] 与独立 token
/// feat./feat（词边界，defeat 不误拆）。返回原串子串（trim），空段丢弃；
/// 无分隔符或无实质拆分时返回 [raw] 原样（非合作歌行为不变）。
///
/// 分隔符只做 `＆→&` 一层折半，各部分保留原字符——与「不做归一化」决策一致
/// （`ＡＢＢＡ & 内田真礼` → `ＡＢＢＡ`、`内田真礼`）。
List<String> artistCollabParts(String raw) {
  final out = <String>[];
  final n = raw.length;
  final lower = raw.toLowerCase();
  var start = 0;
  var i = 0;
  var sawSep = false;
  void cut(int before) {
    final seg = raw.substring(start, before).trim();
    if (seg.isNotEmpty) out.add(seg);
  }

  bool wordChar(int cu) =>
      (cu >= 0x30 && cu <= 0x39) || // 0-9
      (cu >= 0x41 && cu <= 0x5A) ||
      (cu >= 0x61 && cu <= 0x7A) ||
      cu == 0x5F; // _

  bool ws(int cu) =>
      cu == 0x20 || cu == 0x09 || cu == 0x0A || cu == 0x0D || cu == 0x3000;

  while (i < n) {
    final c = lower.codeUnitAt(i);
    if (c == 0x26 || c == 0xFF06) {
      // '&' / 全角 '＆'：单码点分隔符。
      cut(i);
      start = i + 1;
      i += 1;
      sawSep = true;
      continue;
    }
    if (i + 4 <= n &&
        lower.startsWith('feat', i) &&
        (i == 0 || !wordChar(lower.codeUnitAt(i - 1)))) {
      var end = i + 4;
      if (end < n && lower.codeUnitAt(end) == 0x2E) {
        // `feat.` 后不要求空白：`A feat.B` 也拆。
        end += 1;
      } else if (end < n && !ws(lower.codeUnitAt(end)) &&
          lower.codeUnitAt(end) != 0x29) {
        // `featX` 视为一个词，不拆。
        i += 1;
        continue;
      }
      cut(i);
      start = end;
      i = end;
      sawSep = true;
      continue;
    }
    i += 1;
  }
  cut(n);
  // 真的消费了分隔符（含首尾空段）按拆分结果走；否则视为非合作串原样返回。
  return sawSep ? out : [raw];
}

/// 歌手原串 → (canonical, 显示名) 身份列表：合作串逐段一个身份（段内去重，
/// 如 `A & A`），非合作串单个。显示名取对应原串段，供身份行 display_name。
List<(String, String)> artistCollabCanonicals(String raw) {
  final out = <(String, String)>[];
  final seen = <String>{};
  for (final part in artistCollabParts(raw)) {
    final canon = artistCanonicalOf(part);
    if (canon.isEmpty || !seen.add(canon)) continue;
    out.add((canon, part));
  }
  return out;
}

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