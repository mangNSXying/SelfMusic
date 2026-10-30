import '../../models/song.dart';
import 'scan_worker.dart';
import 'webdav_url.dart';

/// 源的分类。决定直连协议与可用的增强能力。
enum SourceKind { local, webdav, smb, sftp }

/// 非本地源的播放链路偏好（新增/编辑源弹窗可配，默认直连）：
/// - direct：原生 URL 直播，代理设置（转码/响度）不生效；
/// - proxy：经服务端代理，代理总开关开时走转码（响度均衡同时生效）、关时回落直连。
enum SourceRoute { direct, proxy }

/// 缓存条目类型（`cache.kind`）：区分用户缓存与预载产物。
///
/// - [user]：手动缓存 / 收藏自动缓存，算“已缓存”，播放时无条件优先；
/// - [preloadOrigin]：转码关闭时预载的原文件，不算“已缓存”，只在直连设置下
///   作为本地副本使用，或转码失败时兜底；
/// - [preloadVariant]：转码预载产物，与码率/响度设置绑定，仅在转码链路使用；
/// - [legacy]：迁移前无法归属到歌曲的旧行（历史变体），淘汰时按最弱处理。
enum CacheEntryKind {
  user('user'),
  preloadOrigin('preload_origin'),
  preloadVariant('preload_variant'),
  legacy('legacy');

  const CacheEntryKind(this.dbValue);

  final String dbValue;

  static CacheEntryKind parse(Object? v) => CacheEntryKind.values.firstWhere(
        (e) => e.dbValue == v,
        orElse: () => CacheEntryKind.legacy,
      );
}

/// 解析持久化/同步来的 route 取值；缺失或非法一律回落直连（旧配置兼容）。
SourceRoute parseSourceRoute(Object? v) => SourceRoute.values.firstWhere(
      (e) => e.name == v,
      orElse: () => SourceRoute.direct,
    );

/// 是否参与跨设备源同步：本地文件夹源与设备绑定（各机独立），
/// 远端类型（webdav/smb/onedrive…）默认同步。
bool isSyncableKind(String kind) => kind.isNotEmpty && kind != 'local';

/// 元数据 sidecar 文件名判定（在线元数据写回用）：歌词 `.lrc`（大小写）
/// 与常见封面图后缀。纯函数，可单测。
bool isSidecarFileName(String name) {
  final i = name.lastIndexOf('.');
  if (i < 0 || i == name.length - 1) return false;
  final ext = name.substring(i + 1).toLowerCase();
  return ext == 'lrc' ||
      ext == 'jpg' ||
      ext == 'jpeg' ||
      ext == 'png' ||
      ext == 'webp';
}
/// 备用源上限：每个逻辑源至多 2 个备用（主 + 备1 + 备2）。
const int kMaxFallbacks = 2;

/// 备用源在 SecretStore 中的槽位后缀（`#fb0` / `#fb1`）。
String fallbackSlotSuffix(int slot) => '#fb$slot';

/// 手动线路选择：auto=自动 Failover，primary=只走主用，fb0/fb1=锁定某备用。
enum SourceLine { auto, primary, fb0, fb1 }

/// 解析持久化的线路偏好；非法回落 auto。
SourceLine parseSourceLine(Object? v) => SourceLine.values.firstWhere(
      (e) => e.name == v,
      orElse: () => SourceLine.auto,
    );

/// 备用源展示标签（`备用1` / `备用2`）。
String fallbackLabel(int slot) => '备用${slot + 1}';

/// 备用源配置键归一化：与主配置同形（kind/host/port/share/baseUrl/path/
/// username/route/authMethod），不含 name/password/keyPem/passphrase 明文。
Map<String, dynamic> sanitizeFallbackConfig(Map<String, dynamic> fb) {
  final m = Map<String, dynamic>.of(fb)
    ..remove('password')
    ..remove('keyPem')
    ..remove('passphrase')
    ..remove('smbPassword')
    ..remove('sftpPassword')
    ..remove('sftpKeyPem')
    ..remove('sftpPassphrase')
    ..remove('name')
    ..remove('key');
  return m;
}

/// 从源 config JSON 中解析备用列表（容错：非 List/超限截断/非法项丢弃）。
List<Map<String, dynamic>> parseFallbackConfigs(Object? v) {
  if (v is! List) return const [];
  final out = <Map<String, dynamic>>[];
  for (final e in v) {
    if (e is! Map) continue;
    final m = Map<String, dynamic>.of(
        e.map((k, vv) => MapEntry(k.toString(), vv)));
    final kind = (m['kind'] as String? ?? '').trim();
    if (kind.isEmpty || kind == 'local') continue;
    out.add(m);
    if (out.length >= kMaxFallbacks) break;
  }
  return out;
}

