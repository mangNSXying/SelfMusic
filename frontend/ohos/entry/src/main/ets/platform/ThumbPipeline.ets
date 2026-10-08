/**
 * 缩略图生成纯管线（ohos-thumb-taskpool feature，plan.md R-2 / R-3 / T003）。
 *
 * **无 UI 依赖硬约束（R-2）**：本模块**仅** import `@kit.ImageKit`（图像）、
 * `@kit.CoreFileKit`（文件）、`@kit.PerformanceAnalysisKit`（hilog）。
 * **禁止** import `@kit.ArkUI`（window）/`@kit.AbilityKit`（common）或任何含 UI
 * 装饰器（@Observed/AppStorage 等）的模块——子线程解析到 UI 装饰器会抛异常并
 * 中断模块解析（`xxx is not initialized` 甚至 crash）。故并发函数不能放在
 * `PlatformBridge.ets`（该文件引入了 window/UIAbilityContext）。
 *
 * **为何独立于 ThumbTask.ets（编译约束）**：`@Concurrent` 并发函数体内**只能**
 * 引用入参、局部变量与 **import 的变量**；引用同文件其它顶层函数会被判定为
 * 闭包/作用域引用而编译报错（`Concurrent function should only use import
 * variable or local variable`）。故把纯管线函数抽到本文件，由 `ThumbTask.ets`
 * 的 `@Concurrent` 函数 import 调用，同时供 Worker 复用（官方 TaskPool FAQ
 * 「自定义函数需定义在单独文件并 import」）。
 *
 * **跨线程边界（R-3）**：入参只传可序列化纯数据（srcPath/thumbPath/maxEdge/
 * quality），返回只传结果对象（ok/costMs/degraded）。ImageSource / PixelMap /
 * ImagePacker / fileIo.File 等句柄一律在本模块内创建与释放，绝不跨线程。
 *
 * **产物零回归（FR-002）**：读图 → EXIF 方向烘焙 → 最长边等比缩放 → JPEG 编码
 * 质量 82 → `<thumbPath>.tmp` → rename 原子落盘；方向口径与迁移前的
 * `PlatformBridge.handleMakeCoverThumb` 逐项一致（官方 FAQ 映射表 + desiredSize）。
 */
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'SelfMusicThumbTask';
/** hilog 业务域。 */
const DOMAIN = 0x0000;

/** 缩略图生成结果（跨线程传回的可序列化纯数据，R-3）。 */
export interface ThumbTaskResult {
  /** 是否成功落盘。 */
  ok: boolean;
  /** 本张耗时（ms，含读图/解码/编码/写盘）。 */
  costMs: number;
  /** 降级标记：本并发单元内恒为 ''（Worker 兜底由调度器另行标记）。 */
  degraded: string;
}

/** EXIF Orientation 文本值 → 解码变换（官方 FAQ 映射表）。 */
interface ExifTransform {
  /** 解码期旋转角度（度：0/90/180/270）。 */
  rotate: number;
  /** 解码后需水平镜像。 */
  flipH: boolean;
  /** 解码后需垂直镜像。 */
  flipV: boolean;
}

/**
 * EXIF Orientation 文本值 → 解码变换（官方 FAQ 映射表；Top-left 与未知值不变换）。
 * 与主线程内联实现（迁移前的 PlatformBridge 管线）完全同口径（FR-002 产物零回归）。
 */
function exifTransformOf(orientation: string): ExifTransform {
  const t: ExifTransform = { rotate: 0, flipH: false, flipV: false };
  switch (orientation) {
    case 'Top-right':
      t.flipH = true;
      break;
    case 'Bottom-right':
      t.rotate = 180;
      break;
    case 'Bottom-left':
      t.flipV = true;
      break;
    case 'Left-top':
      t.rotate = 270;
      t.flipH = true;
      break;
    case 'Right-top':
      t.rotate = 90;
      break;
    case 'Right-bottom':
      t.rotate = 90;
      t.flipH = true;
      break;
    case 'Left-bottom':
      t.rotate = 270;
      break;
    default:
      // Top-left（EXIF 1）与未知值：不变换。
      break;
  }
  return t;
}

/**
 * 旋转后口径的等比目标尺寸（desiredSize 与 rotate 同时传入时解码器按旋转后
 * 解释）：最长边 ≤ maxEdge、四舍五入正整数、不放大。无需缩放返回 null
 * （解码器用原尺寸）。与迁移前的主线程实现同口径（FR-002）。
 */
function thumbTargetSize(width: number, height: number, rotate: number,
  maxEdge: number): image.Size | null {
  if (width <= 0 || height <= 0) {
    return null;
  }
  const swapped = rotate === 90 || rotate === 270;
  const postW = swapped ? height : width;
  const postH = swapped ? width : height;
  const longest = Math.max(postW, postH);
  if (longest <= maxEdge) {
    return null;
  }
  const scale = maxEdge / longest;
  const target: image.Size = {
    width: Math.max(1, Math.round(postW * scale)),
    height: Math.max(1, Math.round(postH * scale))
  };
  return target;
}

