import 'dart:convert';
import 'dart:typed_data';

/// TTC 解析/字面提取失败（格式非法、越界、无可用字面等）。
class TtcFormatException implements Exception {
  const TtcFormatException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// TTC 集合内的一个可选字面（face）。
class TtcFaceInfo {
  const TtcFaceInfo({
    required this.index,
    required this.label,
    required this.extension,
  });

  final int index;

  /// 从 name 表解析的显示名；解析不到时为空串（调用方用文件名兜底）。
  final String label;

  /// 提取后应保存的扩展名（.ttf / .otf），由字面的 sfntVersion 决定。
  final String extension;
}

/// 提取出的单字面字体字节。
class TtcExtractedFace {
  const TtcExtractedFace({
    required this.bytes,
    required this.label,
    required this.extension,
  });

  final Uint8List bytes;
  final String label;
  final String extension;
}

const int _tagTtcf = 0x74746366;
const int _tagOtto = 0x4F54544F;
const int _tagTrue = 0x74727565;
const int _tagHead = 0x68656164;
const int _tagName = 0x6E616D65;
const int _tagDsig = 0x44534947;

const int _maxFaces = 1024;
const int _maxTables = 1024;
const Set<int> _wantedNameIds = {1, 2, 4, 16, 17};

final RegExp _controlChars = RegExp(r'[\u0000-\u001F\u007F]');
final RegExp _whitespace = RegExp(r'\s+');

/// 是否为 TTC 字体集合（仅看首标签）。
bool isTtcBytes(Uint8List data) =>
    data.length >= 4 && _readTag(data, 0) == _tagTtcf;

int _readTag(Uint8List data, int offset) =>
    (data[offset] << 24) |
    (data[offset + 1] << 16) |
    (data[offset + 2] << 8) |
    data[offset + 3];

/// 读取集合内全部字面（索引、显示名、提取后的扩展名）。
List<TtcFaceInfo> readTtcFaces(Uint8List data) {
  final parsed = _parseTtc(data);
  return [
    for (final face in parsed.faces)
      TtcFaceInfo(
        index: face.index,
        label: _readFaceLabel(parsed, face),
        extension: _extensionFor(face.sfntVersion),
      ),
  ];
}

/// 把集合内第 [faceIndex] 个字面重建为独立 sfnt 字体。
///
/// 重建时复制该字面引用的表（TTC 内表偏移以集合文件起点为基准），重新计算
/// 表校验和与 head.checkSumAdjustment。DSIG 签名覆盖原集合，重建后必然失效，
/// 直接丢弃该表，避免输出带无效签名。
TtcExtractedFace extractTtcFace(Uint8List data, int faceIndex) {
  final parsed = _parseTtc(data);
  if (faceIndex < 0 || faceIndex >= parsed.faces.length) {
    throw const TtcFormatException('TTC 字体集合中没有该字面');
  }
  final face = parsed.faces[faceIndex];
  final tables = <_TableRecord>[
    for (final table in face.tables)
      if (table.tag != _tagDsig) table,
  ]..sort((a, b) => a.tag.compareTo(b.tag));
  final headIndex = tables.indexWhere((t) => t.tag == _tagHead);
  if (headIndex < 0) {
    throw const TtcFormatException('字面缺少 head 表，无法提取');
  }

  final numTables = tables.length;
  final headerSize = 12 + 16 * numTables;
  final offsets = List<int>.filled(numTables, 0);
  var cursor = _align4(headerSize);
  for (var i = 0; i < numTables; i++) {
    offsets[i] = cursor;
    cursor = _align4(cursor + tables[i].length);
  }

  final out = Uint8List(cursor);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, face.sfntVersion);
  bd.setUint16(4, numTables);
  final maxPow2 = _maxPow2Le(numTables);
  final searchRange = maxPow2 * 16;
  bd.setUint16(6, searchRange);
  bd.setUint16(8, _log2(maxPow2));
  bd.setUint16(10, numTables * 16 - searchRange);

  for (var i = 0; i < numTables; i++) {
    final table = tables[i];
    final start = offsets[i];
    if (table.length > 0) {
      out.setRange(start, start + table.length, data, table.offset);
    }
    // head.checkSumAdjustment 必须按 0 计算，最后再回填全局调整值。
    if (table.tag == _tagHead) bd.setUint32(start + 8, 0);
  }

