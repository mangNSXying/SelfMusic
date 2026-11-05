import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../providers/direct_source_manager.dart';
import '../../services/bluetooth_service.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/settings_section_header.dart';

/// 通知设置（settings.md §3.6）：通知栏控制/后台播放（Android）。
class NotificationsSection extends StatefulWidget {
  const NotificationsSection();
  @override
  State<NotificationsSection> createState() => _NotificationsSettingsState();
}

class _NotificationsSettingsState extends State<NotificationsSection> {
  late AppSettings _settings;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = context.read<DirectSourceManager>().settings;
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        const SettingsSectionHeader('通知'),
        Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
                '通知栏播放控制 / 后台播放基于 just_audio_background，'
                '仅 Android 生效；Linux 桌面忽略这些开关。',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        SwitchListTile(
          title: const Text('通知栏播放控制'),
          subtitle: const Text('在通知栏/播控中心显示播放控制按钮（修改后重启生效）。关闭只隐藏'
              '按钮——后台播放所需的保活（前台服务/长时任务）始终保持，不受影响。'),
          value: _settings.notificationControls,
          onChanged: (v) {
            setState(() => _settings.notificationControls = v);
            AppToast.show('通知栏播放控制将在重启应用后生效', isError: false);
          },
        ),
      ],
    );
  }
}

/// 常亮限定蓝牙设备多选弹窗：复选框支持选多个设备；
/// 所选设备任一处于连接状态即保持常亮；一个都不勾 = 不限定。
class KeepAwakeDeviceDialog extends StatefulWidget {
  const KeepAwakeDeviceDialog({required this.devices, required this.selected});

  final List<BtDevice> devices;
  final Set<String> selected;

  @override
  State<KeepAwakeDeviceDialog> createState() => _KeepAwakeDeviceDialogState();
}

class _KeepAwakeDeviceDialogState extends State<KeepAwakeDeviceDialog> {
  late final Set<String> _sel = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('常亮限定蓝牙设备'),
      content: SizedBox(
        // double.maxFinite：AlertDialog 内容占满弹窗宽（官方推荐形态）；
        // 固定 320 在窄屏/异常窗口度量下有布局风险（2026-10-06 真机
        // 「仅遮罩无内容」bug 一并调整）。
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('可多选：所选设备任一处于连接状态时保持常亮；都不勾 = 不限定',
                  style: TextStyle(fontSize: 12)),
            ),
            Flexible(
              // 不能用 ListView(shrinkWrap:true)：shrinkWrap 视口会进入
              // AlertDialog 内置 IntrinsicWidth 的固有宽度计算路径，ohos
              // fork 在该组合下布局静默失败——脏标志被清却从不布局，弹窗
              // 只渲染灰遮罩（2026-10-07 VM service render dump 取证：
              // 卡片子树已挂载但 size MISSING）。改用普通 Column +
              // SingleChildScrollView（无 shrinkWrap 视口），固有宽度
              // 计算走安全路径。
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final d in widget.devices)
                      CheckboxListTile(
                        dense: true,
                        title: Text(d.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(d.address,
                            style: const TextStyle(fontSize: 11)),
                        value: _sel.contains(d.address),
                        onChanged: (v) => setState(() {
                          if (v ?? false) {
                            _sel.add(d.address);
                          } else {
                            _sel.remove(d.address);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: appDialogActions(
        context,
        confirmLabel: '确定',
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: () => Navigator.of(context).pop([
          for (final d in widget.devices)
            if (_sel.contains(d.address)) d,
        ]),
      ),
    );
  }
}
