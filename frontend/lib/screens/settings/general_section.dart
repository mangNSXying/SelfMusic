import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../platform/desktop_tray.dart';
import '../../providers/direct_source_manager.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/shortcut_settings_panel.dart';
import 'backup_section.dart';

/// 常规：快捷键 + 视图行为 + 日志 + 备份与迁移入口。
class GeneralSection extends StatelessWidget {
  const GeneralSection();

  @override
  Widget build(BuildContext context) => const ShortcutSettingsPanel(
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ViewBehaviorSection(),
            TraySection(),
            Divider(height: 32),
            LogSection(),
            Divider(height: 32),
            BackupMigrationTile(),
          ],
        ),
      );
}

/// 常规 → 视图行为（自「界面」迁入）：长按组头展开/折叠。
class ViewBehaviorSection extends StatefulWidget {
  const ViewBehaviorSection();

  @override
  State<ViewBehaviorSection> createState() => _ViewBehaviorSectionState();
}

class _ViewBehaviorSectionState extends State<ViewBehaviorSection> {
  @override
  Widget build(BuildContext context) {
    final settings = context.read<DirectSourceManager>().settings;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('视图行为',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        SwitchListTile(
          title: const Text('长按展开/折叠'),
          subtitle: Text(settings.longPressCollapseGroups
              ? '开：长按组头/文件夹行展开/折叠；多选使用工具条图标'
              : '关：长按组头/文件夹行进入多选；展开/折叠使用工具条图标'),
          value: settings.longPressCollapseGroups,
          onChanged: (v) {
            setState(() => settings.longPressCollapseGroups = v);
            // AppSettings 非 ChangeNotifier：通知已打开的列表页按新行为重建。
            context.read<DirectSourceManager>().refresh();
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('播放源逐级文件夹行支持就地展开：B 模式长按切换展开，A 模式长按选中整个子树',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        ),
      ],
    );
  }
}

/// 常规 → 窗口（仅桌面）：关闭主窗口时驻留系统托盘。
class TraySection extends StatefulWidget {
  const TraySection();

  @override
  State<TraySection> createState() => _TraySectionState();
}

class _TraySectionState extends State<TraySection> {
  @override
  Widget build(BuildContext context) {
    if (!DesktopTray.isSupported) return const SizedBox.shrink();
    final settings = context.read<DirectSourceManager>().settings;
    final cs = Theme.of(context).colorScheme;
    final tray = DesktopTray.instance;
    // 托盘创建失败（如 Linux 桌面没有 StatusNotifier 宿主）时关闭仍会退出，
    // 开关置灰避免用户误以为窗口藏起来还能从托盘找回。
    final available = tray.trayReady;
    final enabled = settings.closeToTray;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('窗口',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        SwitchListTile(
          title: const Text('关闭窗口时驻留托盘'),
          subtitle: Text(!available
              ? '当前桌面未提供托盘支持，关闭窗口仍会退出软件'
              : enabled
                  ? '关闭主窗口后继续后台播放；托盘菜单可恢复窗口或退出'
                  : '关闭主窗口即退出软件'),
          value: enabled,
          onChanged: available
              ? (v) {
                  setState(() => settings.closeToTray = v);
                  tray.setCloseToTray(v);
                }
              : null,
        ),
      ],
    );
  }
}

/// 常规 → 日志：收集日志 / 反馈附件的导出时长。
class LogSection extends StatefulWidget {
  const LogSection();

  @override
  State<LogSection> createState() => _LogSectionState();
}

class _LogSectionState extends State<LogSection> {
  Future<void> _pickDuration() async {
    final settings = context.read<DirectSourceManager>().settings;
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => LogDurationDialog(current: settings.logExportMinutes),
    );
    if (picked == null || !mounted) return;
    setState(() => settings.logExportMinutes = picked);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<DirectSourceManager>().settings;
    final cs = Theme.of(context).colorScheme;
    final minutes = settings.logExportMinutes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text('日志',
              style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
        ),
        ListTile(
          leading: const Icon(Icons.schedule),
          title: const Text('日志时长'),
          subtitle: Text('收集日志与反馈附件导出最近 $minutes 分钟的内容'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickDuration,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('可设置 1~30 分钟，作用于「关于软件」的收集日志与反馈附件',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        ),
      ],
    );
  }
}

/// 日志时长选择弹窗：1~30 分钟整数（步进 1 分钟）。
class LogDurationDialog extends StatefulWidget {
  const LogDurationDialog({required this.current});

  final int current;

  @override
  State<LogDurationDialog> createState() => _LogDurationDialogState();
}

class _LogDurationDialogState extends State<LogDurationDialog> {
  late int _minutes = widget.current;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('日志时长'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导出最近 $_minutes 分钟的日志'),
          Slider(
            value: _minutes.toDouble(),
            min: AppSettings.logExportMinutesMin.toDouble(),
            max: AppSettings.logExportMinutesMax.toDouble(),
            divisions: AppSettings.logExportMinutesMax -
                AppSettings.logExportMinutesMin,
            label: '$_minutes 分钟',
            onChanged: (v) => setState(() => _minutes = v.round()),
          ),
          Text('范围 1~30 分钟；设置越大，导出的日志文件越大。',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      actions: appDialogActions(
        context,
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: () => Navigator.of(context).pop(_minutes),
        confirmLabel: '保存',
      ),
    );
  }
}
