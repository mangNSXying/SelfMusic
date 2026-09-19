import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/navigation_provider.dart';
import '../theme/app_theme.dart';

/// 内容区分组横滑切换：播放列表 ↔ 喜欢 ↔ 播放源。
///
/// 纵向 ListView 只认领纵向手势，横向滑动会冒泡到此层；与顶栏导航、条目点击互不干扰。
/// 到边界不再循环。
class SectionSwipe extends StatelessWidget {
  final Widget child;
  const SectionSwipe({super.key, required this.child});

  static const _order = [NavSection.playlists, NavSection.liked, NavSection.sources];

  @override
  Widget build(BuildContext context) {
    final nav = context.read<NavigationProvider>();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v.abs() < 250) return;
        final i = _order.indexOf(nav.section);
        if (i < 0) return;
        final next = v < 0 ? i + 1 : i - 1;
        if (next < 0 || next >= _order.length) return;
        nav.select(_order[next]);
      },
      child: child,
    );
  }
}
