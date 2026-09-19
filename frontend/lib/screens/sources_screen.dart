import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/sources/music_source.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../widgets/corner_add_button.dart';

/// 播放源管理页：直连源（WebDAV / 本地文件夹）列表。
///
/// - 点击源卡片直接进入源内浏览（文件夹式导航）。
/// - 卡片右侧「三点」菜单承载 直连/代理 切换、编辑、删除等设置。
class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final scheme = Theme.of(context).colorScheme;

    return Stack(
      children: [
        Column(
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
                        child: Text('尚未添加播放源，点右下角「+」添加',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 16,
            child: CornerAddButton(
              tooltip: '添加播放源',
              onPressed: () => showDialog<void>(
                  context: context, builder: (_) => const _SourceDialog()),
            ),
          ),
        ],
      );
  }
}

/// 新增/编辑播放源弹窗：按源类型切换字段（WebDAV / 本地文件夹）。
class _SourceDialog extends StatefulWidget {
  final String? editKey;
  const _SourceDialog({this.editKey});

  @override
  State<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<_SourceDialog> {
  late final TextEditingController _name;
  late final TextEditingController _path;
  late final TextEditingController _baseUrl;
  late final TextEditingController _username;
  late final TextEditingController _password;
  SourceKind _kind = SourceKind.webdav;
  SourceMode _mode = SourceMode.direct;
  String? _error;

  bool get _isEdit => widget.editKey != null;

  @override
  void initState() {
    super.initState();
    Map<String, dynamic> cfg = const {};
    if (widget.editKey != null) {
      cfg = context.read<DirectSourceManager>().editableConfig(widget.editKey!);
      _kind = (cfg['kind'] as String?) == 'local'
          ? SourceKind.local
          : SourceKind.webdav;
      _mode = (cfg['mode'] as String?) == 'proxy'
          ? SourceMode.proxy
          : SourceMode.direct;
    }
    _name = TextEditingController(text: cfg['name'] as String? ?? '');
    _path = TextEditingController(text: cfg['path'] as String? ?? '');
    _baseUrl = TextEditingController(text: cfg['baseUrl'] as String? ?? '');
    _username = TextEditingController(text: cfg['username'] as String? ?? '');
    _password = TextEditingController(text: cfg['password'] as String? ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _path.dispose();
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory() async {
    final dir = await getDirectoryPath(confirmButtonText: '选择');
    if (dir != null && mounted) {
      setState(() => _path.text = dir);
    }
  }

  Future<void> _submit() async {
    final direct = context.read<DirectSourceManager>();
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写名称');
      return;
    }
    try {
      if (_kind == SourceKind.local) {
        final path = _path.text.trim();
        if (path.isEmpty) {
          setState(() => _error = '请选择或填写本地目录');
          return;
        }
        if (_isEdit) {
          await direct.updateSource(widget.editKey!,
              name: name, path: path, mode: _mode);
        } else {
          await direct.addLocal(name: name, path: path, mode: _mode);
        }
      } else {
        final url = _baseUrl.text.trim();
        if (url.isEmpty) {
          setState(() => _error = '请填写 WebDAV 地址');
          return;
        }
        if (_isEdit) {
          await direct.updateSource(widget.editKey!,
              name: name,
              baseUrl: url,
              username: _username.text.trim(),
              password: _password.text,
              mode: _mode);
        } else {
          await direct.addWebdav(
              name: name,
              baseUrl: url,
              username: _username.text.trim(),
              password: _password.text,
              mode: _mode);
        }
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst(
          RegExp(r'^(Bad state: |StateError: )'), ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLocal = _kind == SourceKind.local;
    return AlertDialog(
      title: Text(_isEdit ? '编辑播放源' : '添加播放源'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_isEdit) ...[
              SegmentedButton<SourceKind>(
                segments: const [
                  ButtonSegment(
                    value: SourceKind.webdav,
                    icon: Icon(Icons.cloud_outlined),
                    label: Text('WebDAV'),
                  ),
                  ButtonSegment(
                    value: SourceKind.local,
                    icon: Icon(Icons.folder_outlined),
                    label: Text('本地文件夹'),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (s) =>
                    setState(() => _kind = s.first),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '名称（如 NAS / 本地音乐）'),
            ),
            if (isLocal) ...[
              TextField(
                controller: _path,
                decoration: InputDecoration(
                  labelText: '本地目录',
                  hintText: '/home/user/Music',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.folder_open),
                    tooltip: '选择目录',
                    onPressed: _pickDirectory,
                  ),
                ),
              ),
            ] else ...[
              TextField(
                controller: _baseUrl,
                decoration: const InputDecoration(
                  labelText: 'WebDAV 地址',
                  hintText: 'http://192.168.1.10/dav/music',
                ),
              ),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名（可空）'),
              ),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '密码（可空）'),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('数据通道', style: Theme.of(context).textTheme.labelLarge),
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
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          onPressed: _submit,
          child: Text(_isEdit ? '保存' : '添加'),
        ),
      ],
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
    final isLocal = s.kind == SourceKind.local;

    return Card(
      child: ListTile(
        leading: Icon(isLocal ? Icons.folder : Icons.cloud, color: scheme.primary),
        title: Text(s.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium),
        subtitle: isProxy
            ? const Text('服务端代理 · 从后端拉取整体库')
            : Text(
                '直连${isLocal ? ' · 本地文件夹' : ''} · 已索引 $count 首'),
        trailing: PopupMenuButton<String>(
          tooltip: '源设置',
          onSelected: (v) => _onMenu(context, v, s, direct),
          itemBuilder: (c) => [
            PopupMenuItem(
              value: 'mode',
              child: Text(isProxy ? '切换为直连' : '切换为服务端代理'),
            ),
            const PopupMenuItem(value: 'edit', child: Text('编辑')),
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
      case 'edit':
        showDialog<void>(
            context: context,
            builder: (_) => _SourceDialog(editKey: src.key));
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
