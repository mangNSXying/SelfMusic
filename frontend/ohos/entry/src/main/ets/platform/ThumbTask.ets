/**
 * 缩略图 TaskPool 并发入口（ohos-thumb-taskpool feature，plan.md R-2 / R-3 / T003）。
 *
 * **无 UI 依赖硬约束（R-2）**：本模块只承载 `@Concurrent` 入口，**不得** import
 * `@kit.ArkUI`（window）/`@kit.AbilityKit`（common）或任何含 UI 装饰器
 * （@Observed/AppStorage 等）的模块——子线程解析到 UI 装饰器会抛异常并中断模块
 * 解析（`xxx is not initialized` 甚至 crash）。故并发函数不能放在
 * `PlatformBridge.ets`（该文件引入了 window/UIAbilityContext）。
 *
 * **编译约束（为何管线在独立文件）**：`@Concurrent` 函数体内**只能**引用入参、
 * 局部变量与 import 的变量；引用同文件顶层函数会被判定为闭包/作用域引用而报错
 * （`Concurrent function should only use import variable or local variable`）。
 * 因此纯管线 `runThumbPipeline` 定义于独立模块 `ThumbPipeline.ets` 并由本文件
 * import 调用（官方 TaskPool FAQ：自定义函数需定义在单独文件并 import）。
 *
 * **跨线程边界（R-3）**：入参/出参均为可序列化纯数据；图像/文件句柄一律在
 * 管线函数内创建与释放，绝不跨线程。
 */
import { runThumbPipeline, ThumbTaskResult } from './ThumbPipeline';

// 保持既有外部契约：调度器（ThumbDispatcher.ets）仍从 './ThumbTask' 取得该类型。
export { ThumbTaskResult } from './ThumbPipeline';

/**
 * 顶层 `@Concurrent` 并发函数（TaskPool 执行入口）：在任务池线程执行整条管线。
 * 管线为 import 的独立模块函数，满足并发函数仅可使用 import 变量/局部变量的约束。
 */
@Concurrent
export function makeCoverThumbTask(srcPath: string, thumbPath: string,
  maxEdge: number, quality: number): Promise<ThumbTaskResult> {
  return runThumbPipeline(srcPath, thumbPath, maxEdge, quality);
}
