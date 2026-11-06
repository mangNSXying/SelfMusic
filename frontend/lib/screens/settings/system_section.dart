import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../platform/desktop_tray.dart';
import '../../providers/direct_source_manager.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/shortcut_settings_panel.dart';
import 'settings_focus.dart';

Widget _systemAnchor(String label, Widget child) => SettingsFocusAnchor(
      id: settingsAnchorId(SettingsItem.system, label),
      child: child,
    );

/// 系统：快捷键 / 桌面和后台 / 诊断。
class SystemSection extends StatelessWidget {
  const SystemSection();

  @override
  Widget build(BuildContext context) => const ShortcutSettingsPanel(
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DesktopAndBackgroundSection(),
            Divider(height: 32),
            LogSection(),
          ],
        ),
      );
}

/// 桌面和后台：关闭驻留托盘 + 通知栏控制。
class DesktopAndBackgroundSection extends StatefulWidget {
  const DesktopAndBackgroundSection();

  @override
  State<DesktopAndBackgroundSection> createState() =>
      _DesktopAndBackgroundSectionState();
}

class _DesktopAndBackgroundSectionState
    extends State<DesktopAndBackgroundSection> {
  @override
  Widget build(BuildContext context) {
    final settings = context.read<DirectSourceManager>().settings;
    final cs = Theme.of(context).colorScheme;
    final tray = DesktopTray.isSupported ? DesktopTray.instance : null;
    // 托盘创建失败（如 Linux 桌面没有 StatusNotifier 宿主）时关闭仍会退出，
    // 开关置灰避免用户误以为窗口藏起来还能从托盘找回。
    final trayAvailable = tray?.trayReady ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionHeader('桌面和后台'),
        if (tray != null)
          _systemAnchor(
            '驻留托盘',
            SwitchListTile(
              title: const Text('驻留托盘'),
              subtitle: Text(!trayAvailable
                  ? '当前桌面未提供托盘支持，关闭窗口仍会退出软件'
                  : settings.closeToTray
                      ? '关闭主窗口后继续后台播放；托盘菜单可恢复窗口、控制播放或退出'
                      : '关闭主窗口即退出软件'),
              value: settings.closeToTray,
              onChanged: trayAvailable
                  ? (v) {
                      setState(() => settings.closeToTray = v);
                      tray.setCloseToTray(v);
                    }
                  : null,
            ),
          ),
        _systemAnchor(
          '通知栏控制',
          SwitchListTile(
            title: const Text('通知栏控制'),
            subtitle: const Text('在通知栏/播控中心显示播放控制按钮（修改后重启生效）。关闭只隐藏'
                '按钮——后台播放所需的保活（前台服务/长时任务）始终保持，不受影响。'),
            value: settings.notificationControls,
            onChanged: (v) {
              setState(() => settings.notificationControls = v);
              AppToast.show('通知栏控制将在重启应用后生效', isError: false);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('通知栏控制基于 just_audio_background，仅 Android 生效；桌面端忽略此开关。',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
        ),
      ],
    );
  }
}

/// 诊断：收集日志 / 反馈附件的导出时长。
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
        const SettingsSectionHeader('诊断'),
        _systemAnchor(
          '日志时长',
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('日志时长'),
            subtitle: Text('收集日志与反馈附件导出最近 $minutes 分钟的内容'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickDuration,
          ),
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
