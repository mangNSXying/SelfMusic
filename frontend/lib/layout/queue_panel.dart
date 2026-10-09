import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../widgets/player_sheet_anim.dart';
import '../widgets/row_list.dart';
import '../widgets/song_list.dart';

/// 宽屏右侧常驻面板宽度（[AppShell] 横排传入；窄屏底部弹层不传 width，
/// 撑满可用宽度）。
///
/// 历史坑（2026-09-30 平板真机）：宽屏分支曾以 width=null 塞进 Row——
/// Row 的非 flex 子项拿到**无界宽度**，面板头部 Row 里的 Spacer(flex)
/// 直接抛 unbounded 布局异常，整棵子树布局失败 → 面板空白。窄屏走
/// ModalBottomSheet（有界约束）不受影响——恒宽屏的平板才会踩中。
/// 宽屏必须传有界宽度（回归测试 test/queue_panel_wide_test.dart）。
const double kQueuePanelWidth = 360;

/// 窄屏队列底部弹层高度比例（迷你栏上滑跟手 / 弹层把手拖拽共用行程因子）。
const double kQueueSheetHeightFactor = 0.7;

/// 弹层顶部拖拽把手高度。
const double kQueueSheetHandleHeight = 28;

/// 切换播放队列面板：窄屏竖屏底部弹层开关，宽屏/横屏右侧常驻面板开关。
///
/// 顶栏队列按钮已移除，统一由迷你播放栏进入；AppShell 与迷你栏共用此入口。
/// 宽屏判定与 AppShell.isWide 一致（queue_panel 不导入 app_shell 避免循环依赖）。
///
/// 窄屏从此不再走 `showModalBottomSheet`（固定时长滑入、与触发手指无关的
/// 「不跟手」弹层）；开关只改 [NavigationProvider.queueOpen] 意图位，物理跟手
/// 动画由 [QueueSheetAnimator] + Root 的 `_syncQueueSheet` 统一承担。
void toggleQueuePanel(BuildContext context) {
  final nav = context.read<NavigationProvider>();
  final size = MediaQuery.sizeOf(context);
  final wide = size.width >= 900 || size.width > size.height;
  if (!wide) {
    if (nav.queueOpen) {
      nav.closeQueue();
    } else {
      nav.openQueue();
    }
    return;
  }
  nav.toggleQueue();
}

/// 窄屏「播放队列」底部弹层悬浮层（Root Stack 注入，宽屏自动让位于右侧侧板）。
///
/// 跟手语义与播放页一致：
/// - 迷你栏队列按钮上滑经 [QueueSheetAnimator] 逐帧驱动本层位移——未松手面板
///   已随指升起，不再是「松手后才开始固定动画」；
/// - 把手向下拖拽同样跟手，松手按速度/位移吸附；
/// - 点按遮罩或松手越过阈值 → [NavigationProvider.closeQueue]，收起的吸附动画
///   由 Root `_syncQueueSheet` 承担。
class QueueSheetLayer extends StatelessWidget {
  const QueueSheetLayer({super.key});

