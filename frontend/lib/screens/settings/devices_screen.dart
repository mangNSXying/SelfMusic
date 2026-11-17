import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_client.dart';
import '../../theme/app_metrics.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/confirm_dialog.dart';
import '../../widgets/context_menu.dart';
import '../../widgets/row_action_button.dart';
import '../../widgets/text_input_dialog.dart';

/// 已配对设备管理（阶段5）：按状态分组（本机 / 正常设备 / 已吊销）的卡片列表。
///
/// 正常设备可改名、吊销；已吊销设备可永久删除（单条或整组清理）。
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  String? _selfClientId;
  bool _loading = true;
  bool _purging = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool showLoading = true}) async {
    final api = context.read<ApiClient>();
    if (showLoading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
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
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  bool _isSelf(Map<String, dynamic> d) =>
      (d['clientId'] as String?) == _selfClientId;

  /// 分组：本机 / 正常设备 / 已吊销；组内本机优先，其余按上次活跃降序。
  List<Map<String, dynamic>> _group({
    required bool revoked,
    bool self = false,
  }) {
    final list = _devices.where((d) {
      if ((d['revoked'] == true) != revoked) return false;
      return revoked || _isSelf(d) == self;
    }).toList();
    list.sort((a, b) {
      final aSelf = _isSelf(a);
      final bSelf = _isSelf(b);
      if (aSelf != bSelf) return aSelf ? -1 : 1;
      final aSeen = a['lastSeenAt'] as String?;
      final bSeen = b['lastSeenAt'] as String?;
      if (aSeen == null || aSeen.isEmpty) {
        return (bSeen == null || bSeen.isEmpty) ? 0 : 1;
      }
      if (bSeen == null || bSeen.isEmpty) return -1;
      return bSeen.compareTo(aSeen);
    });
    return list;
  }

  Future<void> _rename(Map<String, dynamic> d) async {
    final name = await showTextInputDialog(
      context: context,
      title: '设备改名',
      initial: (d['name'] as String?) ?? '',
      labelText: '设备名',
      confirmLabel: '保存',
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await context
          .read<ApiClient>()
          .renameDevice((d['id'] as num).toInt(), name);
      await _load(showLoading: false);
    } catch (e) {
      if (!mounted) return;
      AppToast.show('改名失败：$e');
    }
  }

  Future<void> _revoke(Map<String, dynamic> d) async {
    final isSelf = _isSelf(d);
    final ok = await showConfirmDialog(
      context,
      title: '吊销设备？',
      content: '「${_deviceName(d)}」的令牌将即刻失效。'
          '${isSelf ? '这是本机，吊销后需重新配对。' : ''}',
      confirmLabel: '吊销',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await context.read<ApiClient>().revokeDevice((d['id'] as num).toInt());
      await _load(showLoading: false);
    } catch (e) {
      if (!mounted) return;
      AppToast.show('吊销失败：$e');
    }
  }

  Future<void> _purge(Map<String, dynamic> d) async {
    final ok = await showConfirmDialog(
      context,
      title: '永久删除设备？',
      content: '「${_deviceName(d)}」的记录将从服务端移除，不可恢复；'
          '该设备令牌已失效，不影响其它设备。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    try {
      await context.read<ApiClient>().purgeDevice((d['id'] as num).toInt());
      if (!mounted) return;
      AppToast.show('已删除设备', isError: false);
      await _load(showLoading: false);
    } catch (e) {
      if (!mounted) return;
      AppToast.show('删除失败：$e');
    }
  }

  Future<void> _purgeAllRevoked() async {
    final revoked = _group(revoked: true);
    if (revoked.isEmpty || _purging) return;
    final ok = await showConfirmDialog(
      context,
      title: '清空已吊销设备？',
      content: '将永久删除 ${revoked.length} 台已吊销设备的记录，不可恢复；'
          '其它设备不受影响。',
      confirmLabel: '全部删除',
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _purging = true);
    final api = context.read<ApiClient>();
    var success = 0;
    var failed = 0;
    for (final d in revoked) {
      try {
        await api.purgeDevice((d['id'] as num).toInt());
        success++;
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() => _purging = false);
    AppToast.show(
      failed == 0 ? '已删除 $success 台设备' : '已删除 $success 台，$failed 台失败',
      isError: failed > 0,
    );
    await _load(showLoading: false);
  }

  String _deviceName(Map<String, dynamic> d) {
    final name = (d['name'] as String?)?.trim() ?? '';
    return name.isEmpty ? '未知设备' : name;
  }

  static String _shortTime(String iso) {
    // 2026-09-20T12:34:56 → 2026-09-20 12:34
    final s = iso.replaceFirst('T', ' ');
    return s.length > 16 ? s.substring(0, 16) : s;
  }

  String _meta(Map<String, dynamic> d) {
    final lastSeen = d['lastSeenAt'] as String?;
    if (lastSeen != null && lastSeen.isNotEmpty) {
      return '上次活跃 ${_shortTime(lastSeen)}';
    }
    final pairedAt = d['pairedAt'] as String?;
    if (pairedAt != null && pairedAt.isNotEmpty) {
      return '配对于 ${_shortTime(pairedAt)}';
    }
    return '未活跃';
  }

  static String _platformLabel(String? platform) {
    final p = (platform ?? '').toLowerCase();
    if (p.isEmpty) return '未知平台';
    if (p.contains('android')) return 'Android';
    if (p.contains('ios') || p.contains('iphone') || p.contains('ipad')) {
      return 'iOS';
    }
    if (p.contains('mac')) return 'macOS';
    if (p.contains('windows')) return 'Windows';
    if (p.contains('linux')) return 'Linux';
    if (p.contains('ohos') || p.contains('harmony') || p.contains('hongmeng')) {
      return '鸿蒙';
    }
    return platform!;
  }

  static IconData _iconFor(String? platform) {
    final p = (platform ?? '').toLowerCase();
    if (p.contains('android')) return Icons.smartphone;
    if (p.contains('ios') || p.contains('iphone') || p.contains('ipad')) {
      return Icons.phone_iphone;
    }
    if (p.contains('mac')) return Icons.laptop_mac;
    if (p.contains('windows')) return Icons.desktop_windows;
    if (p.contains('linux')) return Icons.computer;
    if (p.contains('ohos') || p.contains('harmony') || p.contains('hongmeng')) {
      return Icons.phone_android;
    }
    return Icons.devices_other;
  }

  static List<PopupMenuEntry<String>> _menuItems({required bool revoked}) {
    if (revoked) {
      return const [PopupMenuItem(value: 'purge', child: Text('删除'))];
    }
    return const [
      PopupMenuItem(value: 'rename', child: Text('改名')),
      PopupMenuItem(value: 'revoke', child: Text('吊销')),
    ];
  }

  void _handleMenu(Map<String, dynamic> d, String value) {
    if (value == 'rename') {
      _rename(d);
    } else if (value == 'revoke') {
      _revoke(d);
    } else if (value == 'purge') {
      _purge(d);
    }
  }

  /// 右键：在指针位置弹出与三点按钮相同的菜单。
  Future<void> _openMenuAt(
      Map<String, dynamic> d, Offset globalPosition) async {
    final picked = await showContextMenuAt<String>(
      context,
      globalPosition,
      items: _menuItems(revoked: d['revoked'] == true),
    );
    if (picked != null && mounted) _handleMenu(d, picked);
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
            onPressed: _loading || _purging ? null : _load,
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_devices.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.devices_other,
                size: 40,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            const Text('暂无已配对设备'),
          ],
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final selfDevices = _group(revoked: false, self: true);
    final activeDevices = _group(revoked: false);
    final revokedDevices = _group(revoked: true);

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (selfDevices.isNotEmpty)
          _Group(
            title: '本机',
            devices: selfDevices,
            color: scheme.primary,
            cardBuilder: _buildCard,
            gridBuilder: _buildGrid,
          ),
        if (activeDevices.isNotEmpty)
          _Group(
            title: '正常设备',
            devices: activeDevices,
            color: scheme.primary,
            cardBuilder: _buildCard,
            gridBuilder: _buildGrid,
          ),
        if (revokedDevices.isNotEmpty)
          _Group(
            title: '已吊销',
            devices: revokedDevices,
            color: scheme.error,
            trailing: RowActionTextButton(
              label: _purging ? '清理中…' : '清空',
              color: scheme.error,
              onPressed: _purging ? null : _purgeAllRevoked,
            ),
            cardBuilder: _buildCard,
            gridBuilder: _buildGrid,
          ),
      ],
    );
  }

  Widget _buildGrid(List<Map<String, dynamic>> devices,
      Widget Function(Map<String, dynamic>) cardBuilder) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth < 600
            ? 1
            : constraints.maxWidth < 900
                ? 2
                : constraints.maxWidth < 1300
                    ? 3
                    : 4;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: devices.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              mainAxisExtent: 132,
            ),
            itemBuilder: (_, i) => cardBuilder(devices[i]),
          ),
        );
      },
    );
  }

  Widget _buildCard(Map<String, dynamic> d) {
    final scheme = Theme.of(context).colorScheme;
    final revoked = d['revoked'] == true;
    final isSelf = _isSelf(d);
    final foreground =
        revoked ? scheme.onSurface.withValues(alpha: 0.55) : scheme.onSurface;
    final accent = revoked ? scheme.onSurfaceVariant : scheme.primary;
    final meta = [
      _platformLabel(d['platform'] as String?),
      _meta(d),
    ].join(' · ');

    return GestureDetector(
      onSecondaryTapDown: (details) => _openMenuAt(d, details.globalPosition),
      child: Card(
        key: ValueKey('deviceCard-${d['id']}'),
        margin: EdgeInsets.zero,
        elevation: 0,
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kButtonRadius),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(_iconFor(d['platform'] as String?),
                    size: 22, color: accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _deviceName(d),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                Theme.of(context).textTheme.bodyLarge?.copyWith(
                                      color: foreground,
                                      fontWeight: FontWeight.w600,
                                    ),
                          ),
                        ),
                        if (isSelf) _Badge('本机', scheme.primary),
                        if (revoked) _Badge('已吊销', scheme.error),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: ValueKey('deviceMenu-${d['id']}'),
                tooltip: '更多操作',
                icon: Icon(Icons.more_vert,
                    size: 20, color: scheme.onSurfaceVariant),
                iconSize: 20,
                padding: EdgeInsets.zero,
                splashRadius: 18,
                onSelected: (v) => _handleMenu(d, v),
                itemBuilder: (_) => _menuItems(revoked: revoked),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单个状态分组：组头（标题 + 数量 + 可选动作）+ 自适应卡片网格。
class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.devices,
    required this.color,
    required this.cardBuilder,
    required this.gridBuilder,
    this.trailing,
  });

  final String title;
  final List<Map<String, dynamic>> devices;
  final Color color;
  final Widget? trailing;
  final Widget Function(Map<String, dynamic>) cardBuilder;
  final Widget Function(
    List<Map<String, dynamic>>,
    Widget Function(Map<String, dynamic>),
  ) gridBuilder;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${devices.length}',
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
        ),
        gridBuilder(devices, cardBuilder),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
