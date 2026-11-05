/// 简繁显示转换（纯 Dart + OpenCC 文本词库）。
///
/// 信息层（SQLite / 模型 / 歌单快照 / 同步载荷）永远保存原文；本模块只在
/// 展示边界把文本转成用户选择的字形，**不写回任何存储**。
///
/// - 词库：`assets/opencc/`（OpenCC ver.1.4.2，Apache-2.0）；
/// - 启动后后台预热，搜索折叠与显示设置解耦（默认「原文」也能简繁互搜）；
///   「原文」只关闭展示转换，词库常驻供搜索使用；
/// - 只在 UI isolate 使用，后台 isolate（扫描/库快照）始终读原文。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'enum_parse.dart';

import 'off_thread.dart';

/// 简繁显示（设置→界面）：只影响元数据展示，不修改任何存储字段。
enum ZhVariant {
  original('原文', '不转换，保持元数据原字'),
  simplified('简体', '繁体元数据以简体显示'),
  traditional('繁体', '简体元数据以繁体显示');

  const ZhVariant(this.label, this.hint);
  final String label;
  final String hint;

  static ZhVariant parse(String? v) =>
      enumByNameOr(ZhVariant.values, v, ZhVariant.original);
}

const String _kTsCharacters = 'assets/opencc/TSCharacters.txt';
const String _kTsPhrases = 'assets/opencc/TSPhrases.txt';
const String _kStCharacters = 'assets/opencc/STCharacters.txt';
const String _kStPhrases = 'assets/opencc/STPhrases.txt';

/// 词组最长匹配上限（runes）。OpenCC 词条绝大多数不超过 8 字，留足余量。
const int _kMaxPhraseRunes = 16;

/// 展示/搜索转换的 memo 缓存上限；超过即整表清空（字符串重复率高，命中率很好）。
const int _kCacheLimit = 20000;

ZhVariant _variant = ZhVariant.original;
int _revision = 0;
OpenccConverter? _t2s;
OpenccConverter? _s2t;

final Map<String, String> _displayCache = {};
final Map<String, String> _foldCache = {};

/// 当前生效的简繁显示口径。
ZhVariant get zhVariant => _variant;

/// 切换版本号：每次切换/安装词库时自增，供缓存键使用。
int get zhVariantRevision => _revision;

/// 按当前设置转换展示文本；`原文` / 未加载词库时原样返回。
String zhDisplay(String text) {
  if (text.isEmpty || _variant == ZhVariant.original) return text;
  final dict = _variant == ZhVariant.simplified ? _t2s : _s2t;
  if (dict == null) return text;
  final hit = _displayCache[text];
  if (hit != null) return hit;
  final out = dict.convert(text);
  _put(_displayCache, text, out);
  return out;
}

/// 搜索归一：统一折叠为简体（与当前显示方向无关），供两侧比较。
///
/// **与显示设置解耦**：只要搜索词库已预热，「原文」模式同样折叠，
/// 保证默认设置下也能简繁互搜；词库未就绪时暂时按原字面匹配。
String zhSearchFold(String? text) {
  if (text == null || text.isEmpty) return '';
  if (_t2s == null) return text;
  final hit = _foldCache[text];
  if (hit != null) return hit;
  final out = _t2s!.convert(text);
  _put(_foldCache, text, out);
  return out;
}

/// SQL 搜索的查询变体：原文 + 简体形 + 繁体形（去重、保序）。
///
/// 数据库列里存的是原文，SQL 无法转换列值，只能把查询词展开成两种字形，
/// 让 `LIKE` 分别命中简繁两种存储。
List<String> zhQueryVariants(String query) {
  final q = query.trim();
  if (q.isEmpty) return const [];
  final out = <String>[q];
  if (_t2s == null || _s2t == null) return out;
  final simplified = _t2s!.convert(q);
  if (simplified.isNotEmpty && !out.contains(simplified)) out.add(simplified);
  final traditional = _s2t!.convert(q);
  if (traditional.isNotEmpty && !out.contains(traditional)) {
    out.add(traditional);
  }
  return out;
}

/// 应用简繁设置：按需加载词库、切换展示口径、清缓存并推进版本号。
///
/// 词库加载后常驻（搜索折叠始终需要）；并发调用按顺序串行；返回 false
/// 表示词库加载失败（已回退原文）。
Future<bool> applyZhVariant(ZhVariant target) {
  final next = _serial.then((_) => _applyNow(target));
  _serial = next.then((_) => true, onError: (_) => false);
  return next;
}

Future<bool> _serial = Future.value(true);

/// 预热搜索词库（与显示设置无关）。
///
/// 搜索折叠在「原文」模式下也要生效，因此启动后可后台调用本方法加载词库；
/// 返回 true 表示本次新加载完成（调用方可据此通知列表重算已按搜索过滤的结果）。
Future<bool> ensureZhSearchEngine() {
  final next = _serial.then((_) => _ensureSearchReadyNow());
  _serial = next.then((_) => true, onError: (_) => false);
  return next;
}

Future<bool> _ensureSearchReadyNow() async {
  if (_t2s != null && _s2t != null) return false;
  try {
    final loaded = await _loadDictionaries();
    _t2s = loaded.t2s;
    _s2t = loaded.s2t;
    _bumpRevision();
    return true;
  } catch (e, st) {
    debugPrint('[zh] 搜索词库预热失败（暂按原字面匹配）：$e\n$st');
    return false;
  }
}

