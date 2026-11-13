import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../data/local/app_settings.dart';
import '../../providers/direct_source_manager.dart';
import '../../services/sync_engine.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/inline_spinner.dart';
import '../../widgets/settings_tile.dart';
import 'devices_screen.dart';
import 'settings_focus.dart';

/// 网络 → 多设备同步（阶段5，DEVELOPER.md「播放算法与同步协议」）：总开关 + 立即同步 + 设备管理入口。
class SyncSection extends StatefulWidget {
  const SyncSection();

  @override
  State<SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<SyncSection> {
  bool _syncing = false;

  /// 待上推事件数缓存（同步后台化：COUNT 走写隔离异步取，不在 build 里同步查库）。
  int _pending = 0;

  @override
  void initState() {
    super.initState();
    _refreshPending();
  }

  Future<void> _refreshPending() async {
    final n =
        await context.read<DirectSourceManager>().index.pendingOutboxCount();
    if (!mounted) return;
    setState(() => _pending = n);
  }

  String _subtitle() {
    final settings = context.read<DirectSourceManager>().settings;
    final engine = context.read<SyncEngine>();
    final parts = <String>[];
    if (_pending > 0) parts.add('$_pending 项待同步');
    final last = settings.lastSyncAt;
    parts.add(last.isEmpty ? '尚未同步' : '上次 ${_shortTime(last)}');
    if (engine.lastError.isNotEmpty) {
      parts.add('同步失败：${engine.lastError}');
    }
    return parts.join(' · ');
  }

  static String _shortTime(String iso) {
    final s = iso.replaceFirst('T', ' ');
    return s.length > 16 ? s.substring(0, 16) : s;
  }

  Future<void> _syncNow() async {
    setState(() => _syncing = true);
    await context.read<SyncEngine>().syncNow(force: true);
    if (!mounted) return;
    setState(() => _syncing = false);
    await _refreshPending();
    if (!mounted) return;
    final err = context.read<SyncEngine>().lastError;
    AppToast.show(err.isEmpty ? '同步完成' : '同步失败：$err', isError: err.isNotEmpty);
  }

  Widget _anchor(String label, Widget child) => SettingsFocusAnchor(
        id: settingsAnchorId(SettingsItem.network, label),
        child: child,
      );

  String _settingsSyncSubtitle(AppSettings settings) {
    if (!settings.syncEnabled) return '先开启多设备同步';
    if (!settings.syncSettingsEnabled) return '未开启';
    final parts = <String>[
      if (settings.syncSettingsPlayback) '播放偏好',
      if (settings.syncSettingsLibrary) '媒体库规则',
      if (settings.syncSettingsInterface) '界面偏好',
      if (settings.syncSettingsTheme) '主题外观',
    ];
    return parts.isEmpty ? '已开启（未选类目）' : '已开启：${parts.join('、')}';
  }

  Future<void> _openSettingsSync() async {
    final settings = context.read<DirectSourceManager>().settings;
    final before = (
      settings.syncSettingsEnabled,
      settings.syncSettingsPlayback,
      settings.syncSettingsLibrary,
      settings.syncSettingsInterface,
      settings.syncSettingsTheme,
    );
    await showDialog<void>(
      context: context,
      builder: (_) => const SettingsSyncDialog(),
    );
    if (!mounted) return;
    setState(() {});
    final after = (
      settings.syncSettingsEnabled,
      settings.syncSettingsPlayback,
      settings.syncSettingsLibrary,
      settings.syncSettingsInterface,
      settings.syncSettingsTheme,
    );
    if (after != before &&
        settings.syncEnabled &&
        settings.syncSettingsEnabled) {
      // 首次开启/新开类目：下一次拉取后只补种服务端没有的键。
      context.read<SyncEngine>().requestSettingsBootstrap();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.read<DirectSourceManager>().settings;
    return Column(
      children: [
        _anchor(
          '同步开关',
          SettingsTile.toggle(
            title: '同步开关',
            description: '收藏、权重、歌单和播放进度',
            value: settings.syncEnabled,
            onChanged: (v) {
              settings.syncEnabled = v;
              setState(() {});
              if (v && settings.syncSettingsEnabled) {
                // 先配置好设置同步、后开总开关：同样补种服务端缺失的键。
                context.read<SyncEngine>().requestSettingsBootstrap();
              }
            },
          ),
        ),
        _anchor(
          '立即同步',
          SettingsTile(
            title: '立即同步',
            description: _subtitle(),
            trailing: _syncing
                ? const InlineSpinner(size: 20)
                : const SettingsValueText('同步'),
            onTap: _syncing ? null : _syncNow,
          ),
        ),
        _anchor(
          '同步设置',
          SettingsTile(
            title: '同步设置',
            description: _settingsSyncSubtitle(settings),
            trailing: const SettingsValueText('选择'),
            onTap: _openSettingsSync,
          ),
        ),
        _anchor(
          '设备管理',
          SettingsTile(
            title: '设备管理',
            description: '查看与吊销已配对设备',
            trailing: const SettingsValueText('查看'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DevicesScreen()),
            ),
          ),
        ),
      ],
    );
  }
}

/// 设置同步范围：总开关 + 播放偏好 / 媒体库规则 / 界面偏好 / 主题外观。
///
/// 类目开关本身是设备本地项，不参与同步；类目关闭时该设备不推也不应用该类设置。
class SettingsSyncDialog extends StatefulWidget {
  const SettingsSyncDialog();

  @override
  State<SettingsSyncDialog> createState() => _SettingsSyncDialogState();
}

class _SettingsSyncDialogState extends State<SettingsSyncDialog> {
  late final AppSettings _settings =
      context.read<DirectSourceManager>().settings;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final enabled = _settings.syncSettingsEnabled;
    return AlertDialog(
      title: const Text('同步设置'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_settings.syncEnabled)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('多设备同步未开启',
                      style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.6))),
                ),
              SettingsTile.toggle(
                title: '同步设置',
                description: '选择哪些设置跟随账号同步',
                value: _settings.syncSettingsEnabled,
                onChanged: (v) =>
                    setState(() => _settings.syncSettingsEnabled = v),
              ),
              SettingsTile.toggle(
                title: '播放偏好',
                value: _settings.syncSettingsPlayback,
                onChanged: enabled
                    ? (v) => setState(() => _settings.syncSettingsPlayback = v)
                    : null,
              ),
              SettingsTile.toggle(
                title: '媒体库规则',
                value: _settings.syncSettingsLibrary,
                onChanged: enabled
                    ? (v) => setState(() => _settings.syncSettingsLibrary = v)
                    : null,
              ),
              SettingsTile.toggle(
                title: '界面偏好',
                value: _settings.syncSettingsInterface,
                onChanged: enabled
                    ? (v) => setState(() => _settings.syncSettingsInterface = v)
                    : null,
              ),
              SettingsTile.toggle(
                title: '主题外观',
                value: _settings.syncSettingsTheme,
                onChanged: enabled
                    ? (v) => setState(() => _settings.syncSettingsTheme = v)
                    : null,
              ),
              const Divider(),
              Text(
                '缓存、音量、网络和快捷键只在本机生效。',
                style: TextStyle(
                    fontSize: 12, color: cs.onSurface.withValues(alpha: 0.6)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('完成'),
        ),
      ],
    );
  }
}
