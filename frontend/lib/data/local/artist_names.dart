/// 歌手处理.txt：歌手名预处理（纯 Dart，无 io/flutter 依赖，
/// 写隔离 isolate 与解析服务共用）。
///
/// 预处理管线：原串剥括号 → 括号外分隔符拆分 → 逐段原样定身份键。
/// 不做任何归一化折叠（ABBA 与 abba、全角/半角拼写各自成身份），
/// 合并只经 MusicBrainz mbid（人工绑定 / alias 命中）归并。
library;

/// 聚合用的歌手键（canonical_key）：不做任何归一化，原样返回。
/// 同歌手的不同大小写/全半角/撇号写法会各自成身份，不自动合并。
String artistCanonicalKey(String raw) => raw;

/// 剥括号：去掉所有 `(...)`/`（...）` 组并 trim。
/// 括号内容（CV 声优、feat 对象、作品/版本号）为注明类注释一律丢弃；
/// 整组剥除也顺带消解了括号内 `&`/`、`/`・` 对切分器的干扰，
/// 因此切分器不再需要括号上下文保护。整串剥空返回空串（调用方跳过该身份）。
String stripParens(String raw) =>
    raw.replaceAll(RegExp(r'[\(（][^()（）]*[\)）]'), '').trim();

/// 合作串拆分：识别括号外分隔符 `&`/`＆`、`feat.`/`feat`（词边界，defeat 不误拆）
/// 与多艺术家分隔符 `,`（含全角 `，`）、`、`（U+3001）、`・`（U+30FB）/`･`（U+FF65）。
/// 返回原串子串（trim，保留原字符——不做归一化），空段丢弃；
/// 无分隔符或只剥出空串时返回 [raw] 原样（非合作歌行为不变）。
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
    if (c == 0x26 || // &
        c == 0xFF06 || // ＆
        c == 0x2C || // ,
        c == 0xFF0C || // ，
        c == 0x3001 || // 、
        c == 0x30FB || // ・
        c == 0xFF65 // ･
        ) {
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
        end += 1;
      } else if (end < n && !ws(lower.codeUnitAt(end)) &&
          lower.codeUnitAt(end) != 0x29) {
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
  return sawSep ? out : [raw];
}

/// 歌手原串 → 聚合身份键（canonical_key）：剥括号 + trim 后原样返回；
/// 剥空回退原串（保证非空键）。
String artistCanonicalOf(String raw) {
  final seg = stripParens(raw);
  return artistCanonicalKey(seg.isEmpty ? raw : seg);
}

/// 歌手原串 → (canonical, 显示名) 身份列表：剥括号后按合作串逐段一个身份
/// （段内去重，如 `A & A`），非合作串单个。canonical = 显示名 = 原样段，
/// 供身份行 display_name（同一 canonical 跨拼写各自成身份，不拼归一化）。
List<(String, String)> artistCollabCanonicals(String raw) {
  final out = <(String, String)>[];
  final seen = <String>{};
  for (final part in artistCollabParts(stripParens(raw))) {
    if (part.isEmpty) continue;
    final canon = artistCanonicalOf(part);
    if (canon.isEmpty || !seen.add(canon)) continue;
    out.add((canon, canon));
  }
  return out;
}