Future<bool> _applyNow(ZhVariant target) async {
  if (target == ZhVariant.original) {
    // 只关闭展示转换；词库保留给搜索折叠（默认原文也要能简繁互搜）。
    final changed = _variant != ZhVariant.original;
    _variant = ZhVariant.original;
    if (changed) _bumpRevision();
    return true;
  }
  if (_variant == target && _t2s != null && _s2t != null) return true;
  try {
    if (_t2s == null || _s2t == null) {
      final loaded = await _loadDictionaries();
      _t2s = loaded.t2s;
      _s2t = loaded.s2t;
    }
    _variant = target;
    _bumpRevision();
    return true;
  } catch (e, st) {
    debugPrint('[zh] 简繁词库加载失败，回退原文：$e\n$st');
    _variant = ZhVariant.original;
    _t2s = null;
    _s2t = null;
    _bumpRevision();
    return false;
  }
}

Future<({OpenccConverter t2s, OpenccConverter s2t})> _loadDictionaries() async {
  final texts = await Future.wait([
    rootBundle.loadString(_kTsCharacters),
    rootBundle.loadString(_kTsPhrases),
    rootBundle.loadString(_kStCharacters),
    rootBundle.loadString(_kStPhrases),
  ]);
  return runOffThread(() {
    final t2s = OpenccConverter.fromEntries({
      ...parseOpenccEntries(texts[0]),
      ...parseOpenccEntries(texts[1]),
    });
    final s2t = OpenccConverter.fromEntries({
      ...parseOpenccEntries(texts[2]),
      ...parseOpenccEntries(texts[3]),
    });
    return (t2s: t2s, s2t: s2t);
  });
}

void _bumpRevision() {
  _revision++;
  _displayCache.clear();
  _foldCache.clear();
}

void _put(Map<String, String> cache, String key, String value) {
  if (cache.length >= _kCacheLimit) cache.clear();
  cache[key] = value;
}

/// 解析 OpenCC 文本词典：`key\tvalue1 value2 ...`，取第一个 value。
///
/// 跳过 `#` 注释与空行；key 为单个 rune 时进单字表，否则进词组表。
Map<String, String> parseOpenccEntries(String text) {
  final out = <String, String>{};
  for (final raw in text.split('\n')) {
    final line = raw.endsWith('\r')
        ? raw.substring(0, raw.length - 1)
        : raw;
    if (line.isEmpty || line.codeUnitAt(0) == 0x23) continue; // '#'
    final tab = line.indexOf('\t');
    if (tab <= 0) continue;
    final key = line.substring(0, tab);
    final rest = line.substring(tab + 1).trim();
    if (key.isEmpty || rest.isEmpty) continue;
    final space = rest.indexOf(' ');
    out[key] = space < 0 ? rest : rest.substring(0, space);
  }
  return out;
}

/// OpenCC 词库转换器：词组最长匹配优先，单字表兜底。
class OpenccConverter {
  OpenccConverter.fromEntries(Map<String, String> entries) {
    for (final e in entries.entries) {
      if (e.key.isEmpty || e.value.isEmpty) continue;
      if (e.key.runes.length == 1) {
        _chars[e.key] = e.value;
      } else {
        _phrases[e.key] = e.value;
      }
    }
    var maxLen = 2;
    for (final k in _phrases.keys) {
      final n = k.runes.length;
      if (n > maxLen) maxLen = n;
    }
    _maxPhraseLen = math.min(maxLen, _kMaxPhraseRunes);
    _phraseStarts = {for (final k in _phrases.keys) k.runes.first};
  }

  final Map<String, String> _chars = {};
  final Map<String, String> _phrases = {};
  late final int _maxPhraseLen;
  late final Set<int> _phraseStarts;

  /// 转换整段文本；不含 CJK 的串原样返回（不分配）。
  String convert(String input) {
    if (input.isEmpty) return input;
    var hasCjk = false;
    for (final r in input.runes) {
      if (_isCjk(r)) {
        hasCjk = true;
        break;
      }
    }
    if (!hasCjk) return input;

    final runes = input.runes.toList(growable: false);
    final buf = StringBuffer();
    var i = 0;
    while (i < runes.length) {
      String? replacement;
      var consumed = 1;
      if (_phraseStarts.contains(runes[i])) {
        final maxLen = math.min(_maxPhraseLen, runes.length - i);
        for (var len = maxLen; len >= 2; len--) {
          final hit = _phrases[String.fromCharCodes(runes, i, i + len)];
          if (hit != null) {
            replacement = hit;
            consumed = len;
            break;
          }
        }
      }
      replacement ??= _chars[String.fromCharCodes(runes, i, i + 1)];
      if (replacement == null) {
        buf.writeCharCode(runes[i]);
      } else {
        buf.write(replacement);
      }
      i += consumed;
    }
    return buf.toString();
  }

  static bool _isCjk(int r) =>
      (r >= 0x3400 && r <= 0x4DBF) ||
      (r >= 0x4E00 && r <= 0x9FFF) ||
      (r >= 0xF900 && r <= 0xFAFF) ||
      (r >= 0x20000 && r <= 0x3FFFF);
}

// ---------- 测试辅助（生产代码不要调用） ----------

/// 直接安装转换器，跳过 asset 加载。
@visibleForTesting
void debugInstallZhConvertersForTest({
  required OpenccConverter t2s,
  required OpenccConverter s2t,
  ZhVariant variant = ZhVariant.simplified,
}) {
  _t2s = t2s;
  _s2t = s2t;
  _variant = variant;
  _bumpRevision();
}

/// 恢复默认「原文」，避免测试间互相污染。
@visibleForTesting
void debugResetZhForTest() {
  _variant = ZhVariant.original;
  _t2s = null;
  _s2t = null;
  _bumpRevision();
}
