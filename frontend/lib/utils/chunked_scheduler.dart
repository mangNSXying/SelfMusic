import 'dart:async';

/// 让出事件循环的钩子：默认调度到下一个事件循环 tick（等价于「下一帧之前」）。
typedef ChunkYield = Future<void> Function();

/// 把一段可切分的纯 Dart 重活按 [chunkSize] 分片执行，每片之间 [yieldTo]
/// 让出 UI isolate 事件循环，避免长同步块独占线程造成滑动/过渡动画长帧。
///
/// 为什么需要它：根 isolate 上的可切分纯 Dart 重活如果一次性跑完，会长时间
/// 独占 UI 事件循环（OHOS 还会触发 `THREAD_BLOCK_6S`）。子 isolate 本身可用
/// （见 `runScan` 与 SFTP worker），但平台通道、不可发送对象、小任务仍适合
/// 留在根 isolate——此时用「分帧让出」把整块循环切成小片，让出后引擎才有机会
/// 处理动画/输入事件（plan.md R-5）。
///
/// 语义：同步遍历 [0, length)，每 [chunkSize] 个调用一次 [process]；分片之间
/// `await yieldTo()`。**幂等**——不修改外部状态，重复调用结果一致；**可中断**——
/// 调用方可在 [process] 内抛出以提前终止（异常向上传播）。
///
/// [yieldTo] 可注入以便确定性测试（默认 `Future.delayed(Duration.zero)`）。
Future<void> runChunked({
  required int length,
  required void Function(int index) process,
  int chunkSize = 64,
  ChunkYield? yieldTo,
}) async {
  if (length <= 0) return;
  final step = chunkSize < 1 ? 1 : chunkSize;
  final nextTick = yieldTo ?? _defaultYield;
  for (var start = 0; start < length; start += step) {
    final end = (start + step < length) ? start + step : length;
    for (var i = start; i < end; i++) {
      process(i);
    }
    if (end < length) await nextTick();
  }
}

Future<void> _defaultYield() => Future<void>.delayed(Duration.zero);

/// 统一的「让出事件循环」默认钩子（公开给需按阶段让出、但不适合用
/// [runChunked] 索引切片的调用方，如解析阶段之间 / DB 批间让出）。
///
/// 语义与 [runChunked]/[runChunkedCancellable] 的默认 [ChunkYield] 一致：调度到
/// 下一个事件循环 tick（不引入对 UI 帧的强依赖），供补读/权重预热/歌手解析等
/// 主线程长同步块治理复用（单次同步块 < 50ms）。
Future<void> yieldToEventLoop() => Future<void>.delayed(Duration.zero);

/// 分块任务的取消令牌（代次比较）：持令牌者重建任务时旧令牌作废，
/// 旧任务在片间检查 [isCancelled] 安全退出——配合 [runChunked] 实现「可中断续跑」。
class ChunkToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// [runChunked] 的取消感知版本：每片开始前检查 [token]，已取消则停止后续处理
/// （已处理部分不回滚；调用方负责以幂等语义续跑）。
Future<void> runChunkedCancellable({
  required ChunkToken token,
  required int length,
  required void Function(int index) process,
  int chunkSize = 64,
  ChunkYield? yieldTo,
}) async {
  if (length <= 0) return;
  final step = chunkSize < 1 ? 1 : chunkSize;
  final nextTick = yieldTo ?? _defaultYield;
  for (var start = 0; start < length; start += step) {
    if (token.isCancelled) return;
    final end = (start + step < length) ? start + step : length;
    for (var i = start; i < end; i++) {
      if (token.isCancelled) return;
      process(i);
    }
    if (end < length) await nextTick();
  }
}