  for (var i = 0; i < numTables; i++) {
    final table = tables[i];
    final record = 12 + 16 * i;
    bd.setUint32(record, table.tag);
    bd.setUint32(record + 4, _checksum(bd, offsets[i], _align4(table.length)));
    bd.setUint32(record + 8, offsets[i]);
    bd.setUint32(record + 12, table.length);
  }

  final total = _checksum(bd, 0, out.lengthInBytes); // out 长度恒为 4 的倍数
  final adjustment = (0xB1B0AFBA - total) & 0xFFFFFFFF;
  bd.setUint32(offsets[headIndex] + 8, adjustment);

  return TtcExtractedFace(
    bytes: out,
    label: _readFaceLabel(parsed, face),
    extension: _extensionFor(face.sfntVersion),
  );
}

class _ParsedTtc {
  _ParsedTtc(this.data, this.bd, this.faces);
  final Uint8List data;
  final ByteData bd;
  final List<_TtcFace> faces;
}

class _TtcFace {
  _TtcFace(this.index, this.sfntVersion, this.tables);
  final int index;
  final int sfntVersion;
  final List<_TableRecord> tables;
}

class _TableRecord {
  _TableRecord(this.tag, this.offset, this.length);
  final int tag;
  final int offset;
  final int length;
}

_ParsedTtc _parseTtc(Uint8List data) {
  if (data.length < 12) {
    throw const TtcFormatException('TTC 文件过短');
  }
  final bd = ByteData.sublistView(data);
  if (!isTtcBytes(data)) {
    throw const TtcFormatException('不是 TTC 字体集合');
  }
  final version = bd.getUint32(4);
  if (version != 0x00010000 && version != 0x00020000) {
    throw TtcFormatException('不支持的 TTC 版本 0x${version.toRadixString(16)}');
  }
  final count = bd.getUint32(8);
  if (count == 0) {
    throw const TtcFormatException('TTC 字体集合为空');
  }
  if (count > _maxFaces) {
    throw const TtcFormatException('TTC 字面数量异常');
  }
  final headerBytes = 12 + 4 * count + (version == 0x00020000 ? 12 : 0);
  if (headerBytes > data.length) {
    throw const TtcFormatException('TTC 文件头不完整');
  }

  final faces = <_TtcFace>[];
  for (var i = 0; i < count; i++) {
    final offset = bd.getUint32(12 + 4 * i);
    if (offset < headerBytes || offset + 12 > data.length) {
      throw const TtcFormatException('TTC 字面目录越界');
    }
    faces.add(_parseFace(bd, data.length, i, offset, headerBytes));
  }
  return _ParsedTtc(data, bd, faces);
}

_TtcFace _parseFace(
    ByteData bd, int fileLength, int index, int offset, int headerBytes) {
  final sfntVersion = bd.getUint32(offset);
  if (sfntVersion != 0x00010000 &&
      sfntVersion != _tagOtto &&
      sfntVersion != _tagTrue) {
    throw const TtcFormatException('字面使用了不支持的字体格式');
  }
  final numTables = bd.getUint16(offset + 4);
  if (numTables == 0 || numTables > _maxTables) {
    throw const TtcFormatException('字面表目录数量异常');
  }
  final dirEnd = offset + 12 + 16 * numTables;
  if (dirEnd > fileLength) {
    throw const TtcFormatException('字面表目录越界');
  }

  final tables = <_TableRecord>[];
  final seenTags = <int>{};
  for (var i = 0; i < numTables; i++) {
    final record = offset + 12 + 16 * i;
    final tag = bd.getUint32(record);
    final tableOffset = bd.getUint32(record + 8);
    final tableLength = bd.getUint32(record + 12);
    if (tableOffset < headerBytes ||
        tableLength > fileLength ||
        tableOffset > fileLength - tableLength) {
      throw const TtcFormatException('字面表数据越界');
    }
    if (!seenTags.add(tag)) {
      throw const TtcFormatException('字面存在重复表');
    }
    tables.add(_TableRecord(tag, tableOffset, tableLength));
  }

  _TableRecord? head;
  for (final t in tables) {
    if (t.tag == _tagHead) {
      head = t;
      break;
    }
  }
  if (head == null || head.length < 54) {
    throw const TtcFormatException('字面缺少有效的 head 表');
  }
  return _TtcFace(index, sfntVersion, tables);
}

