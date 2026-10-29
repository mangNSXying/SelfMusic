import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/local/app_settings.dart';
import '../platform/harmonyos/path_provider_ohos_retry.dart';
import 'ttc_font.dart';

/// 自定义字体文件不合法（格式不支持、内容损坏等）。
class CustomFontException implements Exception {
  const CustomFontException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 全局界面字体（设置 → 界面 → 文字）的文件与注册管理。
///
/// 设计约束：
/// - 接受 TTF/OTF 单字体与 TTC 集合；TTC 先由用户选择字面，再提取成独立
///   单字体文件（`FontLoader` 对集合只认首字面，直接加载会让中文用户拿到 JP
///   等非预期字形）。
/// - 导入后复制到应用支持目录 `selfmusic/fonts/`，设置里只存家族名/文件名/显示名，
///   原始路径不落库（系统文件选择器返回的路径可能失效）。
/// - 家族名按内容摘要生成：不同字体不会共用同一家族，避免运行期重复注册互相覆盖；
///   同一字体重复导入可幂等复用。
/// - 启动预载（[loadSaved]）在 runApp 前完成，避免首帧系统字体闪一下再切自定义字体。
/// - 字体文件缺失/损坏时清空设置并回退系统字体，不阻塞启动。
class CustomFontService {
  CustomFontService(this.settings);

  final AppSettings settings;

  static const String _familyPrefix = 'SelfMusicCustomFont_';

  /// 本进程内已注册的家族：重复导入同一文件时跳过 FontLoader，避免重复注册。
  static final Set<String> _loadedFamilies = <String>{};

  /// 最近一次列出字面的 TTC 字节缓存：设置页先列表、再按选择导入，避免把
  /// 几十 MB 的集合文件读两遍。仅保留一份，导入完成即释放。
  Uint8List? _inspectedBytes;
  String? _inspectedPath;

  /// 当前生效的自定义字体家族名（null=系统默认）。
  String? get family {
    final v = settings.customFontFamily;
    return v.isEmpty ? null : v;
  }

  /// 启动时恢复已保存字体。返回注册好的家族名；无配置/不可用时返回 null。
  Future<String?> loadSaved() async {
    final savedFamily = family;
    final fileName = settings.customFontFile;
    if (savedFamily == null || fileName.isEmpty) {
      if (savedFamily != null ||
          fileName.isNotEmpty ||
          settings.customFontLabel.isNotEmpty) {
        await _clearKeys();
      }
      return null;
    }
    try {
      final file = File(p.join((await _fontDir()).path, fileName));
      if (!await file.exists()) {
        await _clearKeys();
        return null;
      }
      final bytes = await file.readAsBytes();
      if (!_isSupported(bytes)) {
        await _clearKeys();
        return null;
      }
      await _register(savedFamily, bytes);
      return savedFamily;
    } catch (e) {
      debugPrint('自定义字体加载失败，回退系统字体：$e');
      await _clearKeys();
      return null;
    }
  }

  /// 文件头是否为 TTC 集合（扩展名可能不可靠，按内容判断）。
  Future<bool> isTtcFile(String sourcePath) async {
    final raf = await File(sourcePath).open();
    try {
      return isTtcBytes(await raf.read(4));
    } finally {
      await raf.close();
    }
  }

  /// 列出 TTC 内可选字面；非 TTC/格式非法时抛 [CustomFontException]。
  /// 结果与源字节会短暂缓存，供随后的 [importFont] 复用。
  Future<List<TtcFaceInfo>> listTtcFaces({required String sourcePath}) async {
    try {
      final bytes = await File(sourcePath).readAsBytes();
      final faces = readTtcFaces(bytes);
      _inspectedPath = sourcePath;
      _inspectedBytes = bytes;
      return faces;
    } on TtcFormatException catch (e) {
      throw CustomFontException(e.message);
    } catch (e) {
      throw CustomFontException('TTC 字体解析失败：$e');
    }
  }

