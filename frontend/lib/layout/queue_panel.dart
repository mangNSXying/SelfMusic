import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/navigation_provider.dart';
import '../providers/player_provider.dart';
import '../widgets/count_header.dart';
import '../widgets/draggable_sheet.dart';
import '../widgets/row_list.dart';
import '../widgets/song_list.dart';

/// 宽屏右侧常驻面板宽度（[AppShell] 横排传入；窄屏走统一拖拽式窗口，不用宽）。
///
/// 历史坑（2026-09-30 平板真机）：宽屏分支曾以 width=null 塞进 Row——
/// Row 的非 flex 子项拿到**无界宽度**，面板头部 Row 里的 Spacer(flex)
/// 直接抛 unbounded 布局异常，整棵子树布局失败 → 面板空白。
/// 宽屏必须传有界宽度（回归测试 test/queue_panel_wide_test.dart）。
const double kQueuePanelWidth = 360;

/// 切换播放队列面板：窄屏打开统一拖拽式窗口，宽屏/横屏切换右侧常驻面板。
///
/// 顶栏队列按钮已移除，统一由迷你播放栏进入；AppShell 与迷你栏共用此入口。
/// 宽屏判定与 AppShell.isWide 一致（queue_panel 不导入 app_shell 避免循环依赖）。
void toggleQueuePanel(BuildContext context) {
  final nav = context.read<NavigationProvider>();
  final size = MediaQuery.sizeOf(context);
  final wide = size.width >= 900 || size.width > size.height;
  if (!wide) {
    // 窄屏：统一拖拽式窗口（点击启动）。窗口在栈上时入口不可点，不会重复
    // 推入（AppSheetLauncher 另有 isShowing 兜底）。
    unawaited(openQueueSheet(context));
    return;
  }
  nav.toggleQueue();
}

/// 窄屏播放队列：统一拖拽式窗口（点击启动，标准展开动画）。
///
/// 走 [AppSheetLauncher] 的悬浮层（[AppSheetHost] 宿主）而非 modal 路由：
/// 路由 push 会取消迷你条上滑跟手的那根手指（见 [AppSheetLauncher]）。
/// 开合镜像到 [NavigationProvider.queueOpen]（迷你条高亮、返回层级用），
/// 遮罩/关闭/返回统一经 scope 收起并同步回关闭。
Future<void> openQueueSheet(BuildContext context) {
  final nav = context.read<NavigationProvider>();
  final launcher = context.read<AppSheetLauncher>();
  if (launcher.isShowing) return Future.value();
  void onNav() {
    if (!nav.queueOpen && launcher.isShowing) launcher.close();
  }

  nav.addListener(onNav);
  return launcher.openTap<void>(
    builder: (c, scrollCtrl) => _QueueSheetContent(scrollCtrl: scrollCtrl),
    onOpen: nav.openQueue,
    onClose: () {
      nav.removeListener(onNav);
      nav.closeQueue();
    },
  );
}

/// 窄屏播放队列：统一拖拽式窗口（滑动启动）①拖拽开始——插入进度 0 的悬浮层，
/// 后续由宿主逐帧拉起、松手定稿（见 [AppSheetLauncher]）。
/// 返回 false 表示窗口已在展示，宿主应忽略本次手势。
bool beginQueueSheetSwipe(BuildContext context) {
  final nav = context.read<NavigationProvider>();
  final launcher = context.read<AppSheetLauncher>();
  void onNav() {
    if (!nav.queueOpen && launcher.isShowing) launcher.close();
  }

  nav.addListener(onNav);
  final started = launcher.beginSwipe<void>(
    builder: (c, scrollCtrl) => _QueueSheetContent(scrollCtrl: scrollCtrl),
    onOpen: nav.openQueue,
    onClose: () {
      nav.removeListener(onNav);
      nav.closeQueue();
    },
  );
  if (!started) nav.removeListener(onNav);
  return started;
}

/// 窄屏队列窗口内容：头部走统一的 [AppSheetTitleBar]（拖拽把手 + 标题 + 关闭），
/// 与队列列表共用窗口的 scroll controller——任意位置按下都可拖拽/滚动窗口
/// （与歌手/专辑弹层同构）。
///
/// 注意：顶部不再套 `SafeArea(top: true)`——统一窗口（悬浮层/路由）的外层已
/// 消费顶部安全区（悬浮层顶部区域让开状态栏，内容从窗口顶边开始）；自建悬浮层
/// 时代这里多出一整块状态栏空白（历史 bug）。底部手势条仍需自行让开。
class _QueueSheetContent extends StatefulWidget {
  const _QueueSheetContent({required this.scrollCtrl});

