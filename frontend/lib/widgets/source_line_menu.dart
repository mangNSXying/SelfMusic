import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart' show SourceLine;
import '../providers/direct_source_manager.dart';
import '../providers/player_provider.dart';
import 'app_toast.dart';

/// 播放源线路切换菜单项（源卡片与播放页共用）。
///
/// 仅当该源配置了备用线路时返回内容；文案与选中态在各入口保持一致。
List<PopupMenuEntry<String>> buildSourceLineMenuItems(
    DirectSourceManager direct, String sourceKey) {
  final fbCount = direct.fallbackCountOf(sourceKey);
  if (fbCount == 0) return const [];
  final linePref = direct.linePrefOf(sourceKey);
  String label(SourceLine l) {
    final cur = linePref == l ? ' ✓' : '';
    return switch (l) {
      SourceLine.auto => '线路：自动$cur',
      SourceLine.primary => '线路：主用$cur',
      SourceLine.fb0 => '线路：备用1$cur',
      SourceLine.fb1 => '线路：备用2$cur',
    };
  }

  return [
    const PopupMenuDivider(),
    PopupMenuItem(value: 'line_auto', child: Text(label(SourceLine.auto))),
    PopupMenuItem(
        value: 'line_primary', child: Text(label(SourceLine.primary))),
    PopupMenuItem(value: 'line_fb0', child: Text(label(SourceLine.fb0))),
    if (fbCount > 1)
      PopupMenuItem(value: 'line_fb1', child: Text(label(SourceLine.fb1))),
  ];
}

/// 线路切换选中后的统一处理（源卡片与播放页共用）。
Future<void> applySourceLineSelection(
    BuildContext context, String sourceKey, String value) async {
  final direct = context.read<DirectSourceManager>();
  final line = switch (value) {
    'line_primary' => SourceLine.primary,
    'line_fb0' => SourceLine.fb0,
    'line_fb1' => SourceLine.fb1,
    _ => SourceLine.auto,
  };
  await direct.setLinePref(sourceKey, line);
  if (!context.mounted) return;
  AppToast.show(
      line == SourceLine.auto
          ? '已切到自动线路（主→备 Failover）'
          : line == SourceLine.primary
              ? '已锁定主用线路'
              : line == SourceLine.fb0
                  ? '已锁定备用1线路'
                  : '已锁定备用2线路',
      isError: false);
  try {
    final player = context.read<PlayerProvider>();
    if (player.current?.sourceKey == sourceKey) {
      unawaited(player.reloadCurrentForPlaybackRoute());
    }
  } catch (_) {}
}
