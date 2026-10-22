import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../widgets/app_dialog_actions.dart';
import '../widgets/app_toast.dart';

/// 已配对设备管理（阶段5）：列表 / 改名 / 吊销（调 `DeviceAdminController`）。
/// 当前设备按配对时下发的 client_id 高亮。
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  String? _selfClientId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final selfId = await api.getClientId();
      final list = await api.fetchDevices();
      if (!mounted) return;
      setState(() {
        _selfClientId = selfId;
        _devices = [
          for (final e in (list ?? const []))
            if (e is Map) e.cast<String, dynamic>()
        ];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _rename(Map<String, dynamic> d) async {
    final ctrl = TextEditingController(text: (d['name'] as String?) ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('设备改名'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: '设备名'),
        ),
        actions: appDialogActions(
          c,
          confirmLabel: '保存',
          onCancel: () => Navigator.of(c).pop(),
          onConfirm: () => Navigator.of(c).pop(ctrl.text.trim()),
        ),
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await context.read<ApiClient>().renameDevice((d['id'] as num).toInt(), name);
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.show('改名失败：$e');
    }
  }

  Future<void> _revoke(Map<String, dynamic> d) async {
    final isSelf = (d['clientId'] as String?) == _selfClientId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('吊销设备？'),
        content: Text('「${d['name']}」的令牌将即刻失效。'
            '${isSelf ? '这是本机，吊销后需重新配对。' : ''}'),
        actions: appDialogActions(
          c,
          confirmLabel: '吊销',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<ApiClient>().revokeDevice((d['id'] as num).toInt());
      await _load();
    } catch (e) {
      if (!mounted) return;
      AppToast.show('吊销失败：$e');
    }
  }

  String _subtitle(Map<String, dynamic> d) {
    final parts = <String>[];
    final platform = d['platform'] as String?;
    if (platform != null && platform.isNotEmpty) parts.add(platform);
    final lastSeen = d['lastSeenAt'] as String?;
    parts.add(lastSeen == null || lastSeen.isEmpty
        ? '未活跃'
        : '上次活跃 ${_shortTime(lastSeen)}');
    if (d['revoked'] == true) parts.add('已吊销');
    return parts.join(' · ');
  }

  static String _shortTime(String iso) {
    // 2026-09-20T12:34:56 → 2026-09-20 12:34
    final s = iso.replaceFirst('T', ' ');
    return s.length > 16 ? s.substring(0, 16) : s;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('已配对设备'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('加载失败：$_error'))
              : _devices.isEmpty
                  ? const Center(child: Text('暂无已配对设备'))
                  : ListView.separated(
                      itemCount: _devices.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final d = _devices[i];
                        final isSelf =
                            (d['clientId'] as String?) == _selfClientId;
                        final revoked = d['revoked'] == true;
                        return ListTile(
                          leading: Icon(revoked
                              ? Icons.block
                              : _iconFor(d['platform'] as String?)),
                          title: Text(
                              '${(d['name'] as String?) ?? '未知设备'}${isSelf ? '（本机）' : ''}'),
                          subtitle: Text(_subtitle(d)),
                          trailing: revoked
                              ? null
                              : PopupMenuButton<String>(
                                  onSelected: (v) {
                                    if (v == 'rename') {
                                      _rename(d);
                                    } else if (v == 'revoke') {
                                      _revoke(d);
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'rename',
                                        child: Text('改名')),
                                    PopupMenuItem(
                                        value: 'revoke',
                                        child: Text('吊销')),
                                  ],
                                ),
                        );
                      },
                    ),
    );
  }

  static IconData _iconFor(String? platform) {
    final p = (platform ?? '').toLowerCase();
    if (p.contains('android')) return Icons.smartphone;
    if (p.contains('windows') || p.contains('linux') || p.contains('desktop')) {
      return Icons.computer;
    }
    return Icons.devices;
  }
}