String _readFaceLabel(_ParsedTtc parsed, _TtcFace face) {
  _TableRecord? name;
  for (final t in face.tables) {
    if (t.tag == _tagName) {
      name = t;
      break;
    }
  }
  if (name == null || name.length < 6) return '';

  final bd = parsed.bd;
  final base = name.offset;
  final nameEnd = base + name.length;
  if (nameEnd > parsed.data.length) return '';
  final count = bd.getUint16(base + 2);
  final stringOffset = bd.getUint16(base + 4);
  if (6 + 12 * count > name.length || stringOffset > name.length) {
    return '';
  }
  final stringBase = base + stringOffset;
  if (stringBase > nameEnd) return '';

  final best = <int, String>{};
  final bestScore = <int, int>{};
  for (var i = 0; i < count; i++) {
    final record = base + 6 + 12 * i;
    if (record + 12 > nameEnd) return '';
    final platform = bd.getUint16(record);
    final encoding = bd.getUint16(record + 2);
    final language = bd.getUint16(record + 4);
    final nameId = bd.getUint16(record + 6);
    if (!_wantedNameIds.contains(nameId)) continue;
    final length = bd.getUint16(record + 8);
    final offset = bd.getUint16(record + 10);
    final start = stringBase + offset;
    if (start < 0 || start + length > nameEnd) continue;
    final decoded = _decodeName(parsed.data, start, length, platform, encoding);
    if (decoded == null) continue;
    final text = _cleanName(decoded);
    if (text.isEmpty) continue;
    final score = _nameScore(platform, encoding, language);
    if (score > (bestScore[nameId] ?? -1)) {
      bestScore[nameId] = score;
      best[nameId] = text;
    }
  }

  final family = best[16] ?? best[1];
  final subfamily = best[17] ?? best[2];
  if (family == null) return best[4] ?? '';
  if (subfamily == null || _isRegularLabel(subfamily)) return family;
  return '$family $subfamily';
}

String? _decodeName(
    Uint8List data, int start, int length, int platform, int encoding) {
  if (length <= 0) return null;
  if (platform == 0 || platform == 3) {
    if (length.isOdd) return null;
    final units = <int>[];
    for (var i = 0; i < length; i += 2) {
      units.add((data[start + i] << 8) | data[start + i + 1]);
    }
    return String.fromCharCodes(units);
  }
  // 旧 Mac 字体常见 MacRoman；高字节映射不精确，但仅作 Windows/Unicode
  // 名称缺失时的兜底显示名。
  if (platform == 1 && encoding == 0) {
    return latin1.decode(Uint8List.sublistView(data, start, start + length),
        allowInvalid: true);
  }
  return null;
}

int _nameScore(int platform, int encoding, int language) {
  if (platform == 3) {
    var score = 300;
    score += switch (language) {
      0x0804 || 0x1004 => 40, // 简体中文
      0x0404 || 0x0C04 => 30, // 繁体中文
      0x0409 => 20, // en-US
      _ => 10,
    };
    return score;
  }
  if (platform == 0) return 200 + (language == 0 ? 10 : 0);
  if (platform == 1 && encoding == 0) return 100 + (language == 0 ? 5 : 0);
  return 0;
}

String _cleanName(String raw) => raw
    .replaceAll('\uFEFF', '')
    .replaceAll(_controlChars, ' ')
    .replaceAll(_whitespace, ' ')
    .trim();

bool _isRegularLabel(String value) {
  final v = value.toLowerCase();
  return v == 'regular' || value == '常规' || value == '标准';
}

String _extensionFor(int sfntVersion) =>
    sfntVersion == _tagOtto ? '.otf' : '.ttf';

int _align4(int value) => (value + 3) & ~3;

int _maxPow2Le(int value) {
  var p = 1;
  while ((p << 1) <= value) {
    p <<= 1;
  }
  return p;
}

int _log2(int value) {
  var v = value;
  var n = 0;
  while (v > 1) {
    v >>= 1;
    n++;
  }
  return n;
}

int _checksum(ByteData bd, int offset, int length) {
  var sum = 0;
  for (var i = 0; i < length; i += 4) {
    sum = (sum + bd.getUint32(offset + i)) & 0xFFFFFFFF;
  }
  return sum;
}
