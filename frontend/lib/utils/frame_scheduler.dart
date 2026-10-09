import 'package:flutter/scheduler.dart';

/// 把动作推迟到「下一帧渲染完成后」执行，并主动调度一帧保证回调必达。
///
/// 同步落库回调用它解耦：拉取/落库完成时若立刻通知 UI，整库列表重建会挤在
/// 同一事件循环轮次里与当前帧渲染抢时间；推迟到帧末执行，让当帧先渲染完，
/// 再补投数据变更（首帧之后的轻量化 / 同步后台化）。
void scheduleAfterFrame(void Function() action) {
  final binding = SchedulerBinding.instance;
  binding.addPostFrameCallback((_) => action());
  binding.scheduleFrame();
}
