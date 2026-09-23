/// LRC 歌词解析（纯函数，供播放页歌词视图使用）。
library;

/// 一行带时间轴的歌词（[translation] 为译文，可空）。
class LyricLine {
  final Duration time;
  final String text;

  /// 译文（同行 `原文 / 译文` 拆分，或紧随的无时间轴译文行）。
  final String? translation;
  const LyricLine(this.time, this.text, [this.translation]);
}

/// 解析结果：带时间轴的 [lines]，或退化为纯文本 [plain]（二者至多一个有值）。
class ParsedLyrics {
  final List<LyricLine> lines;
  final String? plain;
  const ParsedLyrics({this.lines = const [], this.plain});

  bool get isEmpty => lines.isEmpty && (plain == null || plain!.trim().isEmpty);
}

/// 歌词行拆分：`原文 / 译文` → (原文, 译文)；无分隔或任一侧为空时原样返回。
(String, String?) splitLyricTranslation(String text) {
  final sep = text.indexOf(' / ');
  if (sep <= 0) return (text, null);
  final original = text.substring(0, sep).trim();
  final translation = text.substring(sep + 3).trim();
  if (original.isEmpty || translation.isEmpty) return (text, null);
  return (original, translation);
}

/// 解析歌词原文（LRC 或纯文本）。
///
/// - 支持一行多个时间标签 `[mm:ss.xx][mm:ss.xx]文本`；
/// - 支持 `[offset:±ms]` 全局偏移；
/// - 其余 `[ti:]/[ar:]` 等元信息行忽略；
/// - 同行 `原文 / 译文` 拆分为译文（作为同一行整体展示）；
/// - 有时间轴歌词后出现的无时间轴行视为上一行的独立译文行；
/// - 无任何时间标签时退化为纯文本（按原换行保留）。
ParsedLyrics parseLyrics(String raw) {
  final lines = <LyricLine>[];
  final plainLines = <String>[];
  var offsetMs = 0;
  final timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  final metaTag =
      RegExp(r'^\[(ti|ar|al|by|offset):(.*)\]$', caseSensitive: false);

  for (final rawLine
      in raw.replaceFirst('\uFEFF', '').split(RegExp(r'\r?\n'))) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final meta = metaTag.firstMatch(line);
    if (meta != null) {
      if (meta.group(1)!.toLowerCase() == 'offset') {
        offsetMs = int.tryParse(meta.group(2)!.trim()) ?? 0;
      }
      continue;
    }
    final tags = timeTag.allMatches(line).toList();
    if (tags.isEmpty) {
      // 有时间轴歌词后出现的无时间轴行：作为上一行的独立译文（多行译文换行拼接）。
      if (lines.isNotEmpty) {
        final last = lines.last;
        lines[lines.length - 1] = LyricLine(
          last.time,
          last.text,
          last.translation == null ? line : '${last.translation}\n$line',
        );
      } else {
        plainLines.add(line);
      }
      continue;
    }
    final rawText = line.substring(tags.last.end).trim();
    if (rawText.isEmpty) continue; // 纯时间行（间奏标记）跳过
    final (text, translation) = splitLyricTranslation(rawText);
    for (final m in tags) {
      final minutes = int.parse(m.group(1)!);
      final seconds = int.parse(m.group(2)!);
      final fracRaw = m.group(3);
      var fracMs = 0;
      if (fracRaw != null && fracRaw.isNotEmpty) {
        final v = int.parse(fracRaw);
        fracMs = switch (fracRaw.length) {
          1 => v * 100,
          2 => v * 10,
          _ => v,
        };
      }
      var ms = minutes * 60000 + seconds * 1000 + fracMs + offsetMs;
      if (ms < 0) ms = 0;
      lines.add(LyricLine(Duration(milliseconds: ms), text, translation));
    }
  }

  if (lines.isEmpty) {
    final plain = plainLines.join('\n').trim();
    return ParsedLyrics(plain: plain.isEmpty ? null : plain);
  }
  lines.sort((a, b) => a.time.compareTo(b.time));
  return ParsedLyrics(lines: lines);
}

/// 返回 [pos] 时刻应高亮的行下标：最后一个 time ≤ pos；早于首行返回 -1。
int lyricIndexAt(List<LyricLine> lines, Duration pos) {
  if (lines.isEmpty) return -1;
  var lo = 0;
  var hi = lines.length - 1;
  var ans = -1;
  final ms = pos.inMilliseconds;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].time.inMilliseconds <= ms) {
      ans = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return ans;
}
