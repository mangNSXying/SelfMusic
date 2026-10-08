/**
 * 缩略图生成调度器（ohos-thumb-taskpool feature，plan.md R-1 / R-4 / R-6，T005）。
 *
 * 职责：
 * - **首选** `@ohos.taskpool`（`@kit.ArkTS`）承载缩略图管线（并发函数见
 *   `ThumbTask.ets` 的 `makeCoverThumbTask`）；
 * - **兜底** 若 TaskPool 在目标设备不可用，降级到 ArkTS `Worker` 独立线程
 *   （`workers/ThumbWorker.ets`），降级经 hilog 可观测（R-1 / FR-008）；
 * - **有界并发**（`maxInflight`）避免一次性倾泻任务/结果风暴回主线程（R-4）；
 * - **同目标去重**（同一 `thumbPath` 只执行一次，复用同一 Promise）；
 * - **生命周期**：`shutdown()` 取消在飞任务并终止 Worker，不留半写产物（R-6/FR-009）。
 *
 * 本文件位于宿主（主线程）侧，可依赖 UI 相关能力；真正的重活只在 `ThumbTask.ets`
 * 的无 UI 依赖并发函数中执行。
 */
import { taskpool, worker, MessageEvents, ErrorEvent } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { makeCoverThumbTask, ThumbTaskResult } from './ThumbTask';

const TAG = 'SelfMusicThumb';
/** hilog 业务域。 */
const DOMAIN = 0x0000;

/** 降级到 Worker 时使用的 Worker 入口（须与 entry/build-profile.json5 一致）。 */
const THUMB_WORKER_ENTRY = 'entry/ets/workers/ThumbWorker.ets';

/** 回桥给 Dart 的调度结果（可序列化）。 */
export interface ThumbDispatchResult {
  /** 是否成功落盘。 */
  ok: boolean;
  /** 本张耗时（ms）。 */
  costMs: number;
  /** 降级标记：''（TaskPool）| 'worker'（Worker 兜底）| 'shutdown'。 */
  degraded: string;
}

/** Worker 请求体（可序列化纯数据）。 */
interface ThumbWorkerRequest {
  srcPath: string;
  thumbPath: string;
  maxEdge: number;
  quality: number;
}

/** Worker 应答体（可序列化纯数据）。 */
interface ThumbWorkerResponse {
  ok: boolean;
  costMs: number;
  degraded: string;
}

/** 队列任务。 */
interface ThumbJob {
  srcPath: string;
  thumbPath: string;
  maxEdge: number;
  quality: number;
  resolve: (r: ThumbDispatchResult) => void;
}

/**
 * 有界并发 + 去重的缩略图调度器（单例）。
 */
export class ThumbDispatcher {
  private static instance: ThumbDispatcher | null = null;

  /** 并发上限（默认小并发，避免与渲染抢核；R-4）。 */
  private readonly maxInflight: number = 2;
  private inflightCount: number = 0;
  private readonly queue: Array<ThumbJob> = [];
  /** 同目标去重：thumbPath → 在飞 Promise。 */
  private readonly dedup: Map<string, Promise<ThumbDispatchResult>> =
    new Map<string, Promise<ThumbDispatchResult>>();
  /** 在飞 TaskPool 任务（shutdown 取消用）。 */
  private readonly running: Map<string, taskpool.Task> = new Map<string, taskpool.Task>();
  /** 在飞 Worker（shutdown 终止用）。 */
  private readonly workers: Set<worker.ThreadWorker> = new Set<worker.ThreadWorker>();
  /** TaskPool 是否已探测为不可用（一旦降级保持，避免反复失败）。 */
  private taskpoolBroken: boolean = false;
  private shutdownFlag: boolean = false;

  private constructor() {
  }

  static getInstance(): ThumbDispatcher {
    if (ThumbDispatcher.instance === null) {
      ThumbDispatcher.instance = new ThumbDispatcher();
    }
    return ThumbDispatcher.instance;
  }

  /**
   * 生成一张缩略图（同 `thumbPath` 去重）。返回 Promise，永不 reject。
   */
  generate(srcPath: string, thumbPath: string, maxEdge: number,
    quality: number): Promise<ThumbDispatchResult> {
    const existing = this.dedup.get(thumbPath);
    if (existing !== undefined) {
      return existing;
    }
    const promise = new Promise<ThumbDispatchResult>((resolve) => {
      const job: ThumbJob = {
        srcPath: srcPath,
        thumbPath: thumbPath,
        maxEdge: maxEdge,
        quality: quality,
        resolve: resolve
      };
      this.queue.push(job);
      this.pump();
    });
    this.dedup.set(thumbPath, promise);
    return promise;
  }

  /** 泵动队列：在并发上限内取出任务执行。 */
  private pump(): void {
    while (!this.shutdownFlag && this.inflightCount < this.maxInflight &&
      this.queue.length > 0) {
      const job = this.queue.shift();
      if (job === undefined) {
        break;
      }
      this.inflightCount++;
      this.run(job).then((r: ThumbDispatchResult): void => {
        this.inflightCount--;
        this.dedup.delete(job.thumbPath);
        job.resolve(r);
        this.pump();
      });
    }
  }

