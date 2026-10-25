import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../platform/app_background.dart';
import '../providers/player_provider.dart';
import '../widgets/app_dialog_actions.dart';

Future<void> confirmExitApp(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('退出软件'),
      content: const Text('确定要退出吗？退出后播放队列会保留，下次启动可继续。'),
      actions: appDialogActions(
        c,
        confirmLabel: '退出',
        destructive: true,
        onCancel: () => Navigator.of(c).pop(false),
        onConfirm: () => Navigator.of(c).pop(true),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await context.read<PlayerProvider>().shutdown();
  await exitAppGracefully();
}
