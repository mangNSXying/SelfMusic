import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'music_source.dart';

/// 转码门控（纯函数）：代理总开关开 + 后端可达 +
/// 该源在新增/编辑弹窗中选了代理链路。直连源恒走原生 URL，开关不生效。
/// kind 限定 webdav/sftp（服务端强校验按同类源匹配）。
/// 播放装载与预载变体共用同一口径（单测覆盖）。
bool shouldUseTranscode({
  required bool enabled,
  required String apiBaseUrl,
  required MusicSource src,
}) =>
    enabled &&
    apiBaseUrl.isNotEmpty &&
    (src.kind == SourceKind.webdav ||
        src.kind == SourceKind.sftp ||
        src.kind == SourceKind.smb) &&
    src.route == SourceRoute.proxy;

/// 转码变体缓存 key：同一首歌在不同（码率，响度）设置下各存一份。
/// 变体是**预载产物**，只在“没有用户缓存”时存在；用户手动/自动缓存成功后
/// 会清掉该歌变体（缓存优先后不会再被用到）。md5 hex，文件名安全（含 HarmonyOS）。
String transcodeVariantKey(
        String baseCacheKey, int bitrate, String loudnorm) =>
    md5
        .convert(utf8.encode('$baseCacheKey|tc$bitrate-n${loudnorm.toLowerCase()}'))
        .toString();
