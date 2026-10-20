import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppVersion {
  AppVersion._();

  static Future<String>? _future;

  static Future<String> load() => _future ??= _read();

  static Future<String> _read() async {
    try {
      final pubspec = await rootBundle.loadString('pubspec.yaml');
      final match = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(pubspec);
      return match?.group(1) ?? '未知';
    } catch (e) {
      debugPrint('读取应用版本失败：$e');
      return '未知';
    }
  }
}
