/// 鸿蒙原生播放器（fvp/libmdk）运行期开关，由应用设置驱动。
///
/// 单独成文件、不 import `package:fvp`，让通用代码（设置/直连源管理器）
/// 改写一个 bool 时无需牵入 libmdk 依赖。
library;

/// 「信任自签名证书」开关（settings.md §3.3）在 mdk 层的镜像。
///
/// 为 true 时 [just_audio_fvp] 会在装载前给播放器设 `avio.tls_verify=0`，
/// 令 FFmpeg/mdk 对 https 自签后端与自签 WebDAV 跳过证书校验（与
/// AppSettings.allowSelfSigned 对 dart:io 的 `badCertificateCallback` 口径一致）。
bool ohosPlayerAllowSelfSigned = false;
