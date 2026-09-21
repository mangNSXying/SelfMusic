import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/local/app_settings.dart';
import '../data/sources/music_source.dart';
import '../providers/direct_source_manager.dart';
import '../providers/navigation_provider.dart';
import '../services/api_client.dart';
import '../widgets/corner_add_button.dart';
import '../widgets/count_header.dart';
import '../widgets/square_card.dart';
import '../widgets/view_mode_toggle.dart';

/// 播放源管理页：直连源（WebDAV / 本地文件夹）列表（支持列表/卡片切换）。
///
/// - 点击源卡片直接进入源内浏览（文件夹式导航）。
/// - 卡片右侧「三点」菜单承载 直连/代理 切换、编辑、删除等设置。
class SourcesScreen extends StatefulWidget {
  const SourcesScreen({super.key});

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  /// 本地覆盖的展示形式（null 时读设置）。
  CollectionViewMode? _mode;

  CollectionViewMode _modeOf(BuildContext c) =>
      _mode ?? c.read<DirectSourceManager>().settings.viewModeSources;

  void _setMode(BuildContext c, CollectionViewMode m) {
    c.read<DirectSourceManager>().settings.viewModeSources = m;
    setState(() => _mode = m);
  }

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final scheme = Theme.of(context).colorScheme;
    final card = _modeOf(context) == CollectionViewMode.card;

    return Stack(
      children: [
        Column(
          children: [
              CountHeader(
                count: direct.sources.length,
                unit: '个播放源',
                trailing: ViewModeToggle(
                  card: card,
                  onChanged: (v) => _setMode(
                      context,
                      v
                          ? CollectionViewMode.card
                          : CollectionViewMode.list),
                ),
              ),
              Expanded(
                child: direct.sources.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text('尚未添加播放源，点右下角「+」添加',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      )
                    : card
                        ? SquareCardGrid(
                            itemCount: direct.sources.length,
                            itemBuilder: (c, i) => _DirectSourceCard(
                                sourceKey: direct.sources[i].key),
                          )
                        : ListView.separated(
                            itemCount: direct.sources.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, indent: 56),
                            itemBuilder: (c, i) =>
                                _DirectSourceTile(sourceKey: direct.sources[i].key),
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
        // 默认 HTTPS：显式 http:// 仅在「允许不安全 HTTP」开启后放行（settings.md §3.3）。
        final err = ApiClient.validateEndpointUrl(url,
            allowHttp: direct.settings.allowInsecureHttp);
        if (err != null) {
          setState(() => _error = err);
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
                  hintText: 'https://192.168.1.10/dav/music',
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

class _DirectSourceTile extends StatelessWidget {
  final String sourceKey;
  const _DirectSourceTile({required this.sourceKey});

  @override
  Widget build(BuildContext context) =>
      _DirectSourceCard(sourceKey: sourceKey, plain: true);
}

class _DirectSourceCard extends StatelessWidget {
  final String sourceKey;

  /// true 时渲染为不走卡片的紧凑列表行。
  final bool plain;
  const _DirectSourceCard({required this.sourceKey, this.plain = false});

  @override
  Widget build(BuildContext context) {
    final direct = context.watch<DirectSourceManager>();
    final s = direct.sourceByKey(sourceKey);
    if (s == null) return const SizedBox.shrink();
    final count = direct.countOf(sourceKey);
    final isProxy = direct.isProxy(sourceKey);
    final isLocal = s.kind == SourceKind.local;

    final tile = ListTile(
      leading: Icon(isLocal ? Icons.folder : Icons.cloud,
          color: Theme.of(context).colorScheme.primary),
      title: Text(s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium),
      subtitle: isProxy
          ? const Text('服务端代理 · 从后端拉取整体库')
          : Text('直连${isLocal ? ' · 本地文件夹' : ''} · 已索引 $count 首'),
      trailing: _SourceMenu(
          sourceKey: sourceKey, isProxy: isProxy, source: s, direct: direct),
      onTap: () => context.read<NavigationProvider>().enterSource(sourceKey),
    );
    if (plain) return tile;
    // 卡片形态：与专辑/歌手共用方形卡片（SquareCard），菜单叠右上角。
    return SquareCard(
      title: s.name,
      subtitle: isProxy
          ? '服务端代理 · 从后端拉取整体库'
          : '直连${isLocal ? ' · 本地文件夹' : ''} · 已索引 $count 首',
      fallbackIcon: isLocal ? Icons.folder : Icons.cloud,
      onTap: () => context.read<NavigationProvider>().enterSource(sourceKey),
      cornerAction: _SourceMenu(
          sourceKey: sourceKey, isProxy: isProxy, source: s, direct: direct),
    );
  }
}

/// 播放源设置菜单（列表行 trailing / 方形卡片右上角共用）。
class _SourceMenu extends StatelessWidget {
  final String sourceKey;
  final bool isProxy;
  final MusicSource source;
  final DirectSourceManager direct;
  const _SourceMenu(
      {required this.sourceKey,
      required this.isProxy,
      required this.source,
      required this.direct});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: '源设置',
      iconSize: 20,
      padding: EdgeInsets.zero,
      onSelected: (v) {
        switch (v) {
          case 'mode':
            direct.setMode(sourceKey,
                isProxy ? SourceMode.direct : SourceMode.proxy);
          case 'edit':
            showDialog<void>(
                context: context,
                builder: (_) => _SourceDialog(editKey: sourceKey));
          case 'delete':
            _confirmDelete(context, sourceKey, direct);
        }
      },
      itemBuilder: (c) => [
        PopupMenuItem(
          value: 'mode',
          child: Text(isProxy ? '切换为直连' : '切换为服务端代理'),
        ),
        const PopupMenuItem(value: 'edit', child: Text('编辑')),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: Text('删除源', style: TextStyle(color: Colors.redAccent)),
        ),
      ],
    );
  }
}

/// 删除源二次确认（列表/卡片共用）。
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