  bool _isWide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 900 || size.width > size.height;
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.read<NavigationProvider>();
    final anim = context.read<QueueSheetAnimator>();
    // 宽屏走右侧侧板（AppShell 分支），本层不渲染；MediaQuery 依赖随旋转重建，
    // 宽窄切换即时生效。
    if (_isWide(context)) return const SizedBox.shrink();
    return ValueListenableBuilder<double>(
      valueListenable: nav.queueProgress,
      builder: (c, p, _) {
        // 进度回满即视为关闭：宽窄屏旋转等「queueOpen 为真但从未运行动画」的
        // 情形下，p 恒为 1——若仍挂遮罩会整屏拦截触摸（不可见屏障）。
        if (p >= 1) return const SizedBox.shrink();
        final h = MediaQuery.sizeOf(c).height;
        final sheetH = h * kQueueSheetHeightFactor;
        return Stack(
          children: [
            // 遮罩：点外部关闭（跟手期间同样存在，避免露出底下内容闪烁）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: nav.closeQueue,
                child: ColoredBox(color: Colors.black.withValues(alpha: 0.32)),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Transform.translate(
                offset: Offset(0, p * sheetH),
                child: SizedBox(
                  height: sheetH,
                  // 底部安全区：弹层不再由 ModalBottomSheet 路由兜底，需自行
                  // 让开系统手势条（列表底部最后一行不能被遮挡）。
                  child: SafeArea(
                    top: false,
                    child: Column(
                      children: [
                        _QueueSheetHandle(
                            animator: anim, nav: nav, sheetH: sheetH),
                        Expanded(
                          child: QueuePanel(onClose: nav.closeQueue),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 弹层顶部拖拽把手：向下跟手拉低弹层，松手按速度/位移吸附。
class _QueueSheetHandle extends StatefulWidget {
  const _QueueSheetHandle({
    required this.animator,
    required this.nav,
    required this.sheetH,
  });

  final QueueSheetAnimator animator;
  final NavigationProvider nav;
  final double sheetH;

  @override
  State<_QueueSheetHandle> createState() => _QueueSheetHandleState();
}

class _QueueSheetHandleState extends State<_QueueSheetHandle> {
  double _startY = 0;
  double _startP = 0;

  void _onStart(DragStartDetails d) {
    _startY = d.globalPosition.dy;
    _startP = widget.animator.value;
    widget.animator.dragStart();
  }

  void _onUpdate(DragUpdateDetails d) {
    final sh = widget.sheetH;
    if (sh <= 0) return;
    widget.animator.dragTo(_startP + (d.globalPosition.dy - _startY) / sh);
  }

  void _onEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final p = widget.animator.value;
    if (v > 700 || p > 0.4) {
      widget.nav.closeQueue(); // 收起吸附动画由 Root._syncQueueSheet 承担
    } else {
      widget.animator.settle(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      key: const ValueKey('queue_sheet_handle'),
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      child: Container(
        height: kQueueSheetHandleHeight,
        alignment: Alignment.center,
        color: cs.surface, // 与面板同底色，拖拽空缝不露遮罩。
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: cs.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// 播放队列面板：纯队列展示（当前歌曲与控制在播放页/迷你条操作）。
/// 打开时自动定位到当前播放歌曲并以强调色显示。
class QueuePanel extends StatefulWidget {
  final VoidCallback onClose;

  /// 面板宽度（null 时撑满可用宽度，供窄屏底部弹层使用）。
  final double? width;
  const QueuePanel({super.key, required this.onClose, this.width});

  @override
  State<QueuePanel> createState() => _QueuePanelState();
}

class _QueuePanelState extends State<QueuePanel> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 打开即定位到当前播放歌曲（首帧布局完成后再滚动）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final player = context.read<PlayerProvider>();
      final idx = _currentIndex(player);
      if (idx <= 0) return;
      final target = (idx * kRowExtent - 96)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _currentIndex(PlayerProvider player) {
    for (var i = 0; i < player.queue.length; i++) {
      if (player.isCurrent(player.queue[i])) return i;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final queue = player.queue;

    return Container(
      width: widget.width,
      color: Theme.of(context).colorScheme.surface,
      // 面板自带 Material：宽屏侧板（Scaffold）与窄屏弹层（自建悬浮层）都能让
      // SongTile/ListTile 找到 Material 祖先。Material 放在带色 Container 之内，
      // 避免 ListTile 断言「Material 与 ListTile 之间夹带背景色 ColoredBox」。
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        // 宽屏侧板形态整高直达屏幕顶（与内容列并排，TopBar 的 SafeArea
        // 管不到这里），顶部内容需自行让开状态栏；底色仍满高。
        // 窄屏底部弹层形态下无副作用（顶部不在状态栏区）。
        child: SafeArea(
          top: true,
          child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 4, 4),
              child: Row(
                children: [
                  Text('播放队列',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  IconButton(icon: const Icon(Icons.close), onPressed: widget.onClose),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: queue.isEmpty
                  ? const Center(child: Text('队列为空'))
                  : RowList(
                      controller: _scroll,
                      count: queue.length,
                      itemBuilder: (c, i) {
                        final s = queue[i];
                        final isCurrent = player.isCurrent(s);
                        return SongTile(
                          song: s,
                          source: null,
                          playing: isCurrent,
                          onPlay: () => player.playAt(i),
                        );
                      },
                    ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}