  /// 导入并注册字体文件，成功后替换当前自定义字体。返回显示名。
  ///
  /// [sourcePath] 为文件选择器返回的路径，[sourceName] 为原文件名（用于显示与
  /// 扩展名校验），[faceIndex] 为 TTC 内选中的字面（非集合忽略）。
  /// 失败时抛 [CustomFontException] 或底层 IO 异常，设置不变。
  Future<String> importFont({
    required String sourcePath,
    required String sourceName,
    int? faceIndex,
  }) async {
    final ext = p.extension(sourceName).toLowerCase();
    if (ext != '.ttf' && ext != '.otf' && ext != '.ttc') {
      throw const CustomFontException('仅支持 TTF / OTF / TTC 字体文件');
    }

    late Uint8List fontBytes;
    late String fontExt;
    late String displayName;
    try {
      final sourceBytes =
          _inspectedPath == sourcePath && _inspectedBytes != null
              ? _inspectedBytes!
              : await File(sourcePath).readAsBytes();
      if (isTtcBytes(sourceBytes)) {
        final faces = readTtcFaces(sourceBytes);
        final selected = faceIndex ?? 0;
        if (selected < 0 || selected >= faces.length) {
          throw const CustomFontException('TTC 字体集合中没有该字面');
        }
        final extracted = extractTtcFace(sourceBytes, selected);
        fontBytes = extracted.bytes;
        fontExt = extracted.extension;
        displayName = extracted.label.isEmpty
            ? '${_displayName(sourceName)} #${selected + 1}'
            : extracted.label;
      } else {
        if (ext == '.ttc') {
          throw const CustomFontException('TTC 文件格式无效');
        }
        fontBytes = sourceBytes;
        fontExt = ext;
        displayName = _displayName(sourceName);
      }
    } on TtcFormatException catch (e) {
      throw CustomFontException(e.message);
    } finally {
      _inspectedPath = null;
      _inspectedBytes = null;
    }

    if (!_isSupported(fontBytes)) {
      throw const CustomFontException('无法识别的字体文件');
    }
    final digest = sha256.convert(fontBytes).toString().substring(0, 16);
    final family = '$_familyPrefix$digest';
    final fileName = 'font_$digest$fontExt';
    // 先注册再落盘/改设置：注册失败时仍保持原字体，不留下半套状态。
    await _register(family, fontBytes);
    final dir = await _fontDir();
    await File(p.join(dir.path, fileName)).writeAsBytes(fontBytes, flush: true);
    await _deleteOtherFiles(dir, keep: fileName);

    final label = _clampLabel(displayName);
    settings
      ..customFontFamily = family
      ..customFontFile = fileName
      ..customFontLabel = label;
    return label;
  }

  /// 清除自定义字体：删除字体文件并清空设置（下次启动回退系统字体）。
  Future<void> clear() async {
    final fileName = settings.customFontFile;
    await _clearKeys();
    if (fileName.isEmpty) return;
    try {
      final file = File(p.join((await _fontDir()).path, fileName));
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('自定义字体文件删除失败（忽略）：$e');
    }
  }

  Future<Directory> _fontDir() async {
    ensureOhosPathWrapper('customFontDir');
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'selfmusic', 'fonts'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> _register(String family, Uint8List bytes) async {
    if (_loadedFamilies.contains(family)) return;
    final loader = FontLoader(family);
    loader.addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
    _loadedFamilies.add(family);
  }

  Future<void> _clearKeys() async {
    settings
      ..customFontFamily = ''
      ..customFontFile = ''
      ..customFontLabel = '';
  }

  Future<void> _deleteOtherFiles(Directory dir, {required String keep}) async {
    try {
      await for (final e in dir.list()) {
        if (e is File && p.basename(e.path) != keep) {
          try {
            await e.delete();
          } catch (err) {
            debugPrint('旧字体文件删除失败：$err');
          }
        }
      }
    } catch (e) {
      debugPrint('字体目录清理失败（忽略）：$e');
    }
  }

  static String _displayName(String sourceName) {
    final name = p.basenameWithoutExtension(sourceName).trim();
    if (name.isEmpty) return '自定义字体';
    return name.length <= 60 ? name : name.substring(0, 60);
  }

  static String _clampLabel(String value) {
    final cleaned = value
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return '自定义字体';
    return cleaned.length <= 60 ? cleaned : cleaned.substring(0, 60);
  }

  /// TTF（0x00010000 / 'true'）与 OTF（'OTTO'）的常见首标签；集合标签拒绝。
  static bool _isSupported(Uint8List b) {
    if (b.length < 4 || isTtcBytes(b)) return false;
    final t = String.fromCharCodes(b.sublist(0, 4));
    return t == 'OTTO' ||
        t == 'true' ||
        (b[0] == 0x00 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00);
  }
}