/**
 * 缩略图生成纯管线（可被并发函数与 Worker 复用）：读图 → EXIF 方向烘焙 →
 * 等比缩放 → JPEG 编码 → `<thumbPath>.tmp` → rename 原子落盘。任何失败返回
 * `ok=false`（不抛出），调用方静默回退原图显示（FR-003）。
 *
 * 句柄在本函数内创建与释放（R-3）；`finally` 保证 `.tmp` 清理与资源回收。
 */
export async function runThumbPipeline(srcPath: string, thumbPath: string,
  maxEdge: number, quality: number): Promise<ThumbTaskResult> {
  const startTs = Date.now();
  const tmpPath = `${thumbPath}.tmp`;
  let srcFile: fileIo.File | null = null;
  let imageSource: image.ImageSource | null = null;
  let pixelMap: image.PixelMap | null = null;
  let packer: image.ImagePacker | null = null;
  let tmpFile: fileIo.File | null = null;
  let renamed = false;
  try {
    srcFile = fileIo.openSync(srcPath, fileIo.OpenMode.READ_ONLY);
    imageSource = image.createImageSource(srcFile.fd);
    let orientation = 'Top-left';
    try {
      orientation = await imageSource.getImageProperty(image.PropertyKey.ORIENTATION);
    } catch (err) {
      // 无 EXIF（PNG/HEIF 等）或属性读取异常：按 Top-left 不变换。
    }
    const info = await imageSource.getImageInfo();
    const transform = exifTransformOf(orientation);
    const target = thumbTargetSize(
      info.size.width, info.size.height, transform.rotate, maxEdge);
    const decodeOptions: image.DecodingOptions = {
      rotate: transform.rotate,
      editable: transform.flipH || transform.flipV
    };
    if (target != null) {
      decodeOptions.desiredSize = target;
    }
    pixelMap = await imageSource.createPixelMap(decodeOptions);
    if (transform.flipH || transform.flipV) {
      await pixelMap.flip(transform.flipH, transform.flipV);
    }
    await imageSource.release();
    imageSource = null;
    fileIo.closeSync(srcFile);
    srcFile = null;
    tmpFile = fileIo.openSync(tmpPath,
      fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    packer = image.createImagePacker();
    const packOptions: image.PackingOption = { format: 'image/jpeg', quality: quality };
    await packer.packToFile(pixelMap, tmpFile.fd, packOptions);
    fileIo.closeSync(tmpFile);
    tmpFile = null;
    fileIo.renameSync(tmpPath, thumbPath);
    renamed = true;
    const costMs = Date.now() - startTs;
    // 线程归属 + 单张耗时埋点（T014）：本行由任务池/Worker 线程打印，
    // hilog 自带线程标识，作为「生成是否仍在 UI 主线程」的判定依据。
    hilog.info(DOMAIN, TAG,
      `并发生成完成 cost=%{public}dms orientation=%{public}s rotate=%{public}d q=%{public}d`,
      costMs, orientation, transform.rotate, quality);
    const okResult: ThumbTaskResult = { ok: true, costMs: costMs, degraded: '' };
    return okResult;
  } catch (err) {
    const e = err as Error;
    hilog.warn(DOMAIN, TAG, `并发生成失败：%{public}s`, e.message);
    const failResult: ThumbTaskResult = {
      ok: false,
      costMs: Date.now() - startTs,
      degraded: ''
    };
    return failResult;
  } finally {
    if (tmpFile != null) {
      try {
        fileIo.closeSync(tmpFile);
      } catch (err) {
        // 关闭失败不影响主流程（fd 随进程回收）。
      }
    }
    if (!renamed) {
      try {
        fileIo.unlinkSync(tmpPath);
      } catch (err) {
        // tmp 不存在/删除失败：忽略（下次生成覆盖重建）。
      }
    }
    if (pixelMap != null) {
      pixelMap.release().catch((err: Error): void => {
        hilog.warn(DOMAIN, TAG, `pixelMap 释放失败（忽略）：%{public}s`, err.message);
      });
    }
    if (packer != null) {
      packer.release().catch((err: Error): void => {
        hilog.warn(DOMAIN, TAG, `imagePacker 释放失败（忽略）：%{public}s`, err.message);
      });
    }
    if (imageSource != null) {
      imageSource.release().catch((): void => {
        // 释放失败仅记日志兜底；async 的 Promise 必须处理。
      });
    }
    if (srcFile != null) {
      try {
        fileIo.closeSync(srcFile);
      } catch (err) {
        // 关闭失败不影响主流程。
      }
    }
  }
}