/// 备用地址指纹（去重/判重用；与 [sourceAddressOf] 同口径，kind 取备用自身 kind）。
String fallbackAddressOf(Map<String, dynamic> fb) {
  final kind = (fb['kind'] as String? ?? '').trim();
  return sourceAddressOf(kind, fb);
}

/// 把源地址（可能来自历史配置/服务端快照的原始形态）归一化为同步标准形态：
/// WebDAV 缺 scheme 补 `https://`（与 [webdavNormalizeBase] 一致）、去尾斜杠；
/// SFTP 形态见 [normalizeSftpAddress]；其余类型仅 trim。
/// 转码强校验按归一化后的地址匹配，上报也必须归一化。
String normalizeSourceAddress(String kind, String address) {
  switch (kind) {
    case 'webdav':
      return webdavNormalizeBase(address).replaceAll(RegExp(r'/+$'), '');
    case 'sftp':
      return normalizeSftpAddress(address);
    default:
      return address.trim();
  }
}

/// SFTP 去重地址形态 `host:port/path`：port 缺省 22 并显式化、host 小写、
/// 去尾斜杠；host 为空返回空串（不参与去重）。可接受 `sftp://` 前缀与
/// `[IPv6]` 形态；非法端口回落默认 22。
String normalizeSftpAddress(String address) {
  var s = address.trim();
  if (s.isEmpty) return '';
  if (s.toLowerCase().startsWith('sftp://')) s = s.substring('sftp://'.length);
  var hostPort = s;
  var path = '';
  final slash = s.indexOf('/');
  if (slash >= 0) {
    hostPort = s.substring(0, slash);
    path = s.substring(slash);
  }
  var host = hostPort;
  var port = 22;
  if (hostPort.startsWith('[')) {
    final end = hostPort.indexOf(']');
    if (end > 0) {
      host = hostPort.substring(1, end);
      final rest = hostPort.substring(end + 1);
      if (rest.startsWith(':') && rest.length > 1) {
        port = int.tryParse(rest.substring(1)) ?? 22;
        if (port < 1 || port > 65535) port = 22;
      }
    }
  } else {
    final colon = hostPort.lastIndexOf(':');
    if (colon >= 0) {
      final tail = hostPort.substring(colon + 1);
      if (tail.isEmpty) {
        host = hostPort.substring(0, colon);
      } else {
        final p = int.tryParse(tail);
        if (p != null && p >= 1 && p <= 65535) {
          host = hostPort.substring(0, colon);
          port = p;
        } else {
          host = hostPort.substring(0, colon);
        }
      }
    }
  }
  host = host.toLowerCase();
  path = path.replaceAll(RegExp(r'/+$'), '');
  if (host.isEmpty) return '';
  return '$host:$port$path';
}

