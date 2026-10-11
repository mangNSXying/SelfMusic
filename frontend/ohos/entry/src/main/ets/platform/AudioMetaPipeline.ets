/**
 * 音频元数据原生解析纯管线（ohos-meta-enrich-native feature，plan.md R-1 / T003）。
 *
 * **无 UI 依赖硬约束**：本模块**仅** import `@kit.MediaKit`（`AVMetadataExtractor`）、
 * `@kit.ImageKit`（封面 PixelMap 打包落盘）、`@kit.CoreFileKit`（文件 fd）、
 * `@kit.PerformanceAnalysisKit`（hilog）。**禁止** import `@kit.ArkUI`（window）/
 * `@kit.AbilityKit`（common）或任何含 UI 装饰器（@Observed/AppStorage 等）的模块——
 * 子线程解析到 UI 装饰器会抛异常并中断模块解析（`xxx is not initialized` 甚至 crash）。
 * 故并发函数不能放在 `PlatformBridge.ets`（该文件引入了 window/UIAbilityContext）。
 *
 * **为何独立于 AudioMetaTask.ets（编译约束）**：`@Concurrent` 并发函数体内**只能**
 * 引用入参、局部变量与 **import 的变量**；引用同文件其它顶层函数会被判定为
 * 闭包/作用域引用而编译报错（`Concurrent function should only use import variable
 * or local variable`）。故把纯管线函数抽到本文件，由 `AudioMetaTask.ets` 的
 * `@Concurrent` 函数 import 调用（官方 TaskPool FAQ「自定义函数需定义在单独文件并
 * import」）。
 *
 * **跨线程边界**：入参只传可序列化纯数据（path/coverPath），返回只传结果对象
 * （见 [AudioMetaResult]）。AVMetadataExtractor / image.PixelMap / ImagePacker /
 * fileIo.File 等句柄一律在本模块内创建与释放，绝不跨线程。
 *
 * **API 依据（`devecocli docs` 核实，API 26）**：
 * - `media.createAVMetadataExtractor(): Promise<AVMetadataExtractor>`；
 * - `extractor.fdSrc = AVFileDescriptor { fd, offset?, length? }`（沙箱真路径 openSync
 *   取 fd，**无需 AbilityContext**；offset/length 缺省即整文件）；
 * - `extractor.fetchMetadata(): Promise<AVMetadata>`（title/artist/album/albumArtist/
 *   genre/duration(字符串)/dateTime 等，均 string 可选）；
 * - `extractor.fetchAlbumCover(): Promise<image.PixelMap>`；
 * - `extractor.release(): Promise<void>`。
 *
 * **失败语义**：任何失败（文件不可读/不支持的容器/取元数据异常）返回 `ok=false`，
 * 绝不抛出；调用方（Dart）据此**不标已读**（既有重试语义）。封面缺失（无内嵌封面）
 * 不是失败：标签照常返回、`coverPath=''`，同目录图片回退由 Dart 侧负责。
 */
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SelfMusicAudioMeta';
/** hilog 业务域。 */
const DOMAIN = 0x0000;

/**
 * 封面重编码质量：`fetchAlbumCover` 只回 PixelMap，需重编码落盘；取 100 尽量
 * 保留原图信息（列表用的降采样缩略图另由 `ThumbPipeline` 负责）。
 */
const COVER_JPEG_QUALITY = 100;

/**
 * 原生解析结果（跨线程传回的可序列化纯数据）：字符串缺省用 `''`、数值缺省用 `0`
 * （避免可选属性跨线程序列化的歧义，由 Dart 侧归一为 null/缺失）。
 */
export interface AudioMetaResult {
  /** 是否解析成功（true 才允许调用方标已读）。 */
  ok: boolean;
  /** 标题（''=缺失）。 */
  title: string;
  /** 歌手（''=缺失）。 */
  artist: string;
  /** 专辑（''=缺失）。 */
  album: string;
  /** 专辑歌手（''=缺失）。 */
  albumArtist: string;
  /** 时长（毫秒；0=未知）。 */
  durationMs: number;
  /** 流派（''=缺失）。 */
  genre: string;
  /** 音轨号（0=未知；AVMetadata 当前不提供该字段，恒为 0）。 */
  trackNo: number;
  /** 年份（0=未知；由 dateTime 前导 4 位数字解析）。 */
  year: number;
  /** 封面落盘路径（''=无内嵌封面或落盘失败）。 */
  coverPath: string;
  /** 内嵌歌词（AVMetadata 当前不提供，恒为 ''，字段预留）。 */
  lyric: string;
  /** 本首解析耗时（ms，含元数据 + 封面落盘）。 */
  costMs: number;
  /** 失败原因摘要（''=无）。 */
  error: string;
}

/** 构造全缺省结果（成功字段由管线逐步填充）。 */
function emptyResult(): AudioMetaResult {
  const out: AudioMetaResult = {
    ok: false,
    title: '',
    artist: '',
    album: '',
    albumArtist: '',
    durationMs: 0,
    genre: '',
    trackNo: 0,
    year: 0,
    coverPath: '',
    lyric: '',
    costMs: 0,
    error: ''
  };
  return out;
}

