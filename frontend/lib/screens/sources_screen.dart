import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/direct_source_manager.dart';
import 'direct_browse_screen.dart';

/// 播放源管理页（阶段 3）：服务器源 + 直连源列表，支持添加/删除/浏览 WebDAV 源。
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
              _ServerSourceCard(active: direct.activeKey == null),
              const SizedBox(height: 8),
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
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('添加 WebDAV 直连源'),
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
                  );
              Navigator.of(c).pop();
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}

class _ServerSourceCard extends StatelessWidget {
  final bool active;
  const _ServerSourceCard({required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final direct = context.read<DirectSourceManager>();
    return Card(
      child: ListTile(
        leading: Icon(Icons.dns, color: scheme.primary),
        title: const Text('服务器模式（SelfMusic 后端）'),
        subtitle: const Text('同步/转码等增强能力，默认激活'),
        trailing: active
            ? const Chip(label: Text('当前'), visualDensity: VisualDensity.compact)
            : TextButton(
                onPressed: () => direct.setActive('server'),
                child: const Text('设为当前'),
              ),
        onTap: () => direct.setActive('server'),
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
    final active = direct.activeKey == sourceKey;

    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.cloud, color: scheme.primary),
            title: Text(s.key),
            subtitle: Text('已索引 $count 首'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => direct.removeSource(sourceKey),
              tooltip: '删除该源',
            ),
            onTap: () => direct.setActive(sourceKey),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Row(
              children: [
                if (!active)
                  TextButton(
                    onPressed: () => direct.setActive(sourceKey),
                    child: const Text('设为当前'),
                  ),
                const Spacer(),
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => DirectBrowseScreen(sourceKey: sourceKey),
                    ),
                  ),
                  child: const Text('浏览'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
