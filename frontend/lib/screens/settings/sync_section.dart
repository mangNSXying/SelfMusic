import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../providers/direct_source_manager.dart';
import '../../services/sync_engine.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/inline_spinner.dart';
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
    if (_pending > 0) parts.add('待上推 $_pending');
    final last = settings.lastSyncAt;
    parts.add(last.isEmpty ? '尚未同步成功' : '上次 ${_shortTime(last)}');
    if (engine.lastError.isNotEmpty) parts.add('错误：${engine.lastError}');
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

  @override
  Widget build(BuildContext context) {
    final settings = context.read<DirectSourceManager>().settings;
    return Column(
      children: [
        _anchor(
          '同步开关',
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('同步开关'),
            subtitle: const Text('同步 权重 / 收藏 / 歌单 / 断点'),
            value: settings.syncEnabled,
            onChanged: (v) {
              settings.syncEnabled = v;
              setState(() {});
            },
          ),
        ),
        _anchor(
          '立即同步',
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: _syncing
                ? const InlineSpinner(size: 24)
                : const Icon(Icons.sync),
            title: const Text('立即同步'),
            subtitle: Text(_subtitle()),
            onTap: _syncing ? null : _syncNow,
          ),
        ),
        _anchor(
          '设备管理',
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices),
            title: const Text('设备管理'),
            subtitle: const Text('查看 / 改名 / 吊销'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const DevicesScreen()),
            ),
          ),
        ),
      ],
    );
  }
}
