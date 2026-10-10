import '../../models/song.dart';
import 'scan_worker.dart';
import 'webdav_url.dart';

/// 源的分类。决定直连协议与可用的增强能力。
enum SourceKind { local, webdav, smb }

/// 非本地源的播放链路偏好（新增/编辑源弹窗可配，默认直连）：
/// - direct：原生 URL 直播，省流转码开关不生效；
/// - proxy：经服务端代理，省流转码开关开时走转码、关时回落直连。
enum SourceRoute { direct, proxy }

/// 解析持久化/同步来的 route 取值；缺失或非法一律回落直连（旧配置兼容）。
SourceRoute parseSourceRoute(Object? v) => SourceRoute.values.firstWhere(
      (e) => e.name == v,
      orElse: () => SourceRoute.direct,
    );

/// 是否参与跨设备源同步：本地文件夹源与设备绑定（各机独立），
/// 远端类型（webdav/smb/onedrive…）默认同步。
bool isSyncableKind(String kind) => kind.isNotEmpty && kind != 'local';

/// 把源地址（可能来自历史配置/服务端快照的原始形态）归一化为同步标准形态：
/// WebDAV 缺 scheme 补 `https://`（与 [webdavNormalizeBase] 一致）、去尾斜杠；
/// 其余类型仅 trim。转码强校验按归一化后的地址匹配，上报也必须归一化。
String normalizeSourceAddress(String kind, String address) {
  switch (kind) {
    case 'webdav':
      return webdavNormalizeBase(address).replaceAll(RegExp(r'/+$'), '');
    default:
      return address.trim();
  }
}

/// 源去重地址（跨设备同步按 kind+地址 识别同一源；名称不参与）：
/// WebDAV=baseUrl（归一化：缺 scheme 补 https、去尾斜杠）；SMB=host/share；
/// 未识别的协议返回空串（不参与去重）。
String sourceAddressOf(String kind, Map<String, dynamic> cfg) {
  switch (kind) {
    case 'webdav':
      return normalizeSourceAddress(
          kind, (cfg['baseUrl'] as String? ?? ''));
    case 'smb':
      final host = (cfg['host'] as String? ?? '').trim();
      final share = (cfg['share'] as String? ?? '').trim();
      if (host.isEmpty) return '';
      return share.isEmpty ? host : '$host/$share';
    default:
      return '';
  }
}

/// 直连源明确拒绝访问（如 WebDAV 401/403 凭据失效）：重试没有意义，
/// 装载链路应快速失败并直接把 [message] 展示给用户（无 Exception 前缀）。
class SourceAuthException implements Exception {
  final String message;
  const SourceAuthException(this.message);

  @override
  String toString() => message;
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

/// 扫描过滤选项（settings.md §3.4）。
///
/// 扫描方式写死「快速：只建索引」：只用枚举拿到的 ref/size/mtime/etag 落库，
/// 不发任何读音频内容的请求（零网络）。原「扫描模式 / 读取音频头部 / 提取内嵌封面」
/// 三个设置项已随之删除——它们让首扫在整库上盲目读头，代价与收益倒挂；元数据
/// 与封面由播放时补读、后台补读按结构定位后精确读取（见 [readAudioMeta]）。
///
/// [minSizeBytes] 仍生效：枚举已经带了大小，不需要读文件。
/// [minDurationSec] 保留但不参与过滤：快速扫描读不到时长，时长过滤等补读出
/// 时长后才具备判据（见设置项文案）。
class ScanOptions {
  final int minSizeBytes;
  final int minDurationSec;
  const ScanOptions({this.minSizeBytes = 0, this.minDurationSec = 0});
}

/// 打开音频流（直接流式传输的统一返回结构）。
class OpenedStream {
  /// 本次响应体的字节数（范围读取时 = 返回区间长度，不等于资源大小）。
  final int contentLength;
  final String contentType;
  final Stream<List<int>> stream;

  /// 资源的**真实总长度**（字节），未知为 null。
  ///
  /// 范围读取时 [contentLength] 只是「这次拿到多少」，无法回答「资源一共多大」，
  /// 于是调用方无法判断自己读到的是不是被截断的片段。本地源直接给文件大小；
  /// WebDAV 从 `Content-Range: bytes 0-8388607/20971520` 的尾部取，服务端不回该
  /// 头时为 null（此时调用方只能按「读到流自然结束」判断）。
  final int? totalLength;

