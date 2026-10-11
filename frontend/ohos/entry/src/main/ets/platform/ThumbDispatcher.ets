/**
 * 缩略图生成调度器（ohos-thumb-dispatch-fix feature，plan.md R-1 ~ R-6）。
 *
 * 本文件为「统一单实例 Worker 版」调度链，修复既有缩略图调度链的主线程占死：
 * - **首选** `@ohos.taskpool`（`@kit.ArkTS`）承载缩略图管线（并发函数见
 *   `ThumbTask.ets` 的 `makeCoverThumbTask`）；其健康状态**可恢复**——单次失败
 *   不永久关闭首选，连续失败达阈值才临时降级并在窗口到期后自动重试（R-2）；
 * - **兜底** 降级到 ArkTS `Worker` 独立线程（`workers/ThumbWorker.ets`），
 *   该线程为**单实例长驻复用**：惰性创建至多一次，按请求-应答 FIFO 串行复用
 *   同一执行环境，消除「逐任务新建/销毁」这一主线程占死的直接来源（R-3）；
 * - **兜底损坏闩锁**：创建失败 / `onerror` / `onexit` / 反序列化失败一旦发生即
 *   置 `workerBroken`，永久禁用兜底并以 `ok=false` 结算全部等待者——不再「每任务
 *   重复初始化 → 必失败」风暴（R-4）；
 * - **有界并发**（`maxInflight`）避免一次性倾泻任务/结果风暴回主线程（R-4）；
 * - **同目标去重**（同一 `thumbPath` 只执行一次，复用同一 Promise）；
 * - **生命周期**：`shutdown()` 取消在飞任务、结算排队/兜底在飞请求并安全终止
 *   长驻 Worker，不留半写产物（R-6/FR-009）。
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

/**
 * 首选机制（TaskPool）连续失败达到该阈值才临时降级（R-2 可恢复判定）：
 * 单次失败仍保留首选，仅当连续失败累计至此值才进入降级窗口。
 */
const PRIMARY_FAIL_THRESHOLD = 2;
/** 首选机制临时降级时长（ms）；窗口到期后自动重试首选，成功即清零失败计数。 */
const PRIMARY_RETRY_DELAY_MS = 30000;

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

/** 兜底 Worker 的一条在飞/排队请求（FIFO 关联应答）。 */
interface WorkerCall {
  job: ThumbJob;
  /** 该请求的发起时刻（ms），用于计算兜底耗时。 */
  start: number;
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
  private shutdownFlag: boolean = false;

  // ---------- 首选机制健康状态（可恢复，替代「单次失败即永久置位」） ----------

  /** 首选机制连续失败计数（成功即清零）。 */
  private primaryFailStreak: number = 0;
  /** 首选机制临时降级截止时刻（ms）；0 表示未降级。 */
  private primaryDegradedUntil: number = 0;

  // ---------- 兜底：单实例长驻 Worker（惰性创建，至多一次） ----------

  /** 长驻兜底 Worker 实例；null 表示尚未创建或已销毁。 */
  private thumbWorker: worker.ThreadWorker | null = null;
  /** 兜底执行环境已损坏（创建失败/onerror/onexit），永久禁用兜底。 */
  private workerBroken: boolean = false;
  /** 兜底 Worker 当前在飞请求；串行复用下同一时刻至多一条。 */
  private workerInFlight: WorkerCall | null = null;
  /** 兜底 Worker 待发请求队列（FIFO，保证请求-应答按序关联）。 */
  private readonly workerQueue: Array<WorkerCall> = [];

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

  /**
   * 执行单个任务：优先尝试首选机制（TaskPool），失败时降级兜底 Worker。
   * 永不 reject。
   */
  private async run(job: ThumbJob): Promise<ThumbDispatchResult> {
    const start = Date.now();
    if (this.shutdownFlag) {
      return ThumbDispatcher.fail(Date.now() - start, 'shutdown');
    }
    if (this.shouldUsePrimary()) {
      try {
        return await this.runViaPrimary(job);
      } catch (err) {
        const e = err as Error;
        if (this.shutdownFlag) {
          return ThumbDispatcher.fail(Date.now() - start, 'shutdown');
        }
        // TaskPool 在目标设备不可用（并发不支持 / 并发函数内图像/文件能力受限 /
        // 模块加载异常等）：判定首选机制本次失败并降级兜底（可恢复，R-2/FR-008）。
        this.onPrimaryFailure(e);
        return this.runViaWorker(job, start);
      }
    }
    return this.runViaWorker(job, start);
  }

