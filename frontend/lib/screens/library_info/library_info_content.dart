import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/navigation_provider.dart';
import 'artist_detail_screen.dart';
import 'format_detail_screen.dart';
import 'library_info_overview.dart';
import 'library_info_tabs.dart';
import 'meta_detail_screen.dart';
import 'play_detail_screen.dart';

/// 歌曲信息工具页（L2 内容栈）：页签 + 总览 / 4 个明细页。
class LibraryInfoContent extends StatelessWidget {
  const LibraryInfoContent({super.key, required this.page});

  final LibraryInfoPage page;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        LibraryInfoTabBar(
          current: page,
          onSelect: (p) =>
              context.read<NavigationProvider>().openLibraryInfo(p),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (page) {
            LibraryInfoPage.overview => const LibraryInfoScreen(),
            LibraryInfoPage.meta => const MetaDetailScreen(),
            LibraryInfoPage.artists => const ArtistDetailScreen(),
            LibraryInfoPage.formats => const FormatDetailScreen(),
            LibraryInfoPage.play => const PlayDetailScreen(),
          },
        ),
      ],
    );
  }
}