  final ScrollController scrollCtrl;

  @override
  State<_QueueSheetContent> createState() => _QueueSheetContentState();
}

class _QueueSheetContentState extends State<_QueueSheetContent> {
  bool _jumped = false;

  @override
  void initState() {
    super.initState();
    // 打开即定位到当前播放歌曲（首帧布局完成后再滚动）。
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToCurrent());
  }

  void _jumpToCurrent() {
    if (_jumped || !mounted) return;
    _jumped = true;
    final ctrl = widget.scrollCtrl;
    if (!ctrl.hasClients) return;
    final player = context.read<PlayerProvider>();
    // 下标定位：复本只亮新播的尾一行（身份首匹配会指回旧行）。
    final queue = player.queue;
    if (queue.isEmpty) return;
    final idx = player.currentIndex.clamp(0, queue.length - 1);
    if (idx <= 0) return;
    final target =
        (idx * kRowExtent - 96).clamp(0.0, ctrl.position.maxScrollExtent);
    ctrl.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final queue = player.queue;
    // 统一窗口外层已提供 Material 祖先（悬浮层 Material），SongTile 可直接使用。
    return CustomScrollView(
      controller: widget.scrollCtrl,
      slivers: [
        // 置顶标题栏：与专辑/歌手弹层同一组件（[AppSheetTitleBar]），滚动队列
        // 时标题与关闭按钮始终可见（仍在同一 scrollable，头部同样可拖拽窗口）。
        AppSheetHeader(
          height: AppSheetTitleBar.heightOf(context),
          child: AppSheetTitleBar(title: '播放队列', count: queue.length),
        ),
        if (queue.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text('队列为空')),
          )
        else
          SliverRowList(
            count: queue.length,
            itemBuilder: (c, i) {
              final s = queue[i];
              // 下标判高亮：同首复本仅新播行亮。
              final isCurrent = i == player.currentIndex;
              return SongTile(
                song: s,
                source: null,
                playing: isCurrent,
                onPlay: () => player.playAt(i),
              );
            },
          ),
        // 底部系统手势条：悬浮层顶部已让开状态栏，底部需自行让开。
        SliverToBoxAdapter(
          child: SizedBox(height: MediaQuery.paddingOf(context).bottom),
        ),
      ],
    );
  }
}

/// 播放队列面板：纯队列展示（当前歌曲与控制在播放页/迷你条操作）。
/// 打开时自动定位到当前播放歌曲并以强调色显示。
///
/// 仅宽屏右侧常驻面板使用（窄屏走统一拖拽式窗口 [_QueueSheetContent]）。
class QueuePanel extends StatefulWidget {
  final VoidCallback onClose;

  /// 面板宽度（宽屏侧板传入 [kQueuePanelWidth]，见文件头历史坑）。
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
      final target =
          (idx * kRowExtent - 96).clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _currentIndex(PlayerProvider player) {
    // 下标定位（同上）：空队 -1，否则钳在队内。
    if (player.queue.isEmpty) return -1;
    return player.currentIndex.clamp(0, player.queue.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final player = context.watch<PlayerProvider>();
    final queue = player.queue;

    return Container(
      width: widget.width,
      color: Theme.of(context).colorScheme.surface,
      // 面板自带 Material：宽屏侧板（Scaffold）能让 SongTile/ListTile
      // 找到 Material 祖先。Material 放在带色 Container 之内，避免
      // ListTile 断言「Material 与 ListTile 之间夹带背景色 ColoredBox」。
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        // 宽屏侧板形态整高直达屏幕顶（与内容列并排，TopBar 的 SafeArea
        // 管不到这里），顶部内容需自行让开状态栏；底色仍满高。
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
                    IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: widget.onClose),
                  ],
                ),
              ),
              // 计数栏：与窄屏窗口标题栏同一组件（[CountHeader]）。
              CountHeader(count: queue.length),
              const Divider(height: 1),
              Expanded(
                child: queue.isEmpty
                    ? const Center(child: Text('队列为空'))
                    : RowList(
                        controller: _scroll,
                        count: queue.length,
                        itemBuilder: (c, i) {
                          final s = queue[i];
                          // 下标判高亮：同首复本仅新播行亮。
                          final isCurrent = i == player.currentIndex;
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
