/// mdk（fvp/libmdk）HTTP 层纯函数工具：不 import `package:fvp`，可独立单测。
library;

/// 把平台层请求头 map 拼成 mdk `avio.headers` 需要的字符串：
/// 每行 `Key: Value` 以 CRLF 分隔（FFmpeg 自行补行尾 CRLF 亦可）。
/// 空/缺省返回空串——用于清除上一曲残留的自定义头。
String buildAvioHeaders(Map<String, String>? headers) {
  if (headers == null || headers.isEmpty) return '';
  return headers.entries.map((e) => '${e.key}: ${e.value}').join('\r\n');
}
