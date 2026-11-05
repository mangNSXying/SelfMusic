import 'dart:async';

import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../models/song.dart';
import '../../providers/direct_source_manager.dart';
import '../../widgets/source_line_menu.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/edit_song_meta_dialog.dart';
import '../../widgets/online_meta_dialog.dart';
import '../../widgets/song_info_dialog.dart';

import 'player_now_playing.dart';

/// 专辑封面：指定尺寸的方形圆角封面 + 右上角更多操作。
class Cover extends StatelessWidget {
  final String? coverPath;
  final Song song;
  final ColorScheme cs;
  final double size;
  final double scale;

  const Cover({
    required this.coverPath,
    required this.song,
    required this.cs,
    required this.size,
    this.scale = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    // 更多入口随封面缩放：圆框直径与图标按封面边长比例取，限制在可点范围。
    final moreSize = (size * 0.13).clamp(28.0, 44.0);
    final cover = SizedBox(
      key: const Key('player-cover'),
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(24 * scale),
            child: Container(
              color: cs.primary.withValues(alpha: 0.10),
              child: coverPath != null
                  ? Image.file(
                      File(coverPath!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(
                        Icons.music_note,
                        size: size * 0.3,
                        color: cs.primary.withValues(alpha: 0.5),
                      ),
                    )
                  : song.metaUnread
                      ? UnreadCoverPlaceholder(cs: cs, size: size)
                      : Icon(
                          Icons.music_note,
                          size: size * 0.3,
                          color: cs.primary.withValues(alpha: 0.5),
                        ),
            ),
          ),
          Positioned(
            top: size * 0.04,
            right: size * 0.04,
            // 静置隐藏时淡出并停止命中（改进.txt UI3）。
            child: IgnorePointer(
              ignoring: PlayerControlsHidden.isHidden(context),
              child: AnimatedOpacity(
                opacity: PlayerControlsHidden.isHidden(context) ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: Material(
                  color: Colors.white.withValues(alpha: 0.6),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: PopupMenuButton<String>(
                    tooltip: '更多',
                    padding: EdgeInsets.zero,
                    onSelected: (v) => _onSelected(context, v),
                    itemBuilder: (c) => _menuItems(c),
                    child: SizedBox(
                      width: moreSize,
                      height: moreSize,
                      child: Icon(
                        Icons.more_horiz,
                        color: Colors.black87,
                        size: moreSize * 0.5,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return GestureDetector(
      // 桌面右键：在指针处弹出与右上「更多」相同的菜单；
      // 控件自动隐藏时与按钮一致不可用。
      onSecondaryTapDown: PlayerControlsHidden.isHidden(context)
          ? null
          : (d) => _openContextMenuAt(context, d.globalPosition),
      child: cover,
    );
  }

  /// 菜单项（三点按钮与右键菜单共用）。
  List<PopupMenuEntry<String>> _menuItems(BuildContext context) {
    // 线路切换（与源卡片同功能）：仅当该源配了备用时出现。
    List<PopupMenuEntry<String>> lineItems = const [];
    try {
      lineItems = buildSourceLineMenuItems(
          context.read<DirectSourceManager>(), song.sourceKey);
    } catch (_) {}
    return [
      const PopupMenuItem(value: 'info', child: Text('歌曲信息')),
      const PopupMenuItem(value: 'edit', child: Text('修改信息')),
      const PopupMenuItem(value: 'online', child: Text('在线获取元数据')),
      ...lineItems,
    ];
  }

  /// 右键：在指针位置弹出与右上「更多」相同的菜单。
  Future<void> _openContextMenuAt(
      BuildContext context, Offset globalPosition) async {
    final picked = await showContextMenuAt<String>(
      context,
      globalPosition,
      items: _menuItems(context),
    );
    if (picked != null && context.mounted) _onSelected(context, picked);
  }

  void _onSelected(BuildContext context, String v) {
    if (v == 'info') {
      showDialog<void>(
        context: context,
        builder: (_) => SongInfoDialog(song: song),
      );
    } else if (v == 'edit') {
      showDialog<void>(
        context: context,
        builder: (_) => EditSongMetaDialog(song: song),
      );
    } else if (v == 'online') {
      showDialog<void>(
        context: context,
        builder: (_) => OnlineMetaDialog(song: song),
      );
    } else if (v.startsWith('line_')) {
      applySourceLineSelection(context, song.sourceKey, v);
    }
  }
}

/// 未读取元数据时的封面占位：提示「尚未读取，可能有封面」，区别于真无封面的图标占位。
class UnreadCoverPlaceholder extends StatelessWidget {
  final ColorScheme cs;
  final double size;
  const UnreadCoverPlaceholder({required this.cs, required this.size});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.image_not_supported_outlined,
            size: size * 0.22, color: cs.primary.withValues(alpha: 0.5)),
        SizedBox(height: size * 0.04),
        Text(
          Song.unreadLabel,
          style: TextStyle(
            fontSize: size * 0.08,
            color: cs.primary.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}
