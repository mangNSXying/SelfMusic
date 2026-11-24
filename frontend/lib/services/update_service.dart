import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../data/local/app_settings.dart';
import '../platform/harmonyos/ohos_bootstrap.dart' show isOhos;

/// 发布版的单个下载资产。
class ReleaseAsset {
  const ReleaseAsset({required this.name, required this.url});

  /// 资产文件名（如 `SelfMusic_1.0.3_windows_x64_release.zip`）。
  final String name;

  /// 直链（GitHub/Gitea 均下发 `browser_download_url`）。
  final String url;
}

/// 发布版信息：GitHub 与 Gitea 的 releases 接口字段同名，在此统一收敛。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.name,
    required this.body,
    required this.pageUrl,
    required this.assets,
  });

  /// 版本标签（如 `1.0.5`），版本比较与「本版本不提醒」都以它为准。
  final String tag;

  /// 发布标题（如 `release_1.0.5+7`）。
  final String name;

  /// 更新说明正文（原样文本，可能含 Markdown 记号）。
  final String body;

  /// 发布页地址（`html_url`）：无平台匹配资产时作为跳转兜底。
  final String pageUrl;

  final List<ReleaseAsset> assets;

  /// 去掉 `v` 前缀的展示用版本号。
  String get versionLabel =>
      tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;
}

/// 比较两个版本号：返回负数/0/正数，语义同 [Comparable.compareTo]。
///
/// 忽略 `v` 前缀、预发布后缀（`-beta`）与构建号（`+6`），只按点分段数值比较；
/// 缺失段按 0 补齐（`1.0` == `1.0.0`）。
int compareVersions(String a, String b) {
  final pa = _versionParts(a);
  final pb = _versionParts(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final va = i < pa.length ? pa[i] : 0;
    final vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return va.compareTo(vb);
  }
  return 0;
}

/// [candidate] 是否严格新于 [current]。
bool isNewerVersion(String candidate, String current) =>
    compareVersions(candidate, current) > 0;

List<int> _versionParts(String version) {
  var s = version.trim();
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  s = s.split('+').first.split('-').first;
  return [
    for (final seg in s.split('.'))
      int.tryParse(seg.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0,
  ];
}

/// 当前平台标识（下载资产匹配用）：`windows` / `linux` / `android` / `ohos` / `macos`。
String currentUpdatePlatform() {
  if (isOhos) return 'ohos';
  if (kIsWeb) return 'unknown';
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  return 'unknown';
}

/// 当前 CPU 架构标识（`arm64` / `x64` / `arm`；未知为空串）。
///
/// 按 `Abi.current()` 的枚举名判断而不是比较枚举成员：各平台分支工具链
/// （stable / 鸿蒙 fork）的 Abi 成员集合不同，引用具体成员可能编译不过。
String currentUpdateAbi() {
  final name = Abi.current().toString().toLowerCase();
  if (name.contains('arm64') || name.contains('aarch64')) return 'arm64';
  if (name.contains('x64') || name.contains('ia32')) return 'x64';
  if (name.contains('arm')) return 'arm';
  return '';
}

/// 从发布资产中挑选当前平台的下载直链，无匹配返回 null（调用方回退发布页）。
///
/// 平台命中多个资产（如 Android 多 ABI 安装包）时再按架构细分；架构也匹配不上
/// 就取第一个平台匹配项，避免漏跳。
String? selectDownloadUrl(
  ReleaseInfo release, {
  String? platform,
  String? abi,
}) {
  final p = platform ?? currentUpdatePlatform();
  final a = abi ?? currentUpdateAbi();
  final matched =
      release.assets.where((asset) => _nameMatchesPlatform(asset.name, p));
  final platformMatched = matched.toList();
  if (platformMatched.isEmpty) return null;
  if (platformMatched.length == 1) return platformMatched.first.url;
  if (a.isNotEmpty) {
    for (final asset in platformMatched) {
      if (_nameMatchesAbi(asset.name, a)) return asset.url;
    }
  }
  return platformMatched.first.url;
}

bool _nameMatchesPlatform(String name, String platform) {
  final n = name.toLowerCase();
  return switch (platform) {
    'windows' => n.contains('windows'),
    'linux' => n.contains('linux'),
    'android' => n.contains('android') || n.endsWith('.apk'),
    'ohos' => n.contains('ohos') || n.endsWith('.app') || n.endsWith('.hap'),
    'macos' => n.contains('macos') || n.contains('darwin'),
    _ => false,
  };
}

bool _nameMatchesAbi(String name, String abi) {
  final n = name.toLowerCase();
  return switch (abi) {
    'arm64' => n.contains('arm64') || n.contains('aarch64'),
    'x64' => n.contains('x64') || n.contains('x86_64') || n.contains('x86-64'),
    'arm' => n.contains('armeabi') ||
        (n.contains('arm') && !n.contains('arm64') && !n.contains('aarch64')),
    _ => false,
  };
}

/// 解析 GitHub / Gitea 的 releases 响应。
///
/// 过滤草稿与预发布，按版本号取最高者；[data] 非预期结构返回 null。
ReleaseInfo? parseLatestRelease(Object? data) {
  final list = _releaseList(data);
  if (list == null) return null;
  ReleaseInfo? best;
  for (final raw in list) {
    if (raw is! Map) continue;
    final info = _parseRelease(raw);
    if (info == null) continue;
    if (best == null || compareVersions(info.tag, best.tag) > 0) {
      best = info;
    }
  }
  return best;
}

List<dynamic>? _releaseList(Object? data) {
  if (data is List) return data;
  if (data is String && data.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(data);
      if (decoded is List) return decoded;
    } catch (_) {
      return null;
    }
  }
  return null;
}