  /**
   * 首选机制是否可用（可恢复判定）：
   * - 未降级 → 可用；
   * - 处于降级窗口内 → 不可用（直接走兜底）；
   * - 降级窗口已到期 → 开启新一轮尝试并清零连续失败计数（自动重试首选）。
   */
  private shouldUsePrimary(): boolean {
    if (this.primaryDegradedUntil === 0) {
      return true;
    }
    if (Date.now() < this.primaryDegradedUntil) {
      return false;
    }
    this.primaryFailStreak = 0;
    this.primaryDegradedUntil = 0;
    hilog.info(DOMAIN, TAG, '首选机制降级窗口到期，重新尝试 TaskPool');
    return true;
  }

  /**
   * 经首选机制（TaskPool）执行管线。`taskpool.execute` 抛错表示**机制**不可用
   * （向上抛出交由 `run` 降级）；正常返回（即便 `ok=false` 属管线本身失败）
   * 表示机制健康，清零失败计数。
   */
  private async runViaPrimary(job: ThumbJob): Promise<ThumbDispatchResult> {
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
    // execute 正常返回 → 首选机制健康：清零失败计数与降级窗口。
    this.primaryFailStreak = 0;
    this.primaryDegradedUntil = 0;
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
  }

  /** 记录首选机制一次失败：连续失败达阈值才临时降级（可恢复，R-2）。 */
  private onPrimaryFailure(e: Error): void {
    this.primaryFailStreak++;
    if (this.primaryFailStreak >= PRIMARY_FAIL_THRESHOLD) {
      this.primaryDegradedUntil = Date.now() + PRIMARY_RETRY_DELAY_MS;
      hilog.warn(DOMAIN, TAG,
        `TaskPool 连续失败 ${this.primaryFailStreak} 次，暂降级 ${PRIMARY_RETRY_DELAY_MS}ms 后重试：%{public}s`,
        e.message);
    } else {
      hilog.warn(DOMAIN, TAG,
        `TaskPool 单次失败（第 ${this.primaryFailStreak} 次），仍保留首选，本次降级兜底：%{public}s`,
        e.message);
    }
  }

  /** Worker 兜底路径：复用单实例长驻线程执行同管线。永不 reject。 */
  private runViaWorker(job: ThumbJob, start: number): Promise<ThumbDispatchResult> {
    return new Promise<ThumbDispatchResult>((resolve) => {
      if (this.shutdownFlag) {
        resolve(ThumbDispatcher.fail(Date.now() - start, 'shutdown'));
        return;
      }
      if (this.workerBroken) {
        // 兜底执行环境已明确损坏：直接失败，不再逐任务重复初始化（避免风暴）。
        resolve(ThumbDispatcher.fail(Date.now() - start, 'worker'));
        return;
      }
      const call: WorkerCall = { job: job, start: start, resolve: resolve };
      this.workerQueue.push(call);
      this.pumpWorker();
    });
  }

  /**
   * 泵动兜底队列：串行复用长驻 Worker——同一时刻至多投递一条请求，
   * 待应答返回后再投递下一条，保证请求-应答按 FIFO 一一关联。
   */
  private pumpWorker(): void {
    if (this.shutdownFlag || this.workerBroken) {
      return;
    }
    if (this.workerInFlight !== null || this.workerQueue.length === 0) {
      return;
    }
    const w = this.ensureWorker();
    if (w === null) {
      // 创建失败：workerBroken 已置位，结算全部等待者（无逐任务初始化风暴）。
      this.settleWorkerWaiters();
      return;
    }
    const call = this.workerQueue.shift();
    if (call === undefined) {
      return;
    }
    this.workerInFlight = call;
    try {
      const req: ThumbWorkerRequest = {
        srcPath: call.job.srcPath,
        thumbPath: call.job.thumbPath,
        maxEdge: call.job.maxEdge,
        quality: call.job.quality
      };
      w.postMessage(req);
    } catch (err) {
      const e = err as Error;
      hilog.error(DOMAIN, TAG, `兜底 Worker 投递失败：%{public}s`, e.message);
      this.failWorker();
    }
  }

