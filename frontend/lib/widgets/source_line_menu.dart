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
  // 目标槽不存在时不能静默回落主源：那会让“切到备用”看起来成功、实际仍走
  // 主源。这里直接拒绝，且不改写已保存的线路偏好。
  final fbCount = direct.fallbackCountOf(sourceKey);
  if ((line == SourceLine.fb0 && fbCount < 1) ||
      (line == SourceLine.fb1 && fbCount < 2)) {
    AppToast.show(
        '该源未配置${line == SourceLine.fb0 ? '备用1' : '备用2'}线路',
        isError: true);
    return;
  }
  await direct.setLinePref(sourceKey, line);
  if (!context.mounted) return;
  final label = line == SourceLine.auto
      ? '已切到自动线路（主→备 Failover）'
      : line == SourceLine.primary
          ? '已锁定主用线路'
          : line == SourceLine.fb0
              ? '已锁定备用1线路'
              : '已锁定备用2线路';
  try {
    final player = context.read<PlayerProvider>();
    final cur = player.current;
    if (cur != null && cur.sourceKey == sourceKey) {
      // 缓存优先重载会直接跳过（见 reloadCurrentForPlaybackRoute）：必须
      // 明确告知，否则切线路看起来完全没反应。
      if (direct.isUserCached(cur)) {
        AppToast.show('$label；当前曲已缓存，仍播本地', isError: false);
      } else {
        AppToast.show(label, isError: false);
        unawaited(player.reloadCurrentForPlaybackRoute());
      }
      return;
    }
  } catch (_) {}
  AppToast.show(label, isError: false);
}
