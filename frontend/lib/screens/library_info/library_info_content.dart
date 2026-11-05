import 'package:flutter/material.dart';
import '../../providers/navigation_provider.dart';

import 'library_info_overview.dart';
import 'artist_detail_screen.dart';
import 'format_detail_screen.dart';
import 'play_detail_screen.dart';
import 'meta_detail_screen.dart';

/// 歌曲信息工具页（L2 内容栈）：按子页分发到总览或 4 个明细页。
class LibraryInfoContent extends StatelessWidget {
  const LibraryInfoContent({super.key, required this.page});

  final LibraryInfoPage page;

  @override
  Widget build(BuildContext context) {
    return switch (page) {
      LibraryInfoPage.overview => const LibraryInfoScreen(),
      LibraryInfoPage.meta => const MetaDetailScreen(),
      LibraryInfoPage.artists => const ArtistDetailScreen(),
      LibraryInfoPage.formats => const FormatDetailScreen(),
      LibraryInfoPage.play => const PlayDetailScreen(),
    };
  }
}