  /** 执行单个任务：TaskPool 首选，失败降级 Worker。永不 reject。 */
  private async run(job: ThumbJob): Promise<ThumbDispatchResult> {
    const start = Date.now();
    if (this.shutdownFlag) {
      return ThumbDispatcher.fail(Date.now() - start, 'shutdown');
    }
    if (this.taskpoolBroken) {
      return this.runViaWorker(job, start);
    }
    try {
      const task = new taskpool.Task(makeCoverThumbTask,
        job.srcPath, job.thumbPath, job.maxEdge, job.quality);
      this.running.set(job.thumbPath, task);
      let out: ThumbTaskResult;
      try {
        const raw: Object = await taskpool.execute(task);
        out = raw as ThumbTaskResult;
      } finally {
        this.running.delete(job.thumbPath);
      }
      const result: ThumbDispatchResult = {
        ok: out.ok,
        costMs: out.costMs,
        degraded: out.degraded
      };
      // 宿主侧埋点（T014）：本行由 UI 主线程打印，与并发函数内
      // `SelfMusicThumbTask` 的线程归属行对照，即「生成是否仍在主线程」的判定依据。
      hilog.debug(DOMAIN, TAG,
        `调度完成 ok=${result.ok} cost=${result.costMs}ms degraded=${result.degraded}`);
      return result;
    } catch (err) {
      const e = err as Error;
      if (this.shutdownFlag) {
        return ThumbDispatcher.fail(Date.now() - start, 'shutdown');
      }
      // TaskPool 在目标设备不可用（并发不支持 / 并发函数内图像/文件能力受限 /
      // 模块加载异常等）→ 一次性降级到 Worker 独立线程（可观测，FR-008）。
      hilog.warn(DOMAIN, TAG,
        `TaskPool 不可用，降级 Worker：%{public}s`, e.message);
      this.taskpoolBroken = true;
      return this.runViaWorker(job, start);
    }
  }

  /** Worker 兜底路径：独立线程执行同管线。永不 reject。 */
  private async runViaWorker(job: ThumbJob, start: number): Promise<ThumbDispatchResult> {
    return new Promise<ThumbDispatchResult>((resolve) => {
      let settled = false;
      const finish = (r: ThumbDispatchResult): void => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(r);
      };
      let w: worker.ThreadWorker | null = null;
      try {
        w = new worker.ThreadWorker(THUMB_WORKER_ENTRY);
        const current = w;
        this.workers.add(current);
        current.onmessage = (event: MessageEvents): void => {
          const resp = event.data as ThumbWorkerResponse;
          const r: ThumbDispatchResult = {
            ok: resp.ok,
            costMs: resp.costMs,
            degraded: 'worker'
          };
          this.releaseWorker(current);
          finish(r);
        };
        current.onerror = (event: ErrorEvent): void => {
          hilog.warn(DOMAIN, TAG, `Worker 生成异常：%{public}s`, event.message);
          this.releaseWorker(current);
          finish(ThumbDispatcher.fail(Date.now() - start, 'worker'));
        };
        const req: ThumbWorkerRequest = {
          srcPath: job.srcPath,
          thumbPath: job.thumbPath,
          maxEdge: job.maxEdge,
          quality: job.quality
        };
        current.postMessage(req);
      } catch (err) {
        const e = err as Error;
        hilog.error(DOMAIN, TAG, `Worker 不可用：%{public}s`, e.message);
        if (w !== null) {
          this.releaseWorker(w);
        }
        finish(ThumbDispatcher.fail(Date.now() - start, 'worker'));
      }
    });
  }

  private releaseWorker(w: worker.ThreadWorker): void {
    this.workers.delete(w);
    try {
      w.terminate();
    } catch (err) {
      // 终止失败忽略（随后进程回收）。
    }
  }

  /**
   * 退后台 / 销毁时调用：取消在飞 TaskPool 任务、终止在飞 Worker、以失败结果
   * 结算排队任务（FR-009：不残留半写产物——`.tmp` 由并发函数的 finally 清理）。
   */
  shutdown(): void {
    this.shutdownFlag = true;
    const pending = this.queue.splice(0, this.queue.length);
    for (const job of pending) {
      job.resolve(ThumbDispatcher.fail(0, 'shutdown'));
    }
    this.running.forEach((task: taskpool.Task): void => {
      try {
        taskpool.cancel(task);
      } catch (err) {
        // 取消失败忽略（任务可能已结束）。
      }
    });
    this.running.clear();
    this.dedup.clear();
    this.workers.forEach((w: worker.ThreadWorker): void => {
      try {
        w.terminate();
      } catch (err) {
        // 终止失败忽略。
      }
    });
    this.workers.clear();
  }

  private static fail(costMs: number, degraded: string): ThumbDispatchResult {
    const r: ThumbDispatchResult = { ok: false, costMs: costMs, degraded: degraded };
    return r;
  }
}
