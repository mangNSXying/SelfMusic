import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../data/sources/music_source.dart';
import '../../navigation/detail_target.dart';
import '../../layout/screen_metrics.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/playlists_provider.dart';
import '../../theme/app_theme.dart';
import '../../utils/collection_sort.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/corner_add_button.dart';
import '../../widgets/count_header.dart';
import '../../widgets/detail_presentation.dart';
import '../../widgets/list_detail_split.dart';
import '../../widgets/sort_menu_button.dart';
import '../../widgets/row_list.dart';
import '../../widgets/square_card.dart';
import '../../widgets/view_mode_toggle.dart';
import 'source_browse_view.dart';

import 'source_dialog/source_dialog.dart';
import '../../widgets/source_line_menu.dart';

/// 播放源管理页：直连源（本地 / SMB / WebDAV / SFTP）列表（支持列表/卡片切换）。
///
/// - 点击源卡片直接进入源内浏览（文件夹式导航）。
/// - 卡片右侧「三点」菜单承载 编辑、删除等设置。
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen>
    with AutomaticKeepAliveClientMixin, ViewModeState {
  /// 滑动档横滑时保持存活（与其余分组页一致）。
  @override
  bool get wantKeepAlive => true;

  @override
  ViewModeSlot get viewModeSlot => ViewModeSlot.sources;

  @override
  AppSettings Function() get appSettings =>
      () => context.read<DirectSourceManager>().settings;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final direct = context.watch<DirectSourceManager>();
    // 顶栏搜索在播放源列表页按源名称过滤（进入源内后切换为搜索该源歌曲）。
    final search = context.select<NavigationProvider, String>((n) => n.search);
    final scheme = Theme.of(context).colorScheme;
    final card = isCard;
    final q = search.trim().toLowerCase();
    final all = direct.sources;
    final sources = sortByCollection(
        q.isEmpty
            ? all
            : all.where((s) => s.name.toLowerCase().contains(q)).toList(),
        direct.settings.sortSources,
        (s) => s.name,
        countOf: (s) => direct.countOf(s.key),
        zhAware: false);

    // 大横屏 + 列表模式：左源列表 / 右源内浏览（源内不再整页替换）。
    // 按自身分组判定：离屏缓存期间重建时全局分组可能已是别的页。
    final split = splitDetailActive(context, section: NavSection.sources);
    final selectedKey = context.select<NavigationProvider, String?>(
        (n) => split ? n.browsingSourceKey : null);

    final listPane = Stack(
      children: [
        Column(
          children: [
            CountHeader(
              count: sources.length,
              unit: '个播放源',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  viewModeToggle(),
                  SortMenuButton(
                    value: direct.settings.sortSources,
                    scope: SortScope.collections,
                    onChanged: (v) =>
                        setState(() => direct.settings.sortSources = v),
                  ),
                ],
              ),
            ),
            Expanded(
              child: sources.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text(all.isEmpty ? '尚未添加播放源，点右下角「+」添加' : '无匹配播放源',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    )
                  : card
                      ? SquareCardGrid(
                          itemCount: sources.length,
                          itemBuilder: (c, i) =>
                              _DirectSourceCard(sourceKey: sources[i].key),
                        )
                      : RowList(
                          // 分栏↔整页切换会重建列表：靠 PageStorage 记住滚动位置。
                          key: const PageStorageKey<String>('sources-list'),
                          count: sources.length,
                          itemBuilder: (c, i) => _DirectSourceTile(
                            sourceKey: sources[i].key,
                            active: split && selectedKey == sources[i].key,
                          ),
                        ),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: CornerAddButton(
            tooltip: '添加播放源',
            onPressed: () => showDialog<void>(
                context: context, builder: (_) => const SourceDialog()),
          ),
        ),
      ],
    );

    return ListDetailSplit(
      enabled: split,
      listWidth: ScreenMetrics.of(context).listPaneWidth,
      list: listPane,
      detail: DetailPane(
        // 源内浏览复用同一份实现（pane：栏内不包 SectionSwipe——横滑属于
        // 外层分组 Pager，栏内再套一层会抢手势）。
        detail: selectedKey == null
            ? null
            : SourceBrowseView(
                sourceKey: selectedKey,
                presentation: DetailPresentation.pane,
              ),
        detailKey: selectedKey,
        emptyIcon: Icons.storage,
        emptyText: '从左侧选择播放源浏览',
        duration: direct.settings.playerTransition == PlayerTransition.none
            ? Duration.zero
            : kDetailPaneMotion,
      ),
    );
  }
}

