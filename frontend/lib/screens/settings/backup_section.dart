import 'dart:io';

import 'package:file_selector/file_selector.dart';

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../data/local/backup_service.dart';
import '../../providers/direct_source_manager.dart';
import '../../providers/player_provider.dart';
import '../../providers/playlists_provider.dart';
import '../../services/server_settings.dart';
import '../../shortcuts/shortcut_settings.dart';
import '../../theme/theme_provider.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/row_action_button.dart';

/// 「备份与迁移」入口：文件导出/导入与本机备份合并为一个弹窗。
class BackupMigrationTile extends StatelessWidget {
  const BackupMigrationTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.backup_outlined),
      title: const Text('备份与迁移'),
      subtitle: const Text('导出 / 导入设置与歌单 · 选择本机备份恢复'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => const BackupMigrationDialog(),
      ),
    );
  }
}

/// 备份与迁移弹窗（settings.md §3.5）：设置/歌单导出导入（不含令牌与源凭据），
/// 并可直接点选本机备份恢复。
class BackupMigrationDialog extends StatefulWidget {
  const BackupMigrationDialog();
  @override
  State<BackupMigrationDialog> createState() => _BackupMigrationDialogState();
}

class _BackupMigrationDialogState extends State<BackupMigrationDialog> {
  List<File> _backups = [];

  @override
  void initState() {
    super.initState();
    _backups = _service(context.read<DirectSourceManager>()).listBackups();
  }

  BackupService _service(DirectSourceManager direct) => BackupService(
        index: direct.index,
        server: context.read<ServerSettings>(),
        theme: context.read<ThemeProvider>(),
      );

  void _refresh() {
    setState(() {
      final direct = context.read<DirectSourceManager>();
      _backups = _service(direct).listBackups();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('备份与迁移'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('导出设置'),
                  onPressed: _doExportSettings,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.file_upload_outlined, size: 18),
                  label: const Text('导入设置'),
                  onPressed: () => _pickAndImport(BackupKind.settings),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.queue_music, size: 18),
                  label: const Text('导出歌单'),
                  onPressed: _doExportPlaylists,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: const Text('导入歌单'),
                  onPressed: () => _pickAndImport(BackupKind.playlists),
                ),
              ],
            ),
            const Divider(height: 24),
            Text('本机备份',
                style:
                    TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('点选备份恢复对应的设置或歌单',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurface.withValues(alpha: 0.6))),
            const SizedBox(height: 4),
            Flexible(
              child: _backups.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('暂无备份。点击上方「导出」创建。'),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [for (final f in _backups) _backupTile(f)],
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [appDialogCloseAction(context, label: '关闭')],
    );
  }

  Widget _backupTile(File f) {
    final name = f.path.split('/').last;
    final kind = BackupService.kindOf(f);
    final kindLabel = switch (kind) {
      BackupKind.settings => '设置',
      BackupKind.playlists => '歌单',
      BackupKind.full => '设置 + 歌单',
    };
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(Icons.description_outlined),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$kindLabel · ${_sizeLabel(f.lengthSync())}'),
      onTap: () => _confirmImport(f, name, kind),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RowActionIconButton(
            icon: Icons.restore,
            tooltip: '导入此备份',
            onPressed: () => _confirmImport(f, name, kind),
          ),
          RowActionIconButton(
            icon: Icons.delete_outline,
            tooltip: '删除备份',
            onPressed: () => _doDelete(f),
          ),
        ],
      ),
    );
  }

  Future<void> _doExportSettings() async {
    final direct = context.read<DirectSourceManager>();
    final file = await _service(direct).exportSettings();
    if (!mounted) return;
    _refresh();
    AppToast.show('已导出：${file.path.split('/').last}（不含令牌与源凭据）', isError: false);
  }

  Future<void> _doExportPlaylists() async {
    final direct = context.read<DirectSourceManager>();
    final file = await _service(direct).exportPlaylists();
    if (!mounted) return;
    _refresh();
    AppToast.show('已导出：${file.path.split('/').last}', isError: false);
  }

  /// 文件选择器导入设置/歌单。
  Future<void> _pickAndImport(BackupKind kind) async {
    const groups = [
      XTypeGroup(
          label: 'JSON 备份',
          extensions: ['json'],
          mimeTypes: ['application/json']),
      XTypeGroup(label: '所有文件', mimeTypes: ['*/*']),
    ];
    final XFile? picked;
    try {
      picked = await openFile(acceptedTypeGroups: groups);
    } catch (e) {
      if (mounted) return _toast('打开文件失败：$e', isError: true);
      return;
    }
    if (picked == null) return;
    if (!mounted) return;
    final f = File(picked.path);
    if (!f.existsSync()) {
      _toast('所选文件不存在：${picked.path}', isError: true);
      return;
    }
    final direct = context.read<DirectSourceManager>();
    final service = _service(direct);
    try {
      final summary = kind == BackupKind.settings
          ? await service.importSettings(f)
          : await service.importPlaylists(f);
      if (kind == BackupKind.settings) {
        if (!mounted) return;
        context.read<ShortcutSettings>().reload();
        context.read<PlayerProvider>().reloadEqualizerSettings();
        // 导入的 zh_variant 需要立即重载词库并刷新展示（否则要重启才生效）。
        await direct.applyZhVariantSetting();
        if (mounted) context.read<PlayerProvider>().refreshSystemMedia();
      }
      if (kind == BackupKind.playlists) {
        if (!mounted) return;
        context.read<PlaylistsProvider>().refresh();
      }
      if (!mounted) return;
      _toast(summary);
    } catch (e) {
      if (!mounted) return;
      _toast('导入失败：$e', isError: true);
    }
  }

  void _toast(String msg, {bool isError = false}) {
    AppToast.show(msg, isError: isError);
  }

  Future<void> _confirmImport(File f, String name, BackupKind kind) async {
    final scope = switch (kind) {
      BackupKind.settings => '将覆盖当前设置（含服务端地址与主题）',
      BackupKind.playlists => '将以本机歌单重建',
      BackupKind.full => '将覆盖当前设置并重建歌单',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导入备份'),
        content: Text('$scope，是否继续？\n\n$name'),
        actions: appDialogActions(
          c,
          confirmLabel: '导入',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final direct = context.read<DirectSourceManager>();
    final service = _service(direct);
    try {
      final summaries = <String>[];
      if (kind == BackupKind.settings || kind == BackupKind.full) {
        summaries.add(await service.importSettings(f));
      }
      if (kind == BackupKind.playlists || kind == BackupKind.full) {
        summaries.add(await service.importPlaylists(f));
      }
      if (!mounted) return;
      if (kind != BackupKind.playlists) {
        context.read<ShortcutSettings>().reload();
        context.read<PlayerProvider>().reloadEqualizerSettings();
        await direct.applyZhVariantSetting();
        if (!mounted) return;
        context.read<PlayerProvider>().refreshSystemMedia();
      }
      context.read<PlaylistsProvider>().refresh();
      AppToast.show(summaries.join('；'), isError: false);
    } catch (e) {
      if (!mounted) return;
      AppToast.error(e, '导入失败');
    }
  }

  Future<void> _doDelete(File f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除备份'),
        content: Text('确定删除 ${f.path.split('/').last}？'),
        actions: appDialogActions(
          c,
          confirmLabel: '删除',
          destructive: true,
          onCancel: () => Navigator.of(c).pop(false),
          onConfirm: () => Navigator.of(c).pop(true),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      f.deleteSync();
    } catch (_) {}
    _refresh();
  }

  static String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