  /**
   * 惰性获取长驻兜底 Worker（进程内至多创建一次）：
   * 已损坏返回 null；已存在复用；否则创建并挂接 onmessage/onmessageerror/
   * onerror/onexit。创建失败即闩锁 `workerBroken`（不再重试创建）。
   */
  private ensureWorker(): worker.ThreadWorker | null {
    if (this.workerBroken) {
      return null;
    }
    if (this.thumbWorker !== null) {
      return this.thumbWorker;
    }
    try {
      const w = new worker.ThreadWorker(THUMB_WORKER_ENTRY);
      w.onmessage = (event: MessageEvents): void => {
        this.onWorkerMessage(event);
      };
      w.onmessageerror = (event: MessageEvents): void => {
        hilog.warn(DOMAIN, TAG, '兜底 Worker 应答反序列化失败');
        this.failWorker();
      };
      w.onerror = (event: ErrorEvent): void => {
        hilog.warn(DOMAIN, TAG, `兜底 Worker 运行异常：%{public}s`, event.message);
        this.failWorker();
      };
      w.onexit = (code: number): void => {
        hilog.warn(DOMAIN, TAG, `兜底 Worker 退出：code=${code}`);
        this.failWorker();
      };
      this.thumbWorker = w;
      hilog.info(DOMAIN, TAG, '兜底 Worker 已创建（单实例长驻复用）');
      return w;
    } catch (err) {
      const e = err as Error;
      hilog.error(DOMAIN, TAG,
        `兜底 Worker 入口加载失败，禁用兜底（不再逐任务初始化）：%{public}s`, e.message);
      this.workerBroken = true;
      this.thumbWorker = null;
      return null;
    }
  }

  /** 收到一条兜底 Worker 应答：结算当前在飞请求并继续泵动。 */
  private onWorkerMessage(event: MessageEvents): void {
    if (this.shutdownFlag) {
      return;
    }
    const call = this.workerInFlight;
    this.workerInFlight = null;
    const resp = event.data as ThumbWorkerResponse;
    if (call !== null) {
      const r: ThumbDispatchResult = {
        ok: resp.ok,
        costMs: resp.costMs,
        degraded: 'worker'
      };
      call.resolve(r);
    }
    this.pumpWorker();
  }

  /**
   * 闩锁兜底损坏（创建失败/onerror/onexit/反序列化失败/投递失败）：永久禁用兜底，
   * 终止实例并以 `ok=false` 结算在飞与排队全部等待者（无逐任务初始化风暴）。
   */
  private failWorker(): void {
    if (this.shutdownFlag) {
      return;
    }
    this.workerBroken = true;
    const w = this.thumbWorker;
    this.thumbWorker = null;
    if (w !== null) {
      try {
        w.terminate();
      } catch (err) {
        // 终止失败忽略（随后进程回收）。
      }
    }
    this.settleWorkerWaiters();
  }

  /** 以 `ok=false` 结算兜底在飞与排队请求（保持各自发起时刻计耗时）。 */
  private settleWorkerWaiters(): void {
    const inFlight = this.workerInFlight;
    this.workerInFlight = null;
    if (inFlight !== null) {
      inFlight.resolve(ThumbDispatcher.fail(Date.now() - inFlight.start, 'worker'));
    }
    const pending = this.workerQueue.splice(0, this.workerQueue.length);
    for (const call of pending) {
      call.resolve(ThumbDispatcher.fail(Date.now() - call.start, 'worker'));
    }
  }

  /**
   * 退后台 / 销毁时调用：取消在飞 TaskPool 任务、结算并安全终止长驻兜底 Worker、
   * 以失败结果结算排队任务（FR-009：不残留半写产物——`.tmp` 由并发函数的
   * finally 清理）。
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
    // 兜底 Worker：先在飞/排队请求按 shutdown 结算，再安全终止长驻实例。
    const inFlight = this.workerInFlight;
    this.workerInFlight = null;
    if (inFlight !== null) {
      inFlight.resolve(ThumbDispatcher.fail(0, 'shutdown'));
    }
    const workerPending = this.workerQueue.splice(0, this.workerQueue.length);
    for (const call of workerPending) {
      call.resolve(ThumbDispatcher.fail(0, 'shutdown'));
    }
    const w = this.thumbWorker;
    this.thumbWorker = null;
    if (w !== null) {
      try {
        w.terminate();
      } catch (err) {
        // 终止失败忽略。
      }
    }
  }

  private static fail(costMs: number, degraded: string): ThumbDispatchResult {
    const r: ThumbDispatchResult = { ok: false, costMs: costMs, degraded: degraded };
    return r;
  }
}
