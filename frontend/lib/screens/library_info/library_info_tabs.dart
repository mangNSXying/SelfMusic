import 'package:flutter/material.dart';

import '../../providers/navigation_provider.dart';

/// 歌曲信息工具页的内部页签：总览 / 元数据 / 歌手 / 格式 / 播放。
///
/// 选中态沿用顶栏分组导航的口径（primary + w600 + 3px 下划线）；
/// 切换走 [NavigationProvider.openLibraryInfo]，明细之间为同层替换。
class LibraryInfoTabBar extends StatelessWidget {
  final LibraryInfoPage current;
  final ValueChanged<LibraryInfoPage> onSelect;

  const LibraryInfoTabBar({
    super.key,
    required this.current,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: LibraryInfoPage.values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 2),
        itemBuilder: (context, i) {
          final page = LibraryInfoPage.values[i];
          final selected = page == current;
          final color =
              selected ? cs.primary : cs.onSurface.withValues(alpha: 0.7);
          final tab = InkWell(
            key: ValueKey('library-info-tab-${page.name}'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => onSelect(page),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(
                    page.tabLabel,
                    style: TextStyle(
                      color: color,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 4,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: selected ? 1 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          height: 3,
                          decoration: BoxDecoration(
                            color: cs.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          // 总览的短名已经等于工具页标题，不再挂重复 tooltip。
          return page == LibraryInfoPage.overview
              ? tab
              : Tooltip(message: page.label, child: tab);
        },
      ),
    );
  }
}
