import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../providers/navigation_provider.dart';
import '../../data/local/local_index.dart';
import '../../providers/playlists_provider.dart';
import '../../widgets/app_dialog_actions.dart';
import '../../widgets/text_input_dialog.dart';

Future<void> showCreatePlaylistDialog(
    BuildContext context, PlaylistsProvider provider) async {
  final name = await showTextInputDialog(
    context: context,
    title: '新建歌单',
    hintText: '名称',
    confirmLabel: '创建',
  );
  if (name != null && name.isNotEmpty && context.mounted) {
    provider.create(name);
  }
}

Future<void> showRenamePlaylistDialog(
    BuildContext context, PlaylistsProvider provider, PlaylistRow p) async {
  final name = await showTextInputDialog(
    context: context,
    title: '重命名歌单',
    initial: p.name,
    hintText: '名称',
    confirmLabel: '保存',
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
