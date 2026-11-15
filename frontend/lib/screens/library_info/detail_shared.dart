import 'dart:async';

import 'package:flutter/material.dart';

/// 歌曲信息页统一的宽度/断点口径。
const double kInfoContentMaxWidth = 1080;
const double kInfoTwoColumnMinWidth = 680;
const double kInfoCardGap = 16;
const double kInfoTableMinWidth = 800;

/// 占比文案；分母为 0 时显示 `—`。
String infoPercent(int got, int total) =>
    total <= 0 ? '—' : '${(got / total * 100).toStringAsFixed(0)}%';

/// 格式/分布图的单色系调色板（主题主色递进，适配深色与自定义强调色）。
List<Color> sharePalette(ColorScheme cs) => [
      cs.primary,
      cs.primary.withValues(alpha: 0.72),
      cs.primary.withValues(alpha: 0.52),
      cs.primary.withValues(alpha: 0.34),
      cs.primary.withValues(alpha: 0.20),
      cs.outlineVariant,
    ];

/// 详情页首次加载：失败显示重试，否则转圈。
class DetailLoadingGuard extends StatelessWidget {
  final bool failed;
  final VoidCallback onRetry;

  const DetailLoadingGuard({
    super.key,
    required this.failed,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: failed
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('加载失败'),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: onRetry, child: const Text('重试')),
              ],
            )
          : const CircularProgressIndicator(),
    );
  }
}

/// 详情页「标签 + 值」行；[ok] 非空时在尾部显示对勾/叉号。
class DetailInfoRow extends StatelessWidget {
  final String label;
  final String value;
  final double labelWidth;
  final bool? ok;

  const DetailInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.labelWidth = 150,
    this.ok,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: cs.onSurface.withValues(alpha: 0.7));
    final body = ok == null
        ? Theme.of(context).textTheme.bodySmall
        : Theme.of(context).textTheme.bodySmall?.copyWith(
              color: ok! ? null : cs.error,
              fontWeight: ok! ? null : FontWeight.w600,
            );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(label, style: muted),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: body,
            ),
          ),
          if (ok != null)
            Icon(
              ok! ? Icons.check : Icons.close,
              size: 14,
              color: ok! ? cs.primary : cs.error,
            ),
        ],
      ),
    );
  }
}

/// 统计卡外壳：统一标题、留白与右上角「查看明细」入口。
class InfoCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const InfoCard({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final body = Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: text.bodySmall?.copyWith(
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

/// 信息卡右上角的「查看明细 >」。
class InfoCardLink extends StatelessWidget {
  const InfoCardLink({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '查看明细',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: cs.primary),
        ),
        Icon(Icons.chevron_right, size: 18, color: cs.primary),
      ],
    );
  }
}

/// 概览 KPI：大号数字 + 标签 + 可选说明。
class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;
  final Color? valueColor;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: valueColor ?? cs.onSurface,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodySmall?.copyWith(
            color: cs.onSurface.withValues(alpha: 0.75),
          ),
        ),
        if (hint != null)
          Text(
            hint!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(
              color: cs.onSurface.withValues(alpha: 0.5),
            ),
          ),
      ],
    );
  }
}

/// 元数据维度单元格：标签 + 百分比 + 4px 细条。
class CoverageItem {
  final String label;
  final int got;

  const CoverageItem(this.label, this.got);
}

class CoverageCell extends StatelessWidget {
  final String label;
  final int got;
  final int total;

  const CoverageCell({
    super.key,
    required this.label,
    required this.got,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pct = total <= 0 ? 0.0 : (got / total).clamp(0.0, 1.0);
    final low = pct < 0.5;
    final color = low ? cs.error : cs.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.75),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${(pct * 100).toStringAsFixed(0)}%',
              style: text.bodySmall?.copyWith(
                color: low ? cs.error : cs.onSurface,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 4,
            backgroundColor: color.withValues(alpha: 0.12),
            color: color,
          ),
        ),
      ],
    );
  }
}

