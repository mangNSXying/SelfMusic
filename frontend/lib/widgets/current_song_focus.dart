import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../utils/perf_log.dart';
import 'song_list_locator.dart';

/// 「定位当前曲」的统一调度器：触发时机、失败重试、一次锁存全部收口于此。
///
/// 各页只注入纯函数（目标行号、行顶偏移、置顶高度、可选「让目标可见」动作），
/// 不再各自维护 `_focusDone` / `_jumped` 布尔。
///
/// 关键规则（历史问题根因）：
/// - **成功才清 pending**：滚动视图尚未 attach / 尚未有内容尺寸时不算完成，
///   保留 pending 等待度量就绪（[onMetricsAvailable]）或下一次重试；
/// - **目标行暂不可见不算失败**：先调用一次 [revealCurrent]（展开折叠组等），
///   下一帧再试；仍为 -1 则保留 pending，数据到齐后由 [retryIfPending] 补跳；
/// - 同一时刻只有一个 post-frame 回调在飞，重复 [request] 以最后一次为准。
class CurrentSongFocusController {
  CurrentSongFocusController({
    required this.scroll,
    required this.rowIndexOfCurrent,
    required this.rowTopOf,
    this.revealCurrent,
    this.coveredTopOf,
    this.isActive,
  });

  final ScrollController scroll;

  /// 当前曲在展示列表中的行号；`-1` 表示当前不可见 / 不在列表。
  final int Function() rowIndexOfCurrent;

  /// 行号 → 行顶在滚动空间中的偏移（含分组行/块表头/前置 sliver 的前缀和）。
  final double Function(int row) rowTopOf;

  /// 行号为 -1 时先做一次「让目标可见」的动作（展开折叠组、切换目录等）。
  /// 返回 true 表示已改变布局、应下一帧重试。
  final bool Function()? revealCurrent;

  /// 置顶栏/吸顶表头高度（滚动区内被盖住的部分）。
  final double Function()? coveredTopOf;

  /// 宿主是否仍可用（默认恒 true）。
  final bool Function()? isActive;

  bool _pending = false;
  bool _scheduled = false;
  bool _revealed = false;
  int _attempts = 0;
  bool _indexLogged = false;
  bool _metricsLogged = false;

  /// 尚未成功完成定位。
  bool get pending => _pending;

  /// 已成功定位（或从未请求）。
  bool get settled => !_pending;

  /// 请求定位：挂载一次 / 重进 tick / 点击按钮共用。
  ///
  /// [immediate] 为 true 且当前处于 idle（点击回调）时同步生效，保持「点按钮
  /// 立刻跳」；tick 类信号（当前曲可能刚变化、本帧还没重建）传 false，
  /// 统一延后到帧末，用最新的行映射计算目标。
  void request({bool immediate = true}) {
    _pending = true;
    _revealed = false;
    _attempts = 0;
    _indexLogged = false;
    _metricsLogged = false;
    if (immediate &&
        SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle) {
      _attempt();
    }
    if (_pending) _schedule();
  }

  /// 上次请求还没成功时再试一帧（数据/行映射后来才就绪的场景）。
  void retryIfPending() {
    if (_pending) _schedule();
  }

  /// 滚动度量变化（首帧布局完成、窗口缩放等）后补跳。
  void onMetricsAvailable() {
    if (_pending) _schedule();
  }

  /// 切集合 / 换列表：清空等待，等下一次 [request]。
  void reset() {
    _pending = false;
    _attempts = 0;
    _revealed = false;
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _attempt();
    });
  }

  void _attempt() {
    if (!_pending) return;
    if (isActive != null && !isActive!()) return;

    final row = rowIndexOfCurrent();
    if (row < 0) {
      if (!_revealed && revealCurrent != null && revealCurrent!()) {
        _revealed = true;
        _schedule();
        return;
      }
      if (!_indexLogged) {
        _indexLogged = true;
        perfLog('locate.skip', 'index=-1${_revealed ? ' afterReveal' : ''}');
      }
      // 保留 pending：列表数据/展开状态后来就绪时由 retryIfPending 补跳。
      return;
    }

    if (SongListLocator.tryJump(
      scroll,
      rowTop: rowTopOf(row),
      coveredTop: coveredTopOf?.call() ?? 0,
    )) {
      _pending = false;
      perfLog('locate.jump', 'row=$row');
      return;
    }

    // 滚动视图尚未就绪：短重试若干帧，之后交给 onMetricsAvailable。
    _attempts++;
    if (_attempts <= 3) {
      _schedule();
    } else if (!_metricsLogged) {
      _metricsLogged = true;
      perfLog('locate.skip', 'metrics-not-ready row=$row');
    }
  }
}
