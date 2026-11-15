import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../providers/direct_source_manager.dart';
import 'detail_shared.dart';

/// 歌曲信息 → 歌手详情：解析状态 + 关系/展开进度（与总览同口径）。
class ArtistDetailScreen extends StatelessWidget {
  const ArtistDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final index = context.watch<DirectSourceManager>().index;
    final stats = index.artistStats();
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = stats['total'] ?? 0;
    if (total <= 0) {
      return const Center(child: Text('暂无歌手数据'));
    }

    final mapped = stats['mapped'] ?? 0;
    final withArtist = stats['withArtist'] ?? 0;
    final pct = withArtist <= 0 ? 0.0 : (mapped / withArtist).clamp(0.0, 1.0);
    final segments = [
      ShareSegment('已解析', stats['resolved'] ?? 0, cs.primary),
      ShareSegment('待确认', stats['ambiguous'] ?? 0, cs.tertiary),
      ShareSegment('未命中', stats['local'] ?? 0, cs.secondary),
      ShareSegment('待解析', stats['pending'] ?? 0, cs.outlineVariant),
    ];

    final statusCard = InfoCard(
      title: '解析状态',
      subtitle: '共 $total 个歌手身份',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShareBar(segments: segments, height: 12),
          const SizedBox(height: 12),
          ShareLegend(segments: segments, total: total),
          const SizedBox(height: 12),
          Text(
            '歌曲映射 $mapped / $withArtist 首 · '
            '${(pct * 100).toStringAsFixed(0)}%',
            style: text.bodySmall,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 6,
              backgroundColor: cs.primary.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );

    final relationCard = InfoCard(
      title: '关系与展开',
      child: Column(
        children: [
          _MetricRow(
            label: '成员关系',
            value: '${stats['members'] ?? 0} 条',
          ),
          const Divider(height: 20),
          _MetricRow(
            label: '已展开组合',
            value: '${stats['expanded'] ?? 0} 个',
          ),
          const Divider(height: 20),
          _MetricRow(
            label: '回落组合',
            value: '${stats['fallback'] ?? 0} 个',
            hint: '展开后没有成员，歌手页显示组合本身',
          ),
        ],
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = math.max(
          0.0,
          math.min(constraints.maxWidth, kInfoContentMaxWidth) - 32,
        );
        final twoCol = available >= kInfoTwoColumnMinWidth;
        final half = (available - kInfoCardGap) / 2;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kInfoContentMaxWidth),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: twoCol
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: half, child: statusCard),
                        const SizedBox(width: kInfoCardGap),
                        SizedBox(width: half, child: relationCard),
                      ],
                    )
                  : Column(
                      children: [
                        statusCard,
                        const SizedBox(height: kInfoCardGap),
                        relationCard,
                      ],
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _MetricRow extends StatelessWidget {
  final String label;
  final String value;
  final String? hint;

  const _MetricRow({
    required this.label,
    required this.value,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: text.bodyMedium),
              if (hint != null) ...[
                const SizedBox(height: 2),
                Text(
                  hint!,
                  style: text.bodySmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          value,
          style: text.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
