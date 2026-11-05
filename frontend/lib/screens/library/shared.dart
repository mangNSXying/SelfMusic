import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import '../../providers/navigation_provider.dart';
import '../../layout/screen_metrics.dart';
import '../../models/song.dart';

/// 过滤/排序结果快照（raw = 未过滤全集，用于空态提示）。
class SortedResult {
  const SortedResult(this.raw, this.songs);
  final List<Song> raw;
  final List<Song> songs;
}

/// 宽屏详情页标题栏左侧的返回箭头（弹层形态仍用右下/右上关闭）。
///
/// 分栏右栏里同样用它：返回只是把右栏退回上一层/空态（左栏过滤词保留）。
class DetailBackButton extends StatelessWidget {
  const DetailBackButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      tooltip: '返回',
      onPressed: () => context
          .read<NavigationProvider>()
          .exitDetail(keepSearch: splitDetailActive(context)),
    );
  }
}

class EmptyHint extends StatelessWidget {
  final VoidCallback onRefresh;
  const EmptyHint({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.music_off,
              size: 72,
              color:
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          const Text('暂无内容'),
          const SizedBox(height: 8),
          TextButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('刷新/扫描'),
              onPressed: onRefresh),
        ],
      ),
    );
  }
}
