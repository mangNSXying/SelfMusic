import 'dart:async';
import 'dart:typed_data';

import '../../models/song.dart';
import '../../platform/harmonyos/ohos_bootstrap.dart' show isOhos;
import '../../platform/harmonyos/ohos_platform_bridge.dart';
import '../../utils/cover_thumb.dart';
import '../../utils/main_thread_probe.dart';
import '../../utils/perf_log.dart';
import '../../utils/chunked_scheduler.dart' show ChunkYield, yieldToEventLoop;
import '../local/audio_metadata.dart';
import '../local/local_index.dart';
import 'music_source.dart';
import 'sftp_worker.dart';
import 'sibling_cover.dart';

/// 后台元数据补读（播放链路共用）：头部直读 → 按结构定位补读 → 解析 → 回填索引 → 标已读。
///
/// 读序（[readAudioMeta] 统一实现，**绝不整读**）：
/// 1. 先读一小段头部，按魔数识别格式；
/// 2. 顺着文件自己声明的长度跳着补读（mp3 的 ID3v2 总长 / flac 元数据块长 /
///    m4a 的 moov 原子大小），必要时按 4 倍几何放大——大内嵌封面、PICTURE 排在
///    VORBIS_COMMENT 之前的 FLAC 都能拿到，且全程不碰音频数据；
/// 3. 尾部信息（m4a moov-at-end / ogg·opus 时长 / mp3 ID3v1）在尾部阶梯上补全；
/// 4. 仍无封面 → 同目录图片回退（同名图片优先，其次 cover/folder 等）。
///
/// 播放补读与后台补读走的是同一个函数，区别只在外层调度优先级（当前曲 → 下首
/// → 全库），读法上没有分叉。
///
/// 返回是否解析成功：成功才标已读；未识别容器（无法解析）返回 false 且不标已读。
/// 取流失败抛异常，由调用方决定重试策略。
///
/// **ohos 分支（spec/ohos-meta-enrich-native）**：fork 引擎无子 isolate、
/// `runOffThread` 在 ohos 内联，纯 Dart 解析会以秒级同步块独占主线程（真机
/// `THREAD_BLOCK_6S` 强杀根因）。故 ohos 上标签解析/封面提取改由原生
/// `@Concurrent` 任务池的 `AVMetadataExtractor` 完成（[OhosPlatformBridge.extractAudioMeta]），
/// 见 [_enrichViaNative]；非 ohos 与 ohos 原生不可用时仍走 [_enrichViaDart]
/// 的既有纯 Dart 读序（非 ohos 逐字节零回归）。
Future<bool> enrichSongMeta(
    LocalIndex index, MusicSource src, Song song) async {
  perfPhase('meta.enrich'); // TEMP-PROBE
  final sw = Stopwatch()..start(); // TEMP-PROBE
  // ohos：标签解析/封面提取下沉原生任务池（主线程不再跑纯 Dart 解析重活，
  // 见 spec/ohos-meta-enrich-native）。原生不可用/失败时回退既有 Dart 路径。
  if (isOhos && await _enrichViaNative(index, src, song)) {
    _logEnrich(song, sw); // TEMP-PROBE
    return true;
  }
  final ok = await _enrichViaDart(index, src, song);
  _logEnrich(song, sw); // TEMP-PROBE
  return ok;
}

