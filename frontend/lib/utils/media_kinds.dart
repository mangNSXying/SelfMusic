/// 音频文件判定与容器元信息（全应用唯一入口）。
library;

/// 支持的音频后缀集合（扫描 / 上传 / UI 过滤共用）。
final RegExp _audioExtPattern = RegExp(
    r'\.(mp3|flac|m4a|aac|ogg|wav|aif|aiff|aifc)$',
    caseSensitive: false);

/// 路径/文件名是否为受支持的音频文件（后缀不区分大小写）。
bool isAudioFileName(String path) => _audioExtPattern.hasMatch(path);

/// 取小写扩展名（无扩展名返回空串）。
String audioExtOf(String path) {
  final i = path.lastIndexOf('.');
  return i >= 0 ? path.substring(i + 1).toLowerCase() : '';
}

/// 扩展名 → MIME（未知容器按 mp3 处理，与历史行为一致）。
String audioMimeOf(String ext) {
  switch (ext) {
    case 'flac':
      return 'audio/flac';
    case 'm4a':
    case 'aac':
      return 'audio/mp4';
    case 'ogg':
      return 'audio/ogg';
    case 'wav':
      return 'audio/wav';
    case 'aif':
    case 'aiff':
    case 'aifc':
      return 'audio/aiff';
    default:
      return 'audio/mpeg';
  }
}