  const OpenedStream({
    required this.contentLength,
    required this.contentType,
    required this.stream,
    this.totalLength,
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

  /// 播放链路偏好（仅非本地源可配；本地源恒直连）。默认直连。
  SourceRoute get route => SourceRoute.direct;

  // ---------- 直连接口（默认不支持） ----------
  bool get supportsDirect => false;

  /// 建本地索引（增量）。默认抛"不支持直连"。
  /// [token] 用于取消（可选），[onProgress] 接收进度（可选，跨 isolate 由 runScan 转发）。
  Future<ScanSummary> scan(
      {ScanOptions options = const ScanOptions(),
      ScanToken? token,
      void Function(ScanProgress)? onProgress}) async =>
      throw UnimplementedError('$key 不支持直连扫描');

  /// 打开音频流（支持 Range）。默认抛"不支持直连"。
  Future<OpenedStream> open(Song song, {IntRange? range}) async =>
      throw UnimplementedError('$key 不支持直连播放');

  /// 若该歌可直接以 URL 播放（原生 Range/seek），返回 URL 与请求头；否则 null。
  DirectStream? directStream(Song song) => null;

  /// 预热：确认该曲可取（连通 / 鉴权 / 可达），不产生任何播放副作用。
  ///
  /// 切歌要新发起一次取流请求，而后台受 Doze / 应用待机限流，冷启动请求容易
  /// 被拖到超时——这正是「切后台后还能播一两首，播完静默停住」的触发点。调用方
  /// 在本曲播放期间先 probe 一次，把连接打通，失败还有时间退避重试
  /// （见 [PlayerProvider] 的下一首预热）。
  ///
  /// 默认实现什么都不做：本地文件等走缓存路径的源无需预热，视作已就绪。
  Future<void> probe(Song song) async {}

  /// 展示用完整路径（歌曲信息弹窗）。默认回落到持久化完整 URL 或源内引用；
  /// 各源实现可覆盖为真实可读路径（本机绝对路径 / 完整 WebDAV URL / UNC…）。
  String displayPath(Song song) => song.sourceUrl ?? song.sourceRef;

  /// 依据本地索引检索歌曲。
  Future<List<Song>> search({String? query, int page = 1, int size = 100}) async =>
      const [];

  /// 若该歌已离线缓存，返回本地文件路径（供断网播缓存，DESIGN §6.5）；否则 null。
  Future<String?> cachedFilePath(Song song) async => null;

  /// 把直连音频下载缓存到本地（断网可播）。
  ///
  /// [shouldAbort] 给「预载下一首」用：换歌后那份预载已经没意义了（预载到的
  /// 不是会播的那首），但串行队列里它还占着连接，整曲几十 MB 的下载能把当前曲
  /// 的元数据/封面拖到几分钟后。实现应按传输块轮询它，返回 true 即放弃
  /// （并清理半截临时文件），抛 [PreloadAbortedException]。
  Future<void> cacheSong(Song song, {bool Function()? shouldAbort}) async =>
      throw UnimplementedError('$key 不支持直连缓存');

  // ---------- 直写管理（阶段6，WebDAV/本地直写；SMB 仍骨架） ----------

  /// 是否支持直写管理（上传/删除/新建文件夹）。默认不支持。
  bool get supportsWrite => false;

  /// 上传单个音频文件到 [parentRef] 目录下（parentRef 为 '' 即源根目录）。
  /// [filename] 不得含 `/` 与 `..`；实现应做穿越校验。
  Future<void> uploadFile(String parentRef, String filename,
          Stream<List<int>> bytes, int length) async =>
      throw UnimplementedError('$key 不支持上传');

  /// 删除一首歌曲对应的远端/本地文件。
  Future<void> deleteSong(Song song) async =>
      throw UnimplementedError('$key 不支持删除');

  /// 在 [parentRef] 下新建文件夹。
  Future<void> createFolder(String parentRef, String name) async =>
      throw UnimplementedError('$key 不支持新建文件夹');

  Future<void> close() async {}
}

/// 预载被放弃（换歌/下一首变了）：不是错误，不提示、不重试。
class PreloadAbortedException implements Exception {
  const PreloadAbortedException();
  @override
  String toString() => '预载已放弃（下一首变了）';
}
