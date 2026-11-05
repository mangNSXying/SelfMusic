import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../providers/navigation_provider.dart';
import '../../data/local/local_index.dart';
import '../../providers/playlists_provider.dart';
import '../../widgets/app_dialog_actions.dart';

Future<void> showCreatePlaylistDialog(
    BuildContext context, PlaylistsProvider provider) async {
  final ctrl = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('新建歌单'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: '名称'),
      ),
      actions: appDialogActions(
        c,
        confirmLabel: '创建',
        onCancel: () => Navigator.of(c).pop(),
        onConfirm: () {
          final t = ctrl.text.trim();
          if (t.isEmpty) return;
          Navigator.of(c).pop(t);
        },
      ),
    ),
  );
  if (name != null && name.isNotEmpty && context.mounted) {
    provider.create(name);
  }
}

Future<void> showRenamePlaylistDialog(
    BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
  final ctrl = TextEditingController(text: p.name);
  final name = await showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('重命名歌单'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: '名称'),
      ),
      actions: appDialogActions(
        c,
        confirmLabel: '保存',
        onCancel: () => Navigator.of(c).pop(),
        onConfirm: () {
          final t = ctrl.text.trim();
          if (t.isEmpty) return;
          Navigator.of(c).pop(t);
        },
      ),
    ),
  );
  if (name != null && name.isNotEmpty) provider.rename(p.id, name);
}

Future<void> confirmDeletePlaylist(
    BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('删除歌单'),
      content: Text('确定删除「${p.name}」？其中歌曲不会被删除，仅移除歌单。'),
      actions: appDialogActions(
        c,
        confirmLabel: '删除',
        destructive: true,
        onCancel: () => Navigator.of(c).pop(false),
        onConfirm: () => Navigator.of(c).pop(true),
      ),
    ),
  );
  if (ok == true && context.mounted) {
    final nav = context.read<NavigationProvider>();
    if (nav.browsingPlaylistId == p.id) nav.exitPlaylist();
    provider.delete(p.id);
  }
}