/// 元数据覆盖网格：按可用宽度排 2/3 列。
class CoverageGrid extends StatelessWidget {
  final List<CoverageItem> items;
  final int total;
  final double spacing;
  final double runSpacing;

  const CoverageGrid({
    super.key,
    required this.items,
    required this.total,
    this.spacing = 20,
    this.runSpacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 620 ? 3 : 2;
        // 预留半像素，避免浮点误差把最后一格挤到下一行。
        final width = (c.maxWidth - spacing * (cols - 1)) / cols - 0.5;
        return Wrap(
          spacing: spacing,
          runSpacing: runSpacing,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: CoverageCell(
                  label: item.label,
                  got: item.got,
                  total: total,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 堆叠条的一段。
class ShareSegment {
  final String label;
  final int value;
  final Color color;

  const ShareSegment(this.label, this.value, this.color);
}

/// 单条占比堆叠条；0 值段自动跳过，全 0 显示空轨。
class ShareBar extends StatelessWidget {
  final List<ShareSegment> segments;
  final double height;

  const ShareBar({
    super.key,
    required this.segments,
    this.height = 10,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final total = segments.fold<int>(0, (sum, s) => sum + s.value);
    if (total <= 0) {
      return Container(
        height: height,
        decoration: BoxDecoration(
          color: cs.outlineVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            for (final segment in segments)
              if (segment.value > 0)
                Expanded(
                  flex: segment.value,
                  child: ColoredBox(color: segment.color),
                ),
          ],
        ),
      ),
    );
  }
}

/// 堆叠条图例：色点 + 标签 + 数量 + 百分比。
class ShareLegend extends StatelessWidget {
  final List<ShareSegment> segments;
  final int? total;
  final int columns;
  final double spacing;

  const ShareLegend({
    super.key,
    required this.segments,
    this.total,
    this.columns = 2,
    this.spacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final sum = total ?? segments.fold<int>(0, (acc, s) => acc + s.value);
    return LayoutBuilder(
      builder: (context, c) {
        final cols = columns.clamp(1, 4);
        final width = cols <= 1
            ? c.maxWidth
            : (c.maxWidth - spacing * (cols - 1)) / cols - 0.5;
        return Wrap(
          spacing: spacing,
          runSpacing: 6,
          children: [
            for (final segment in segments)
              SizedBox(
                width: width,
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: segment.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        segment.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      sum <= 0
                          ? '${segment.value}'
                          : '${segment.value} · '
                              '${(segment.value / sum * 100).toStringAsFixed(0)}%',
                      style: text.bodySmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.65),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 统一搜索框。
class LibrarySearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  const LibrarySearchField({
    super.key,
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search),
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: onChanged,
    );
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool active;

  const _InfoPill({
    required this.icon,
    required this.text,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = active ? cs.primary : cs.onSurface.withValues(alpha: 0.72);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(
          color: active ? cs.primary.withValues(alpha: 0.6) : cs.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 5),
          Text(
            text,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: color,
                  fontWeight: active ? FontWeight.w600 : null,
                ),
          ),
          const SizedBox(width: 2),
          Icon(Icons.arrow_drop_down, size: 18, color: color),
        ],
      ),
    );
  }
}

/// 扁平开关 pill：与筛选/排序 pill 同一视觉（无填充底色）。
class LibraryTogglePill extends StatelessWidget {
  final String label;
  final bool selected;
  final IconData icon;
  final ValueChanged<bool> onChanged;

  const LibraryTogglePill({
    super.key,
    required this.label,
    required this.selected,
    required this.icon,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => onChanged(!selected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: _InfoPill(
          icon: selected ? Icons.check : icon,
          text: label,
          active: selected,
        ),
      ),
    );
  }
}

/// 筛选 pill：点开是「全部 / 有缺失 / 缺歌手…」菜单。
class LibraryFilterButton<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final bool active;

  const LibraryFilterButton({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    assert(options.isNotEmpty);
    final cs = Theme.of(context).colorScheme;
    final current = options
        .firstWhere((option) => option.$1 == value, orElse: () => options.first)
        .$2;
    return PopupMenuButton<T>(
      tooltip: '筛选',
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<T>(
            value: option.$1,
            height: 40,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: option.$1 == value
                      ? Icon(Icons.check, size: 16, color: cs.primary)
                      : null,
                ),
                const SizedBox(width: 6),
                Text(
                  option.$2,
                  style: option.$1 == value
                      ? TextStyle(
                          color: cs.primary,
                          fontWeight: FontWeight.w600,
                        )
                      : null,
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: _InfoPill(
          icon: Icons.filter_list,
          text: '$label：$current',
          active: active,
        ),
      ),
    );
  }
}

/// 排序 pill：字段 + 方向；当前字段再点一次翻转方向。
class LibrarySortMenu extends StatelessWidget {
  final String label;
  final int value;
  final bool ascending;
  final List<(int, String)> options;
  final ValueChanged<int> onSelected;

  const LibrarySortMenu({
    super.key,
    required this.label,
    required this.value,
    required this.ascending,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    assert(options.isNotEmpty);
    final cs = Theme.of(context).colorScheme;
    final current = options
        .firstWhere((option) => option.$1 == value, orElse: () => options.first)
        .$2;
    return PopupMenuButton<int>(
      tooltip: '排序',
      position: PopupMenuPosition.under,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<int>(
            value: option.$1,
            height: 42,
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  child: option.$1 == value
                      ? Icon(Icons.check, size: 16, color: cs.primary)
                      : null,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    option.$2,
                    style: option.$1 == value
                        ? TextStyle(
                            color: cs.primary,
                            fontWeight: FontWeight.w600,
                          )
                        : null,
                  ),
                ),
                if (option.$1 == value)
                  Icon(
                    ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 16,
                    color: cs.primary,
                  ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: _InfoPill(
          icon: Icons.sort,
          text: '$label：$current ${ascending ? '↑' : '↓'}',
          active: false,
        ),
      ),
    );
  }
}

/// 明细页统一工具栏：可选摘要行 + 可选搜索行 + 动作/计数行。
class LibraryDetailToolbar extends StatelessWidget {
  final Widget? search;
  final String? summary;
  final List<Widget> actions;
  final String countLabel;

  const LibraryDetailToolbar({
    super.key,
    this.search,
    this.summary,
    this.actions = const [],
    required this.countLabel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              summary!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.7),
                  ),
            ),
          ),
        if (search != null)
          Padding(
            padding: EdgeInsets.fromLTRB(16, summary == null ? 12 : 8, 16, 0),
            child: search!,
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            summary == null && search == null ? 12 : 8,
            16,
            4,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                countLabel,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 详情页全量数据的异步装载器（入场不冻帧）。
///
/// - [request] 在后台 isolate 查库（详见 `runOffThread`；测试环境内联，OHOS
///   与其它平台一样走真实子 isolate），查询期间保留 [data] 旧值不闪屏
///   （首次为 null，调用方显示 loading）；
/// - 查询在途时再次 [request] 只置脏，完成后补查一次，避免扫描期
///   高频通知把全量查询叠成一串；
/// - [onUpdate] 在数据落地（或失败）时回调，调用方 setState 驱动重建。
class DetailDataLoader<T> {
  DetailDataLoader(this._query);

  final Future<T> Function() _query;

  /// 最近一次装载成功的数据；null = 尚未装载成功。
  T? data;

  /// 首次装载失败（[data] 仍为 null）；重试成功后消除。
  bool failed = false;

  /// 数据落地/失败回调（调用方在此 setState）。
  VoidCallback? onUpdate;

  bool _inflight = false;
  bool _dirty = false;

  void request() {
    if (_inflight) {
      _dirty = true;
      return;
    }
    _inflight = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final v = await _query();
      data = v;
      failed = false;
    } catch (_) {
      failed = data == null; // 已有旧数据时静默保留，不打断浏览。
    } finally {
      _inflight = false;
      onUpdate?.call();
      if (_dirty) {
        _dirty = false;
        request();
      }
    }
  }
}
