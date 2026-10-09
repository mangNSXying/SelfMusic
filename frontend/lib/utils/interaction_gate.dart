import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

/// 交互门控协调器（R-2）：聚合「滚动 / 过渡动画 / 播放页拖拽 / 队列弹层
/// 拖拽与开合」五类交互状态，对外派生单一 [isInteracting]；并承载「交互期
/// 高频数据通知去重聚合、交互结束补投一次」的能力（最终一致）。
///
/// 为什么需要它：`DirectSourceManager` 的 `notifyListeners` 在后台补读 /
/// 封面回填 / 元数据变更时高频触发，若恰好落在过渡/滚动动画帧内，会让动画
/// 所涉列表整屏重建（"一直卡"主因之一）。门控在交互期把这类通知合并、去重，
/// 空闲时统一补投一次，既不丢最终状态，又避免动画帧内抖动。
///
/// **零回退保证**：非 ohos 平台与「关闭/淡入/缩放」档同样生效（共性优化），
/// 未接入门控的调用方（如部分单测未提供 Provider）通过 [maybeOf] 取到 `null`
/// 后走原路径，行为与改动前一致。
class InteractionGate extends ChangeNotifier {
  int _scrollDepth = 0;
  bool _transitioning = false;
  bool _playerSheetDragging = false;
  bool _queueSheetDragging = false;
  bool _queuePanelOpen = false;

  /// 交互期被聚合的最新一次数据通知回调（去重：只保留最后一次即等价）。
  VoidCallback? _pendingNotify;

  bool get scrolling => _scrollDepth > 0;
  bool get transitioning => _transitioning;
  bool get playerSheetDragging => _playerSheetDragging;
  bool get queueSheetDragging => _queueSheetDragging;
  bool get queuePanelOpen => _queuePanelOpen;

  /// 是否处于任一「不要干扰」的交互窗口。
  bool get isInteracting =>
      scrolling ||
      _transitioning ||
      _playerSheetDragging ||
      _queueSheetDragging ||
      _queuePanelOpen;

  /// 是否存在被聚合、尚未补投的通知（测试/观测用）。
  @visibleForTesting
  bool get hasPendingNotify => _pendingNotify != null;

  /// 容忍性获取：未接入门控的调用方（旧测试等）返回 `null`，走原路径。
  static InteractionGate? maybeOf(BuildContext context) {
    try {
      return Provider.of<InteractionGate>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  // ---------- 信号来源 1：滚动（嵌套用计数，避免 Start/End 不成对误判） ----------

  void beginScroll() {
    if (_scrollDepth++ == 0) _recompute();
  }

  void endScroll() {
    if (_scrollDepth == 0) return;
    if (--_scrollDepth == 0) _recompute();
  }

  // ---------- 信号来源 2/3/4：过渡动画 / 浮层拖拽 / 队列面板 ----------

  void setTransitioning(bool value) {
    if (_transitioning == value) return;
    _transitioning = value;
    _recompute();
  }

  void setPlayerSheetDragging(bool value) {
    if (_playerSheetDragging == value) return;
    _playerSheetDragging = value;
    _recompute();
  }

  void setQueueSheetDragging(bool value) {
    if (_queueSheetDragging == value) return;
    _queueSheetDragging = value;
    _recompute();
  }

  void setQueuePanelOpen(bool value) {
    if (_queuePanelOpen == value) return;
    _queuePanelOpen = value;
    _recompute();
  }

  /// 数据变更源在通知出口调用：交互期去重聚合，空闲期立即投递。
  ///
  /// [notify] 通常是 `ChangeNotifier.notifyListeners` 的包装。
  void scheduleNotify(VoidCallback notify) {
    if (isInteracting) {
      _pendingNotify = notify; // 去重：多次变更合并为「结束时补投一次」
      return;
    }
    notify();
  }

  bool _active = false;

  void _recompute() {
    final now = isInteracting;
    final was = _active;
    _active = now;
    if (was && !now) _flushPending();
    notifyListeners();
  }

  void _flushPending() {
    final pending = _pendingNotify;
    _pendingNotify = null;
    if (pending == null) return;
    // 交互刚结束：帧末补投，避免与动画最后一帧同帧叠加。
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      scheduleMicrotask(pending);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => pending());
    }
  }

  @visibleForTesting
  void flushPendingNow() => _flushPending();
}
