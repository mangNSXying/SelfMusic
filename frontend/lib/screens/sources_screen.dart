import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';

/// 播放源管理页：服务器模式 + 直连源列表。
///
/// - 点击源卡片直接进入源内浏览（文件夹式导航）。
/// - 卡片右侧「三点」菜单承载 直连/代理 切换、删除等设置。
class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final s in direct.sources) ...[
                _DirectSourceCard(sourceKey: s.key),
                const SizedBox(height: 8),
              ],
              if (direct.sources.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text('尚未添加直连源',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.add_link),
                label: const Text('添加 WebDAV 源'),
                onPressed: () => _showAddDialog(context),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final name = TextEditingController();
    final baseUrl = TextEditingController();
    final username = TextEditingController();
    final password = TextEditingController();
    var mode = SourceMode.direct;
    await showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setDialogState) => AlertDialog(
          title: const Text('添加 WebDAV 源'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '名称（如 NAS）'),
                ),
                TextField(
                  controller: baseUrl,
                  decoration: const InputDecoration(
                    labelText: 'WebDAV 地址',
                    hintText: 'http://192.168.1.10/dav/music',
                  ),
                ),
                TextField(
                  controller: username,
                  decoration: const InputDecoration(labelText: '用户名（可空）'),
                ),
                TextField(
                  controller: password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码（可空）'),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('数据通道',
                      style: Theme.of(c).textTheme.labelLarge),
                ),
                const SizedBox(height: 8),
                SegmentedButton<SourceMode>(
                  segments: const [
                    ButtonSegment(
                      value: SourceMode.direct,
                      icon: Icon(Icons.flash_on),
                      label: Text('直连'),
                    ),
                    ButtonSegment(
                      value: SourceMode.proxy,
                      icon: Icon(Icons.dns_outlined),
                      label: Text('服务端代理'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) =>
                      setDialogState(() => mode = s.first),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(c).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final url = baseUrl.text.trim();
                if (name.text.trim().isEmpty || url.isEmpty) return;
                context.read<DirectSourceManager>().addWebdav(
                      name: name.text.trim(),
                      baseUrl: url,
                      username: username.text.trim(),
                      password: password.text,
                      mode: mode,
                    );
                Navigator.of(c).pop();
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DirectSourceCard extends StatelessWidget {
  final String sourceKey;
  const _DirectSourceCard({required this.sourceKey});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final scheme = Theme.of(context).colorScheme;
    final s = direct.sourceByKey(sourceKey);
    if (s == null) return const SizedBox.shrink();
    final count = direct.countOf(sourceKey);
    final isProxy = direct.isProxy(sourceKey);

    return Card(
      child: ListTile(
        leading: Icon(Icons.cloud, color: scheme.primary),
        title: Text(s.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium),
        subtitle: isProxy
            ? const Text('服务端代理 · 从后端拉取整体库')
            : Text('直连 · 已索引 $count 首'),
        trailing: PopupMenuButton<String>(
          tooltip: '源设置',
          onSelected: (v) => _onMenu(context, v, s, direct),
          itemBuilder: (c) => [
            PopupMenuItem(
              value: 'mode',
              child: Text(isProxy ? '切换为直连' : '切换为服务端代理'),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'delete',
              child: Text('删除源',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          ],
        ),
        onTap: () =>
            context.read<NavigationProvider>().enterSource(sourceKey),
      ),
    );
  }

  void _onMenu(BuildContext context, String action, MusicSource src,
      DirectSourceManager direct) {
    switch (action) {
      case 'mode':
        final next =
            direct.isProxy(src.key) ? SourceMode.direct : SourceMode.proxy;
        direct.setMode(src.key, next);
        break;
      case 'delete':
        _confirmDelete(context, src.key, direct);
        break;
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, String key, DirectSourceManager direct) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除源'),
        content: const Text('确定删除该播放源吗？其本地索引也会一并清除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.of(c).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      direct.removeSource(key);
    }
  }
}