/// 打开播放源（列表行/卡片共用入口）。
///
/// 分栏时进右栏、整页呈现时沿用原区域切换；重复点同一源不再触发切换。
void _openSource(BuildContext context, String sourceKey) {
  openDetail(context, SourceTarget(sourceKey));
}

class _DirectSourceTile extends StatelessWidget {
  final String sourceKey;

  /// 分栏时是否为「右栏当前源」对应的左栏行（只做底色提示）。
  final bool active;
  const _DirectSourceTile({required this.sourceKey, this.active = false});

  @override
  Widget build(BuildContext context) =>
      _DirectSourceCard(sourceKey: sourceKey, plain: true, active: active);
}

/// 播放源类型图标（一类一图标）：本地=存储图标，远端=协议文字徽标。
/// [framed] 为 true 时套 tinted 圆角徽标盒（列表行 leading 用），
/// false 时只渲染裸图标/文字（方形卡片占位用，卡片底已自带 tint）。
class _SourceKindIcon extends StatelessWidget {
  final SourceKind kind;
  final double size;
  final bool framed;
  const _SourceKindIcon(
      {required this.kind, this.size = 40, this.framed = true});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final Widget content;
    if (kind == SourceKind.local) {
      content = Icon(Icons.storage_outlined,
          size: framed ? size * 0.6 : size,
          color: primary.withValues(alpha: framed ? 1.0 : 0.6));
    } else {
      final label = switch (kind) {
        SourceKind.webdav => 'WebDAV',
        SourceKind.sftp => 'SFTP',
        SourceKind.smb => 'SMB',
        SourceKind.local => '',
      };
      content = FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(label,
            maxLines: 1,
            style: TextStyle(
                color: primary.withValues(alpha: framed ? 1.0 : 0.6),
                fontWeight: FontWeight.w800,
                fontSize: framed ? size * 0.3 : size * 0.42)),
      );
    }
    if (!framed) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Center(child: content),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(size * 0.25),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: size * 0.1),
        child: content,
      ),
    );
  }
}

class _DirectSourceCard extends StatelessWidget {
  final String sourceKey;

  /// true 时渲染为不走卡片的紧凑列表行。
  final bool plain;

  /// 分栏时是否为右栏当前源（列表行底色提示；卡片形态不分栏，恒 false）。
  final bool active;
  const _DirectSourceCard(
      {required this.sourceKey, this.plain = false, this.active = false});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final s = direct.sourceByKey(sourceKey);
    if (s == null) return const SizedBox.shrink();
    final count = direct.countOf(sourceKey);
    final isLocal = s.kind == SourceKind.local;
    final needsSecrets = direct.sourceNeedsSecrets(sourceKey);
    final fbCount = direct.fallbackCountOf(sourceKey);
    final fbNeeds = fbCount > 0 && direct.fallbackNeedsSecrets(sourceKey);
    final linePref = direct.linePrefOf(sourceKey);
    // 非本地源的播放链路（弹窗可配）：直连/代理二选一，互斥替换；
    // 本地源恒直连。代理才走服务端转码，直连恒原生地址。
    final routeLabel = isLocal || s.route == SourceRoute.direct ? '直连' : '代理';
    final fbLabel = fbCount > 0 ? ' · 备×$fbCount' : '';
    final lineLabel = linePref == SourceLine.auto
        ? ''
        : linePref == SourceLine.primary
            ? ' · 线路:主用'
            : linePref == SourceLine.fb0
                ? ' · 线路:备用1'
                : ' · 线路:备用2';