/// ohos 原生解析分支（spec/ohos-meta-enrich-native plan.md R-1/R-3）：
/// 1. 取沙箱真路径（本地源经 `resolvePath` 解析；远端源未缓存返回 null → 不适用）；
/// 2. 计算封面目标路径（沿用 [LocalIndex.persistCover] 口径 `covers/<md5(ref)>.jpg`）
///    并调 `extractAudioMeta`（原生写 tmp + rename 原子落盘）；
/// 3. 成功才回填 + 标已读（`enrichSong` 内含 `meta_read=1`）。
///
/// 返回 false 表示「原生不适用或解析失败」——由 [enrichSongMeta] 回退既有 Dart
/// 路径（保字段覆盖与补读收敛，绝不劣化）。任何失败都不在此标已读（重试语义）。
Future<bool> _enrichViaNative(LocalIndex index, MusicSource src, Song song) async {
  // R-2：以「是否存在可打开的本地沙箱真路径」判定原生可用性——本地源本体即本地
  // 文件（无需离线缓存登记），远端源需已缓存。不得因 `cachedFilePath == null`
  // 对本地源误判为不可用而错失原生解析（主线程长同步块治理 FR-004）。
  final path = await src.localSandboxPath(song);
  if (path == null || path.isEmpty) return false; // 无本地真路径：远端未缓存等
  final coverTarget = index.coverPathFor(song.sourceRef);
  final res = await OhosPlatformBridge.extractAudioMeta(path, coverPath: coverTarget);
  if (!res.ok) return false; // 原生解析失败/机制不可用 → 回退 Dart（不标已读）
  var cover = res.coverPathOrNull;
  if (cover == null) {
    // 原生无内嵌封面：沿用同目录图片回退（不劣化封面覆盖）。
    final sibling = await fetchSiblingImage(src, song);
    if (sibling != null && sibling.isNotEmpty) {
      cover = index.persistCover(sibling, song.sourceRef);
    }
  }
  if (cover != null) {
    // 列表用缩略图落盘与补读解耦：补读不等缩略图，避免拖慢「标已读」。
    unawaited(ensureCoverThumb(cover));
  }
  await index.enrichSong(song.sourceKey, song.sourceRef,
      title: res.titleOrNull,
      artist: res.artistOrNull,
      album: res.albumOrNull,
      albumArtist: res.albumArtistOrNull,
      duration: res.durationSec,
      genre: res.genreOrNull,
      trackNo: res.trackNoOrNull,
      year: res.yearOrNull,
      coverPath: cover);
  // 内嵌歌词：原生 AVMetadata 当前不提供（[res.lyric] 恒空），仅在非空时按既有
  // 口径写入，避免覆盖同名 .lrc/用户内容；不写即保持既有记录不变（不劣化）。
  final lyrics = res.lyricOrNull;
  if (lyrics != null) {
    final existing = index.lyricsOf(song.sourceKey, song.sourceRef);
    if (existing == null || existing.isEmpty) {
      await index.setLyrics(song.sourceKey, song.sourceRef, lyrics);
    }
  }
  return true;
}

/// 既有纯 Dart 解析路径（非 ohos 走此路径；ohos 在原生不适用/失败时回退到它）：
/// 头部直读 → 按结构定位补读 → 解析 → 回填索引 → 标已读。行为与非 ohos 逐字节一致。
///
/// **主线程切片让出（R-1 / FR-001）**：ohos 上主线程即 Dart 根 isolate，远程源无
/// 本地缓存时无法走原生解析，此路径的纯 Dart 重活（标签区解析、内嵌封面处理、
/// 封面落盘/哈希、落库）以 `await` 让出事件循环、片间互不叠加——单次同步块
/// 目标 < 50ms（真机探针曾观测 `meta.enrich` 单次最长 6.1s）。让出点：
/// - [readAudioMeta] 传 [ChunkYield]，阶段/阶梯轮次之间让出；解析内部把大内嵌
///   封面从解析热路径挪出去（零拷贝视图 + base64 分片解码）；
/// - 封面落盘改走 [LocalIndex.persistCoverChunked]（哈希/写盘分片让出）。
Future<bool> _enrichViaDart(LocalIndex index, MusicSource src, Song song) async {
  perfPhase('meta.dart.read'); // TEMP-PROBE
  final meta = await readAudioMeta(
    readRange: (start, length) => _readRange(src, song, start, length),
    format: song.format ?? '',
    fileSize: song.fileSize,
    yieldTo: yieldToEventLoop,
  );
  if (meta == null) {
    return false; // 未识别容器：不标已读，留待后续重试
  }
  await yieldToEventLoop();
  var cover = meta.cover;
  if (cover == null || cover.isEmpty) {
    perfPhase('meta.dart.sibling'); // TEMP-PROBE
    cover = await fetchSiblingImage(src, song);
  }
  String? coverPath;
  if (cover != null && cover.isNotEmpty) {
    await yieldToEventLoop();
    perfPhase('meta.dart.persistCover'); // TEMP-PROBE
    // 哈希与写盘分片让出：大内嵌封面（可达 16MB 元数据区上限）不整块同步落盘。
    coverPath = await index.persistCoverChunked(cover, song.sourceRef,
        yieldTo: yieldToEventLoop);
    // 列表用缩略图落盘与补读解耦：补读不等缩略图，避免拖慢「标已读」。
    if (coverPath != null) unawaited(ensureCoverThumb(coverPath));
  }
  await yieldToEventLoop();
  perfPhase('meta.dart.dbWrite'); // TEMP-PROBE
  await index.enrichSong(song.sourceKey, song.sourceRef,
      title: meta.title,
      artist: meta.artist,
      album: meta.album,
      albumArtist: meta.albumArtist,
      duration: meta.duration,
      genre: meta.genre,
      trackNo: meta.trackNo,
      year: meta.year,
      coverPath: coverPath);
  // 内嵌歌词：仅在尚无歌词记录（或仅有「无歌词」标记）时写入，避免覆盖同名 .lrc/用户内容。
  final lyrics = meta.lyrics?.trim();
  if (lyrics != null && lyrics.isNotEmpty) {
    await yieldToEventLoop();
    perfPhase('meta.dart.lyrics'); // TEMP-PROBE
    final existing = index.lyricsOf(song.sourceKey, song.sourceRef);
    if (existing == null || existing.isEmpty) {
      await index.setLyrics(song.sourceKey, song.sourceRef, lyrics);
    }
  }
  return true;
}

