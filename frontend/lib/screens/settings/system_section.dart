import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../platform/desktop_tray.dart';
import '../../providers/direct_source_manager.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/settings_section_header.dart';
import '../../widgets/settings_tile.dart';
import '../../widgets/shortcut_settings_panel.dart';
import '../../widgets/wheel_picker_dialog.dart';
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
            SettingsTile.toggle(
              title: '驻留托盘',
              description: !trayAvailable
                  ? '当前桌面不支持托盘，关闭窗口会退出'
                  : settings.closeToTray
                      ? '关闭窗口后继续播放，可从托盘恢复'
                      : '关闭窗口即退出',
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
          SettingsTile.toggle(
            title: '通知栏控制',
            description: '通知栏提供播放控制，重启后生效',
            value: settings.notificationControls,
            onChanged: (v) {
              setState(() => settings.notificationControls = v);
              AppToast.show('通知栏控制将在重启应用后生效', isError: false);
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text('仅安卓；关闭不影响后台播放',
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
    final picked = await showNumberWheelDialog(
      context: context,
      title: '日志时长',
      value: settings.logExportMinutes,
      values: wheelRange(
        AppSettings.logExportMinutesMin,
        AppSettings.logExportMinutesMax,
        1,
      ),
      labelOf: (min) => '$min 分钟',
      hint: '导出最近该时长内的日志',
    );
    if (picked == null || !mounted) return;
    setState(() => settings.logExportMinutes = picked);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<DirectSourceManager>().settings;
    final minutes = settings.logExportMinutes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionHeader('诊断'),
        _systemAnchor(
          '日志时长',
          SettingsTile(
            title: '日志时长',
            description: '反馈时附带最近该时长的日志',
            trailing: SettingsValueText('$minutes 分钟'),
            onTap: _pickDuration,
          ),
        ),
      ],
    );
  }
}