ReleaseInfo? _parseRelease(Map raw) {
  // 草稿/预发布不参与「最新版」判定。
  if (raw['draft'] == true || raw['prerelease'] == true) return null;
  final tag = (raw['tag_name'] as Object?)?.toString().trim() ?? '';
  if (tag.isEmpty) return null;
  final assets = <ReleaseAsset>[];
  final list = raw['assets'];
  if (list is List) {
    for (final a in list) {
      if (a is! Map) continue;
      final name = (a['name'] as Object?)?.toString() ?? '';
      final url = (a['browser_download_url'] as Object?)?.toString() ?? '';
      if (name.isEmpty || url.isEmpty) continue;
      assets.add(ReleaseAsset(name: name, url: url));
    }
  }
  return ReleaseInfo(
    tag: tag,
    name: (raw['name'] as Object?)?.toString() ?? tag,
    body: (raw['body'] as Object?)?.toString() ?? '',
    pageUrl: (raw['html_url'] as Object?)?.toString() ?? '',
    assets: assets,
  );
}

/// 检查更新：拉取所选源的发布列表并取出最新版本。
class UpdateService {
  UpdateService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));

  /// 全局单例（启动检查与手动检查共用）。
  static final UpdateService instance = UpdateService();

  /// GitHub 要求带 UA，否则拒绝请求。
  static const String _userAgent = 'SelfMusic (self-hosted music player)';

  final Dio _dio;

  /// 各更新源的 releases 接口地址。
  static String releasesApiUrl(UpdateSource source) => switch (source) {
        UpdateSource.gitea =>
          'https://gitea.shamiko.site/api/v1/repos/shamiko/SelfMusic/releases',
        UpdateSource.github =>
          'https://api.github.com/repos/mangNSXying/SelfMusic/releases',
      };

  /// 拉取最新版本；无发布或全部被过滤时返回 null。
  Future<ReleaseInfo?> fetchLatest(UpdateSource source) async {
    final resp = await _dio.get<dynamic>(
      releasesApiUrl(source),
      // GitHub 用 per_page、Gitea 用 limit；多传的参数会被忽略。
      queryParameters: {'per_page': 30, 'limit': 30},
      options: Options(headers: {
        'User-Agent': _userAgent,
        'Accept': 'application/json',
      }),
    );
    return parseLatestRelease(resp.data);
  }
}
