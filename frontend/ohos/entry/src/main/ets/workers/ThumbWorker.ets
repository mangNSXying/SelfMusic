/**
 * 缩略图 Worker 兜底线程（ohos-thumb-taskpool feature，plan.md R-1 / T005）。
 *
 * 当目标设备上 TaskPool 不可用（含并发函数内图像/文件能力受限）时，调度器
 * `ThumbDispatcher` 降级到本 Worker 的独立线程执行同一管线（`runThumbPipeline`），
 * 保证 FR-001「生成在 UI 主线程之外」恒定成立（FR-008）。
 *
 * 入口路径须与 `entry/build-profile.json5` 的 `buildOption.sourceOption.workers`
 * 及调度器 `THUMB_WORKER_ENTRY` 一致。
 */
import { worker, MessageEvents, ErrorEvent, ThreadWorkerGlobalScope } from '@kit.ArkTS';
import { runThumbPipeline, ThumbTaskResult } from '../platform/ThumbPipeline';

const TAG = 'SelfMusicThumbWorker';
const DOMAIN = 0x0000;

/** 宿主 → Worker 请求体（可序列化纯数据）。 */
interface ThumbWorkerRequest {
  srcPath: string;
  thumbPath: string;
  maxEdge: number;
  quality: number;
}

/** Worker → 宿主应答体（可序列化纯数据）。 */
interface ThumbWorkerResponse {
  ok: boolean;
  costMs: number;
  degraded: string;
}

const workerPort: ThreadWorkerGlobalScope = worker.workerPort;

/** 收到生成请求：在本独立线程执行管线后回包（永不抛未捕获错误）。 */
workerPort.onmessage = (event: MessageEvents): void => {
  const req = event.data as ThumbWorkerRequest;
  runThumbPipeline(req.srcPath, req.thumbPath, req.maxEdge, req.quality)
    .then((r: ThumbTaskResult): void => {
      const resp: ThumbWorkerResponse = {
        ok: r.ok,
        costMs: r.costMs,
        degraded: 'worker'
      };
      workerPort.postMessage(resp);
    })
    .catch((): void => {
      const resp: ThumbWorkerResponse = { ok: false, costMs: 0, degraded: 'worker' };
      workerPort.postMessage(resp);
    });
};

/** 反序列化失败：回失败结果，避免宿主侧悬挂等待。 */
workerPort.onmessageerror = (event: MessageEvents): void => {
  const resp: ThumbWorkerResponse = { ok: false, costMs: 0, degraded: 'worker' };
  workerPort.postMessage(resp);
};

/** Worker 线程内未捕获异常兜底（不影响宿主：宿主侧有 onerror 结算）。 */
workerPort.onerror = (event: ErrorEvent): void => {
  console.error(`${TAG}(${DOMAIN}): ${event.message}`);
};
