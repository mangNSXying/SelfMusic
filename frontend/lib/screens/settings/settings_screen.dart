import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

import 'server_section.dart';
import 'appearance_section.dart';
import 'songs_section.dart';
import 'playback_section.dart';
import 'general_section.dart';
import 'notifications_section.dart';

/// 设置页：根据侧边栏选中的分区渲染对应设置面板。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.item});

  /// 当前设置分区。必须由路由层显式传入，不能在这里读导航状态：区域切换
  /// 动画会把旧页作为独立图层重新挂载，读导航会让“旧页”也变成新分区，
  /// 出现底层新页静止 + 新页再滑入的“双份 B”观感。
  final SettingsItem item;

  @override
  Widget build(BuildContext context) {
    switch (item) {
      case SettingsItem.appearance:
        return const AppearanceSection();
      case SettingsItem.server:
        return const ServerSettingsSection();
      case SettingsItem.songs:
        return const SongsSection();
      case SettingsItem.general:
        return const GeneralSection();
      case SettingsItem.playback:
        return const PlaybackSection();
      case SettingsItem.notifications:
        return const NotificationsSection();
    }
  }
}
