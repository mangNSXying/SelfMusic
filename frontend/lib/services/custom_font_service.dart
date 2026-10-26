import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/local/app_settings.dart';
import '../platform/harmonyos/path_provider_ohos_retry.dart';

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
/// - 只接受 TTF/OTF 单字体文件；TTC 集合不受 Flutter `FontLoader` 支持，明确拒绝。
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

  /// 导入并注册字体文件，成功后替换当前自定义字体。返回显示名。
  ///
  /// [sourcePath] 为文件选择器返回的路径，[sourceName] 为原文件名（用于显示与
  /// 扩展名校验）。失败时抛 [CustomFontException] 或底层 IO 异常，设置不变。
  Future<String> importFont({
    required String sourcePath,
    required String sourceName,
  }) async {
    final ext = p.extension(sourceName).toLowerCase();
    if (ext != '.ttf' && ext != '.otf') {
      throw const CustomFontException('仅支持 TTF / OTF 字体文件');
    }
    final bytes = await File(sourcePath).readAsBytes();
    if (_isTtc(bytes)) {
      throw const CustomFontException('暂不支持 TTC 字体集合，请选择 TTF / OTF');
    }
    if (!_isSupported(bytes)) {
      throw const CustomFontException('无法识别的字体文件');
    }

    final digest = sha256.convert(bytes).toString().substring(0, 16);
    final family = '$_familyPrefix$digest';
    final fileName = 'font_$digest$ext';
    // 先注册再落盘/改设置：注册失败时仍保持原字体，不留下半套状态。
    await _register(family, bytes);
    final dir = await _fontDir();
    await File(p.join(dir.path, fileName)).writeAsBytes(bytes, flush: true);
    await _deleteOtherFiles(dir, keep: fileName);

    final displayName = _displayName(sourceName);
    settings
      ..customFontFamily = family
      ..customFontFile = fileName
      ..customFontLabel = displayName;
    return displayName;
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

  /// TTF（0x00010000 / 'true'）与 OTF（'OTTO'）的常见首标签；TTC（'ttcf'）拒绝。
  static bool _isSupported(Uint8List b) {
    if (b.length < 4) return false;
    if (_isTtc(b)) return false;
    final t = String.fromCharCodes(b.sublist(0, 4));
    return t == 'OTTO' ||
        t == 'true' ||
        (b[0] == 0x00 && b[1] == 0x01 && b[2] == 0x00 && b[3] == 0x00);
  }

  static bool _isTtc(Uint8List b) {
    if (b.length < 4) return false;
    return b[0] == 0x74 && b[1] == 0x74 && b[2] == 0x63 && b[3] == 0x66;
  }
}