/// 源去重地址（跨设备同步按 kind+地址 识别同一源；名称不参与）：
/// WebDAV=baseUrl（归一化：缺 scheme 补 https、去尾斜杠）；SMB=host/share；
/// SFTP=`host:port/path`（见 [normalizeSftpAddress]）；
/// 未识别的协议返回空串（不参与去重）。
String sourceAddressOf(String kind, Map<String, dynamic> cfg) {
  switch (kind) {
    case 'webdav':
      return normalizeSourceAddress(
          kind, (cfg['baseUrl'] as String? ?? ''));
    case 'sftp':
      return normalizeSftpAddress(
          '${cfg['host'] ?? ''}:${cfg['port'] ?? ''}${cfg['path'] ?? ''}');
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

/// 一次扫描的汇总（DEVELOPER.md「客户端扫描与元数据」）。
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

/// Source 抽象（DEVELOPER.md「客户端播放源」）。播放器只认 [MusicSource]。
///
/// 实现 `supportsDirect` 并实现 `scan`/`open`，由 PlayerProvider 包装成
/// `StreamAudioSource` 喂给 just_audio（支持 Range seek / 断点）。
/// 支持把原始字节流交给 MediaProxy（独立 isolate 回环 HTTP）的源。
/// 由 SMB/SFTP 实现；播放层据此判断是否需要启动代理。
abstract class MediaProxySource {
  Map<String, Object?>? mediaProxyConfigFor(Song song);
}

abstract class MusicSource {
  /// 稳定标识（DEVELOPER.md「客户端播放源」 key）：`webdav:<name>` / `smb:<name>` / `local:<name>`。
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

  /// 代理转码 origin（无 userinfo；凭据走 [proxyAuthHeaders]）。
  /// WebDAV 返回可请求的 https URL；SFTP 返回 `sftp://host:port/…`；
  /// SMB 返回 `smb://host/share/…`；其余返回 null（不走代理）。
  String? proxyOrigin(Song song) => null;

  /// 代理鉴权头：WebDAV 为 `X-Origin-Auth: Basic …`，SFTP 为 `X-Origin-Ssh`
  /// 信封，SMB 为 `X-Origin-Smb` 信封；默认空（不走代理的源）。
  Future<Map<String, String>> proxyAuthHeaders(Song song) async => const {};

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

  /// 若该歌已有本地原文件（用户缓存或预载原文件），返回路径；否则 null。
  Future<String?> cachedFilePath(Song song) async => null;

  /// 用户缓存（[CacheEntryKind.user]）路径：播放的“缓存优先”只认它。
  /// 默认与 [cachedFilePath] 同义（本地源文件即本体）；远端源覆盖为按 kind 查询。
  Future<String?> userCachedFilePath(Song song) => cachedFilePath(song);

  /// 可交给原生解析（ohos `extractAudioMeta`）的**本地沙箱真路径**；无则 null。
  ///
  /// 与 [cachedFilePath] 的**离线缓存**语义区分（FR-004 / R-2）：本地源本体即
  /// 本地文件，只要存在可打开的沙箱真路径就应走原生解析，**不得**因为没有「离线
  /// 缓存」登记而被误判为不可用；远端源则返回已缓存文件路径（未缓存 = null，走
  /// Dart 切片兜底）。默认委托 [cachedFilePath]，各源可按需覆盖。
  Future<String?> localSandboxPath(Song song) => cachedFilePath(song);

  /// 把直连音频下载缓存到本地（断网可播）。
  ///
  /// [shouldAbort] 给「预载下一首」用：换歌后那份预载已经没意义了（预载到的
  /// 不是会播的那首），但串行队列里它还占着连接，整曲几十 MB 的下载能把当前曲
  /// 的元数据/封面拖到几分钟后。实现应按传输块轮询它，返回 true 即放弃
  /// （并清理半截临时文件），抛 [PreloadAbortedException]。
  /// [kind] 区分用户缓存与预载产物；源实现需随行写入 cache 表。
  Future<void> cacheSong(Song song,
          {bool Function()? shouldAbort,
          CacheEntryKind kind = CacheEntryKind.user}) async =>
      throw UnimplementedError('$key 不支持直连缓存');

  // ---------- 直写管理（阶段6 起 WebDAV/本地直写；SFTP/SMB 已看齐） ----------

  /// 是否支持直写管理（上传/删除/新建文件夹）。默认不支持。
  bool get supportsWrite => false;

  /// 上传单个音频文件到 [parentRef] 目录下（parentRef 为 '' 即源根目录）。
  /// [filename] 不得含 `/` 与 `..`；实现应做穿越校验。
  ///
  /// 音频后缀之外的 sidecar（歌词/封面）走 [uploadSidecar]，不走本方法。
  Future<void> uploadFile(String parentRef, String filename,
          Stream<List<int>> bytes, int length) async =>
      throw UnimplementedError('$key 不支持上传');

  /// 上传元数据 sidecar（歌词 `.lrc` / 封面图）到 [parentRef] 目录下。
  ///
  /// 语义与 [uploadFile] 相同（同名覆盖），但文件名必须是
  /// [isSidecarFileName] 判定的 sidecar 后缀。默认转调 [uploadFile]，
  /// 各源可按需覆盖（如上传口有音频后缀限制）。
  Future<void> uploadSidecar(String parentRef, String filename,
          Stream<List<int>> bytes, int length) async =>
      uploadFile(parentRef, filename, bytes, length);

  /// 删除一首歌曲对应的远端/本地文件。
  Future<void> deleteSong(Song song) async =>
      throw UnimplementedError('$key 不支持删除');

  /// 删除 [parentRef] 目录下的 sidecar 文件（嵌入后清理用）。
  ///
  /// 不存在按幂等成功计（嵌入时源目录可能本就没有该文件）。
  /// 默认不支持，各源覆盖。
  Future<void> deleteSidecar(String parentRef, String filename) async =>
      throw UnimplementedError('$key 不支持删除 sidecar');

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