    final tile = GestureDetector(
      // 桌面右键：在指针处弹出与三点按钮相同的源设置菜单。
      onSecondaryTapDown: (d) =>
          _openSourceMenuAt(context, sourceKey, direct, d.globalPosition),
      child: ListTile(
        // 分栏时高亮右栏当前源（与歌单/专辑/歌手左栏同一配色）。
        tileColor: plain && active
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.10)
            : null,
        leading: _SourceKindIcon(kind: s.kind),
        title: Text(s.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(needsSecrets
            ? '待配置凭据 · 点击「编辑」补输后可用'
            : fbNeeds
                ? '$routeLabel$fbLabel$lineLabel · 备用待配凭据 · 已索引 $count 首'
                : '$routeLabel$fbLabel$lineLabel · 已索引 $count 首'),
        trailing: _SourceMenu(sourceKey: sourceKey, direct: direct),
        onTap: () => _openSource(context, sourceKey),
      ),
    );
    if (plain) return tile;
    // 卡片形态：与专辑/歌手共用方形卡片（SquareCard），菜单叠右上角。
    return SquareCard(
      title: s.name,
      subtitle: needsSecrets
          ? '待配置凭据 · 点击「编辑」补输后可用'
          : fbNeeds
              ? '$routeLabel$fbLabel$lineLabel · 备用待配凭据 · 已索引 $count 首'
              : '$routeLabel$fbLabel$lineLabel · 已索引 $count 首',
      fallback: _SourceKindIcon(kind: s.kind, size: 44, framed: false),
      onTap: () => _openSource(context, sourceKey),
      cornerAction: _SourceMenu(sourceKey: sourceKey, direct: direct),
      onSecondaryTapDown: (d) =>
          _openSourceMenuAt(context, sourceKey, direct, d.globalPosition),
    );
  }
}

/// 播放源设置菜单（列表行 trailing / 方形卡片右上角共用）。
/// 含线路切换（自动/主用/备用1/备用2，与播放页三点菜单同功能）。
class _SourceMenu extends StatelessWidget {
  final String sourceKey;
  final DirectSourceManager direct;
  const _SourceMenu({required this.sourceKey, required this.direct});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '源设置',
      iconSize: 20,
      padding: EdgeInsets.zero,
      onSelected: (v) => _handleSourceMenuValue(context, sourceKey, direct, v),
      itemBuilder: (c) => _sourceMenuItems(sourceKey, direct),
    );
  }
}

/// 播放源菜单项（三点按钮与右键菜单共用）。
List<PopupMenuEntry<String>> _sourceMenuItems(
    String sourceKey, DirectSourceManager direct) {
  return [
    const PopupMenuItem(value: 'edit', child: Text('编辑')),
    ...buildSourceLineMenuItems(direct, sourceKey),
    const PopupMenuDivider(),
    const PopupMenuItem(
      value: 'delete',
      child: Text('删除源', style: TextStyle(color: Colors.redAccent)),
    ),
  ];
}

/// 播放源菜单选中回调（三点按钮与右键菜单共用）。
Future<void> _handleSourceMenuValue(BuildContext context, String sourceKey,
    DirectSourceManager direct, String v) async {
  switch (v) {
    case 'edit':
      showDialog<void>(
          context: context, builder: (_) => SourceDialog(editKey: sourceKey));
    case 'delete':
      _confirmDelete(context, sourceKey, direct);
    case 'line_auto':
    case 'line_primary':
    case 'line_fb0':
    case 'line_fb1':
      await applySourceLineSelection(context, sourceKey, v);
  }
}

/// 右键：在指针位置弹出与三点按钮相同的源设置菜单。
Future<void> _openSourceMenuAt(BuildContext context, String sourceKey,
    DirectSourceManager direct, Offset globalPosition) async {
  final picked = await showContextMenuAt<String>(
    context,
    globalPosition,
    items: _sourceMenuItems(sourceKey, direct),
  );
  if (picked != null && context.mounted) {
    await _handleSourceMenuValue(context, sourceKey, direct, picked);
  }
}

/// 删除源二次确认（列表/卡片共用）。
Future<void> _confirmDelete(
    BuildContext context, String key, DirectSourceManager direct) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('删除源'),
      content: const Text('确定删除该播放源吗？其本地索引与歌单中的相关歌曲也会一并清除。'),
      actions: appDialogActions(
        c,
        confirmLabel: '删除',
        destructive: true,
        onCancel: () => Navigator.of(c).pop(false),
        onConfirm: () => Navigator.of(c).pop(true),
      ),
    ),
  );
  if (ok == true) {
    await direct.removeSource(key);
    if (context.mounted) {
      // 正在浏览的源被删：左栏行已消失，右栏不能停在旧源上。
      final nav = context.read<NavigationProvider>();
      if (nav.browsingSourceKey == key) {
        nav.exitSource(keepSearch: splitDetailActive(context));
      }
      // 删源同时清理了歌单条目：刷新计数与详情缓存。
      context.read<PlaylistsProvider>().refresh();
    }
  }
}