// TEMP-PROBE：单曲补读耗时（>=50ms 才打印，含文件大小）。
void _logEnrich(Song song, Stopwatch sw) {
  final ms = sw.elapsedMilliseconds;
  if (ms >= 50) {
    perfLog('meta.enrich',
        '${ms}ms size=${song.fileSize} ${song.sourceKey}/${song.sourceRef}');
  }
}

/// 打开 [start, start+length) 范围并读满；**读不满即抛异常**（问题1修复）。
///
/// 旧实现“流长度不足时返回实际全部”：流提前断开（断流/半关闭）无异常时，
/// 短 buf 会被当完整用 → 半图通过头校验落盘 + `enrichSong` 标已读，永不重试。
/// 现按期望长度校验：
/// - `song.fileSize > 0` 已知时，期望 `min(length, fileSize-start)`；
/// - 未知时若 `opened.totalLength` 已知，按它算期望；
/// - 都未知时无法校验（如部分源的探测请求），直接返回（下游靠
///   [isCompleteImageBytes] 尾判拦截半图）。
/// 抛异常后调用方（`_enrichViaDart` → `_enrichLazily`/后台补读）按“读失败”处理：
/// 不标已读，下次播放/补读重试。
///
/// **旧直连 SFTP 让出节拍**：仅当 worker isolate 未启用时，dartssh2 的纯 Dart
/// AEAD 解密仍运行在 UI isolate，整段下载会把主线程连续占满（直连传输已限
/// 「单请求在飞 + 16KB 块」，这里再补「读一块歇一块」的节拍），给渲染/输入留
/// 事件循环窗口——否则后台补读期间界面持续掉帧（真机 2026-10-11 取证）。
/// worker 路径解密已移出 UI isolate，不再需要节拍；WebDAV/本地也不占主线程。
Future<Uint8List> _readRange(
    MusicSource src, Song song, int start, int length) async {
  perfPhase('meta.readRange.$start+$length'); // TEMP-PROBE
  final buf = BytesBuilder(copy: false);
  final opened = await src.open(song, range: IntRange(start, length));
  final pace = !SftpWorker.enabled && src.kind == SourceKind.sftp;
  await for (final chunk in opened.stream) {
    buf.add(chunk);
    if (buf.length >= length) break;
    if (pace && buf.length >= _paceFirstBytes) {
      await Future<void>.delayed(_paceSleep);
    }
  }
  final got = buf.length;
  // 期望长度：文件尾截断请求时按剩余算（如 start+length 越过 EOF）。
  int? expected;
  final fs = song.fileSize;
  if (fs > 0 && start < fs) {
    final remaining = fs - start;
    expected = remaining < length ? remaining : length;
  } else if (fs <= 0) {
    final total = opened.totalLength;
    if (total != null && total > start) {
      final remaining = total - start;
      expected = remaining < length ? remaining : length;
    }
  }
  if (expected != null && got < expected) {
    throw StateError(
        'range 读取截断 ${song.sourceKey}/${song.sourceRef} [$start,${start + length}) 期望 $expected 实际 $got（断流，不标已读待重试）');
  }
  return buf.takeBytes();
}

/// 补读节拍：首块不必让（保证标签/封面快出），之后每 16KB 解密块间隔 8ms。
const int _paceFirstBytes = 32 * 1024;
const Duration _paceSleep = Duration(milliseconds: 8);
