import '../../models/song.dart';
import 'scan_worker.dart';

/// 源的分类。决定直连协议与可用的增强能力。
enum SourceKind { local, webdav, smb }

/// 是否参与跨设备源同步：本地文件夹源与设备绑定（各机独立），
/// 远端类型（webdav/smb/onedrive…）默认同步。
bool isSyncableKind(String kind) => kind.isNotEmpty && kind != 'local';

/// 源去重地址（跨设备同步按 kind+地址 识别同一源；名称不参与）：
/// WebDAV=baseUrl；SMB=host/share；未识别的协议返回空串（不参与去重）。
String sourceAddressOf(String kind, Map<String, dynamic> cfg) {
  switch (kind) {
    case 'webdav':
      return (cfg['baseUrl'] as String? ?? '')
          .trim()
          .replaceAll(RegExp(r'/+$'), '');
    case 'smb':
      final host = (cfg['host'] as String? ?? '').trim();
      final share = (cfg['share'] as String? ?? '').trim();
      if (host.isEmpty) return '';
      return share.isEmpty ? host : '$host/$share';
    default:
      return '';
  }
}

/// 字节范围请求（含起止），用于 Range 起播 / seek。
class IntRange {
  final int start;
  final int? length;
  const IntRange(this.start, [this.length]);

  /// 闭区间 end（含），与 just_audio StreamAudioResponse 语义一致。
  int? get end => length == null ? null : start + length! - 1;
}

/// 一次扫描的汇总（DESIGN §6.4）。
class ScanSummary {
  final int added;
  final int updated;
  final int unchanged;
  final int total;

  /// 用户是否中途取消了本次扫描（取消后仍返回已处理部分）。
  final bool cancelled;
  const ScanSummary({
    required this.added,
    required this.updated,
    this.unchanged = 0,
    required this.total,
    this.cancelled = false,
  });
}

/// 扫描过滤与速度选项（settings.md §3.4）。
///
/// - 只读必要参数：非 [fullMeta] 时仅解析 标题/歌手/专辑，时长/曲目/年份/流派/封面
///   留待播放时 `enrich`（下载量与解析量最小化）。
/// - [fast] 仅用文件名建索引，不发任何读头请求（零网络）。
/// - [headBytes] 头部采样上限（默认 64KB，替代旧的固定 256KB）。
/// - [collectCover] 仅 fullMeta 且 true 时提取并落盘封面。
class ScanOptions {
  final int minSizeBytes;
  final int minDurationSec;
  final int headBytes;
  final bool fullMeta;
  final bool fast;
  final bool collectCover;
  const ScanOptions({
    this.minSizeBytes = 0,
    this.minDurationSec = 0,
    this.headBytes = 64 * 1024,
    this.fullMeta = false,
    this.fast = false,
    this.collectCover = false,
  });
  const ScanOptions.none()
      : minSizeBytes = 0,
        minDurationSec = 0,
        headBytes = 64 * 1024,
        fullMeta = false,
        fast = false,
        collectCover = false;
}

/// 打开音频流（直接流式传输的统一返回结构）。
class OpenedStream {
  final int contentLength;
  final String contentType;
  final Stream<List<int>> stream;
  const OpenedStream({
    required this.contentLength,
    required this.contentType,
    required this.stream,
  });
}

/// 直连源可直接交给播放器的 URL（原生 HTTP Range / seek），
/// 比自建 [StreamAudioSource] 更可靠；不可用时返回 null 走 [MusicSource.open]。
class DirectStream {
  final String url;
  final Map<String, String>? headers;
  const DirectStream(this.url, {this.headers});
}

/// Source 抽象（DESIGN §6.2）。播放器只认 [MusicSource]。
///
/// 实现 `supportsDirect` 并实现 `scan`/`open`，由 PlayerProvider 包装成
/// `StreamAudioSource` 喂给 just_audio（支持 Range seek / 断点）。
abstract class MusicSource {
  /// 稳定标识（DESIGN §6.2 key）：`webdav:<name>` / `smb:<name>` / `local:<name>`。
  String get key;

  /// 友好显示名（如源名称「NAS」）。
  String get name;

  SourceKind get kind;

  // ---------- 直连接口（默认不支持） ----------
  bool get supportsDirect => false;

  /// 建本地索引（增量）。默认抛"不支持直连"。
  /// [token] 用于取消（可选），[onProgress] 接收进度（可选，跨 isolate 由 runScan 转发）。
  Future<ScanSummary> scan(
      {ScanOptions options = const ScanOptions.none(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async =>
      throw UnimplementedError('$key 不支持直连扫描');

  /// 打开音频流（支持 Range）。默认抛"不支持直连"。
  Future<OpenedStream> open(Song song, {IntRange? range}) async =>
      throw UnimplementedError('$key 不支持直连播放');

  /// 若该歌可直接以 URL 播放（原生 Range/seek），返回 URL 与请求头；否则 null。
  DirectStream? directStream(Song song) => null;

  /// 依据本地索引检索歌曲。
  Future<List<Song>> search({String? query, int page = 1, int size = 100}) async =>
      const [];

  /// 若该歌已离线缓存，返回本地文件路径（供断网播缓存，DESIGN §6.5）；否则 null。
  Future<String?> cachedFilePath(Song song) async => null;

  /// 把直连音频下载缓存到本地（断网可播）。
  Future<void> cacheSong(Song song) async =>
      throw UnimplementedError('$key 不支持直连缓存');

  Future<void> close() async {}
}
