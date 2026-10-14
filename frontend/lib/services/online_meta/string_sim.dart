/// 字符/字符串相似度：移植自 MusicPlayer2 `InternetCommon`。
///
/// - `charSimilarDegree`：相等=1；仅大小写差异=0.8；数字与中文数字对应=0.7；其余=0。
/// - `stringSimilarDegree`：带权编辑距离（cost=1-charSim），相似度=1-d/maxLen，
///   上限截断 256 字符（与原实现一致，避免大文本 DP 爆炸）。
library;

const Map<String, String> _digitToCn = {
  '0': '零',
  '1': '一',
  '2': '二',
  '3': '三',
  '4': '四',
  '5': '五',
  '6': '六',
  '7': '七',
  '8': '八',
  '9': '九',
};

double charSimilarDegree(String a, String b) {
  if (a == b) return 1.0;
  if (a.toLowerCase() == b.toLowerCase()) return 0.8;
  final cnA = _digitToCn[a];
  if (cnA != null && cnA == b) return 0.7;
  final cnB = _digitToCn[b];
  if (cnB != null && cnB == a) return 0.7;
  return 0.0;
}

/// MusicPlayer2 `StringSimilarDegree_LD` 的 Dart 移植。
double stringSimilarDegree(String s, String t) {
  var a = s;
  var b = t;
  if (a.length > 256) a = a.substring(0, 256);
  if (b.length > 256) b = b.substring(0, 256);
  final n = a.length;
  final m = b.length;
  if (n == 0 && m == 0) return 1.0;
  if (n == 0 || m == 0) return 0.0;
  final ar = a.runes.toList();
  final br = b.runes.toList();
  final nn = ar.length;
  final mm = br.length;
  var prev = List<double>.filled(mm + 1, 0);
  var curr = List<double>.filled(mm + 1, 0);
  for (var j = 0; j <= mm; j++) {
    prev[j] = j.toDouble();
  }
  for (var i = 1; i <= nn; i++) {
    curr[0] = i.toDouble();
    final ca = String.fromCharCode(ar[i - 1]);
    for (var j = 1; j <= mm; j++) {
      final cb = String.fromCharCode(br[j - 1]);
      final cost = 1.0 - charSimilarDegree(ca, cb);
      final del = prev[j] + 1.0;
      final ins = curr[j - 1] + 1.0;
      final sub = prev[j - 1] + cost;
      var v = del < ins ? del : ins;
      v = v < sub ? v : sub;
      curr[j] = v;
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  final dist = prev[mm];
  final maxLen = nn > mm ? nn : mm;
  return 1.0 - dist / maxLen;
}

/// MusicPlayer2 `SelectMatchedItem` 权重（阈值 0.3，原实现）。
///
/// [filename] 为不带扩展名的文件名（调用方处理）。
double matchWeight({
  required String title,
  required String artist,
  required String album,
  required String candidateTitle,
  required String candidateArtist,
  required String candidateAlbum,
  required String filename,
  required int index,
}) {
  double sim(String x, String y) {
    if (x.trim().isEmpty || y.trim().isEmpty) return 0.0;
    return stringSimilarDegree(x.trim().toLowerCase(), y.trim().toLowerCase());
  }

  final w = sim(title, candidateTitle) * 0.4 +
      sim(artist, candidateArtist) * 0.4 +
      sim(album, candidateAlbum) * 0.3 +
      sim(filename, candidateTitle) * 0.3 +
      sim(filename, candidateArtist) * 0.3 +
      (1 - index * 0.02) * 0.05;
  return w;
}

/// 在候选列表中选最佳下标；最高分 <0.3 视为无匹配，返回 -1。
int selectBestMatch({
  required String title,
  required String artist,
  required String album,
  required String filename,
  required List<({String title, String artist, String album})> candidates,
}) {
  var best = -1;
  var bestW = 0.3;
  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    final w = matchWeight(
      title: title,
      artist: artist,
      album: album,
      candidateTitle: c.title,
      candidateArtist: c.artist,
      candidateAlbum: c.album,
      filename: filename,
      index: i,
    );
    if (w > bestW) {
      bestW = w;
      best = i;
    }
  }
  return best;
}
