/// 展示用 URL 解码（歌曲信息「路径」等界面展示）。
///
/// WebDAV 地址为百分号编码时直接显示会出现 `%E5%8F%A4` 这类字符；
/// 这里解码为可读文本。仅用于展示——播放/请求仍使用原始 URL。
/// 无 `%` 或解码失败时原样返回（不抛错）。
String decodeUrlForDisplay(String raw) {
  if (!raw.contains('%')) return raw;
  try {
    return Uri.decodeFull(raw);
  } catch (_) {
    return raw;
  }
}