/** 字符串数值 → number（非有限值归 0）。`AVMetadata.duration`/`sampleRate` 均为字符串。 */
function numOf(v: string): number {
  const n: number = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** 从任意时间文本取前导 4 位连续数字为年份（`2021`/`2021-05-01 ...`），取不到归 0。 */
function firstYear(s: string): number {
  let run = 0;
  let start = -1;
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c >= 48 && c <= 57) {
      if (start < 0) {
        start = i;
      }
      run++;
      if (run === 4) {
        const y: number = Number.parseInt(s.substring(start, start + 4), 10);
        return Number.isFinite(y) ? y : 0;
      }
    } else {
      run = 0;
      start = -1;
    }
  }
  return 0;
}

/**
 * 音频元数据原生解析纯管线（可被并发函数复用）：open fd → `AVMetadataExtractor`
 * （fdSrc）→ `fetchMetadata()` → 映射字段 → 有封面则 `fetchAlbumCover()` →
 * JPEG 重编码写 `<coverPath>.tmp` → rename 原子落盘。句柄在本函数内创建与释放；
 * `finally` 保证 `.tmp` 清理与资源回收。任何失败返回 `ok=false`（不抛出）。
 */
export async function runAudioMetaPipeline(path: string,
  coverPath: string): Promise<AudioMetaResult> {
  const startTs: number = Date.now();
  const out: AudioMetaResult = emptyResult();
  let file: fileIo.File | null = null;
  let extractor: media.AVMetadataExtractor | null = null;
  let cover: image.PixelMap | null = null;
  let packer: image.ImagePacker | null = null;
  let tmpFile: fileIo.File | null = null;
  const hasCoverTarget: boolean = coverPath !== '';
  const tmpPath: string = hasCoverTarget ? `${coverPath}.tmp` : '';
  let coverRenamed = false;
  try {
    file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const size: number = fileIo.statSync(file.fd).size;
    extractor = await media.createAVMetadataExtractor();
    const fdSrc: media.AVFileDescriptor = {
      fd: file.fd,
      offset: 0,
      length: size
    };
    extractor.fdSrc = fdSrc;
    const meta: media.AVMetadata = await extractor.fetchMetadata();
    out.title = meta.title ?? '';
    out.artist = meta.artist ?? '';
    out.album = meta.album ?? '';
    out.albumArtist = meta.albumArtist ?? '';
    out.genre = meta.genre ?? '';
    out.durationMs = numOf(meta.duration ?? '');
    out.year = firstYear(meta.dateTime ?? meta.dateTimeFormat ?? '');
    // 音轨号 / 内嵌歌词 AVMetadata 当前不提供（见 spec「Open Questions」与残留风险）：
    // 留空不写回，靠既有 COALESCE 语义保持库中已有值，不劣化。
    if (hasCoverTarget) {
      try {
        cover = await extractor.fetchAlbumCover();
        packer = image.createImagePacker();
        tmpFile = fileIo.openSync(tmpPath,
          fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        const option: image.PackingOption = {
          format: 'image/jpeg',
          quality: COVER_JPEG_QUALITY
        };
        await packer.packToFile(cover, tmpFile.fd, option);
        fileIo.closeSync(tmpFile);
        tmpFile = null;
        fileIo.renameSync(tmpPath, coverPath);
        coverRenamed = true;
        out.coverPath = coverPath;
      } catch (err) {
        // 无内嵌封面 / 打包失败：封面缺失不阻断标签解析（同目录回退由 Dart 侧负责）。
        const e = err as Error;
        hilog.warn(DOMAIN, TAG, `封面提取失败（忽略，标签照常）：%{public}s`, e.message);
      }
    }
    out.ok = true;
  } catch (err) {
    const e = err as Error;
    out.error = e.message ?? 'unknown';
    hilog.warn(DOMAIN, TAG, `元数据解析失败：%{public}s`, out.error);
  } finally {
    if (tmpFile != null) {
      try {
        fileIo.closeSync(tmpFile);
      } catch (err) {
        // 关闭失败不影响主流程（fd 随进程回收）。
      }
    }
    if (!coverRenamed && hasCoverTarget) {
      try {
        fileIo.unlinkSync(tmpPath);
      } catch (err) {
        // tmp 不存在/删除失败：忽略（下次生成覆盖重建）。
      }
    }
    if (cover != null) {
      try {
        await cover.release();
      } catch (err) {
        // 释放失败仅兜底（PixelMap 随 GC 回收）。
      }
    }
    if (packer != null) {
      try {
        await packer.release();
      } catch (err) {
        // 释放失败仅兜底。
      }
    }
    if (extractor != null) {
      // fdSrc 已交给 extractor：先释放富媒体句柄，再关闭 fd（官方约束：交给
      // extractor 的 fd 不得在释放前作其它读写）。
      try {
        await extractor.release();
      } catch (err) {
        // 释放失败仅兜底。
      }
    }
    if (file != null) {
      try {
        fileIo.closeSync(file);
      } catch (err) {
        // 关闭失败不影响主流程。
      }
    }
  }
  out.costMs = Date.now() - startTs;
  return out;
}
