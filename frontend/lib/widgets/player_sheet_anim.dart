import 'package:flutter/material.dart';

/// 悬浮层「跟手 / 吸附」动画通用控制器。
///
/// 由 [progress] 这个 [ValueNotifier]（如 `NavigationProvider.playerProgress` /
/// `queueProgress`）驱动位移：0 = 完全展示，1 = 完全隐藏。
/// 手势跟手经 [dragStart]（停掉吸附动画）、[dragTo]（逐帧写进度）完成；
/// 松手用 [settle] 吸附定稿。
///
/// Root 按悬浮层各持一个实例（播放页 / 队列弹层），共用同一套机制；
/// [PlayerSheetAnimator] / [QueueSheetAnimator] 仅用于 Provider 类型区分
/// ——同类名多次注入会令 `context.read` 读取歧义，故拆两个具名子类。
class SheetAnimator {
  final ValueNotifier<double> progress;
  late final AnimationController _ctrl;

  SheetAnimator({
    required TickerProvider vsync,
    required this.progress,
  }) {
    _ctrl = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 220),
      value: progress.value,
    );
    _ctrl.addListener(() => progress.value = _ctrl.value);
    // 外部直接改 progress 时（如打开/关闭定稿）同步内部值，保持唯一事实源。
    progress.addListener(() {
      if (!_ctrl.isAnimating &&
          (_ctrl.value - progress.value).abs() > 0.001) {
        _ctrl.value = progress.value;
      }
    });
  }

  double get value => _ctrl.value;

  /// 跟手开始：停掉进行中的吸附动画（避免与手指抢进度）。
  void dragStart() => _ctrl.stop();

  /// 跟手更新：直接写入进度（自动停掉进行中的动画）。
  void dragTo(double v) => _ctrl.value = v.clamp(0.0, 1.0);

  /// 松手吸附到 [to]；仅在动画自然完成时回调 [onDone]（被打断不回调）。
  void settle(double to, {VoidCallback? onDone}) {
    _ctrl
        .animateTo(to.clamp(0.0, 1.0), curve: Curves.easeOutCubic)
        .then((_) => onDone?.call(), onError: (Object _, StackTrace __) {});
  }

  void dispose() => _ctrl.dispose();
}

/// 播放页悬浮层控制器（Root 持有，全 App 单例）。
///
/// [progress] 即 `NavigationProvider.playerProgress`：
/// 0 = 播放页完全展示，1 = 完全隐藏（回到壳层）。
/// 播放页下拉 / 迷你栏上滑共用同一实例，避免多控制器互相打架。
class PlayerSheetAnimator extends SheetAnimator {
  PlayerSheetAnimator({required super.vsync, required super.progress});
}

/// 窄屏「播放队列」底部弹层控制器（Root 持有，全 App 单例）。
///
/// [progress] 即 `NavigationProvider.queueProgress`：
/// 0 = 队列弹层完全展示，1 = 完全隐藏。迷你栏队列按钮上滑（打开）与
/// 弹层把手拖拽（关闭）共用同一实例。
class QueueSheetAnimator extends SheetAnimator {
  QueueSheetAnimator({required super.vsync, required super.progress});
}