import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../platform/harmonyos/ohos_global_hotkeys.dart';
import '../shortcuts/shortcut_models.dart';
import '../shortcuts/shortcut_settings.dart';
import 'app_dialog_actions.dart';

class ShortcutRecorderDialog extends StatefulWidget {
  const ShortcutRecorderDialog({
    super.key,
    required this.action,
    required this.scope,
    required this.initial,
  });

  final ShortcutAction action;
  final ShortcutScope scope;
  final ShortcutBinding? initial;

  @override
  State<ShortcutRecorderDialog> createState() => _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState extends State<ShortcutRecorderDialog> {
  final FocusNode _focus = FocusNode(debugLabel: 'shortcutRecorder');
  late final ShortcutSettings _settings;
  ShortcutBinding? _binding;
  List<ShortcutConflict> _conflicts = const [];
  String? _error;
  bool _recordingStarted = false;

  @override
  void initState() {
    super.initState();
    _settings = context.read<ShortcutSettings>();
    _binding = widget.initial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _recordingStarted = true;
      // 暂停系统全局热键，避免录制时旧组合先触发或被系统吞掉。
      _settings.beginRecording();
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    if (_recordingStarted) {
      _recordingStarted = false;
      // dispose 期间同步 notify 可能触发正在拆树的页面重建，延后一拍。
      scheduleMicrotask(_settings.endRecording);
    }
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_isModifierKey(key)) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final control = keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    final alt = keyboard.isAltPressed;
    final meta = keyboard.isMetaPressed;
    if (key == LogicalKeyboardKey.escape &&
        !control &&
        !shift &&
        !alt &&
        !meta) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    final binding = ShortcutBinding(
      keyId: key.keyId,
      control: control,
      shift: shift,
      alt: alt,
      meta: meta,
    );
    var error = _settings.validateBinding(widget.scope, binding);
    if (error == null &&
        widget.scope == ShortcutScope.global &&
        _isOhos &&
        ohosHotkeySpecFor(binding) == null) {
      error = '鸿蒙端不支持该按键作为全局快捷键';
    }
    final conflicts = error == null
        ? _settings.conflictsFor(widget.action, widget.scope, binding)
        : const <ShortcutConflict>[];
    setState(() {
      _binding = binding;
      _error = error;
      _conflicts = conflicts;
    });
    return KeyEventResult.handled;
  }

  bool get _isOhos => Platform.operatingSystem == 'ohos';

  static bool _isModifierKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.control ||
      key == LogicalKeyboardKey.controlLeft ||
      key == LogicalKeyboardKey.controlRight ||
      key == LogicalKeyboardKey.shift ||
      key == LogicalKeyboardKey.shiftLeft ||
      key == LogicalKeyboardKey.shiftRight ||
      key == LogicalKeyboardKey.alt ||
      key == LogicalKeyboardKey.altLeft ||
      key == LogicalKeyboardKey.altRight ||
      key == LogicalKeyboardKey.meta ||
      key == LogicalKeyboardKey.metaLeft ||
      key == LogicalKeyboardKey.metaRight ||
      key == LogicalKeyboardKey.capsLock ||
      key == LogicalKeyboardKey.fn;

  String? get _conflictText {
    if (_conflicts.isEmpty) return null;
    final owners = _conflicts
        .map((c) => '「${c.action.label}」（${c.scope.label}）')
        .join('、');
    return '该组合已用于 $owners，保存后会清除原绑定。';
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ShortcutSettings>();
    final isMac = settings.primaryIsMeta;
    final preview = _binding?.describe(isMac: isMac) ?? '按下新的快捷键';
    final conflictText = _conflictText;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: AlertDialog(
        title: Text('设置「${widget.action.label}」'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  preview,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (conflictText != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          conflictText,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.tertiary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                widget.scope == ShortcutScope.global
                    ? _isOhos
                        ? '全局快捷键在应用后台也会生效，至少需要一个 Ctrl 或 Alt 修饰键；'
                            '鸿蒙端不支持 Meta/Command。'
                        : '全局快捷键在应用后台也会生效，至少需要一个 '
                            'Ctrl/Alt/Meta 修饰键；F1-F24 与媒体键可单独使用。'
                    : '按下组合键即可录制（F1-F24、媒体键也可用）；Esc 取消。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: appDialogActions(
          context,
          onCancel: () => Navigator.of(context).pop(),
          onConfirm: _binding == null || _error != null
              ? () {}
              : () => Navigator.of(context).pop(_binding),
          confirmEnabled: _binding != null && _error == null,
          confirmLabel: _conflicts.isEmpty ? '确定' : '覆盖保存',
        ),
      ),
    );
  }
}
