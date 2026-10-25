import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

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
  ShortcutBinding? _binding;
  String? _error;

  @override
  void initState() {
    super.initState();
    _binding = widget.initial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
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
    final settings = context.read<ShortcutSettings>();
    final error = ShortcutSettings.findConflict(
      action: widget.action,
      scope: widget.scope,
      binding: binding,
      window: settings.windowBindings,
      global: settings.globalBindings,
    );
    setState(() {
      _binding = binding;
      _error = error;
    });
    return KeyEventResult.handled;
  }

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

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ShortcutSettings>();
    final isMac = settings.primaryIsMeta;
    final preview = _binding?.describe(isMac: isMac) ?? '按下新的快捷键';
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
              const SizedBox(height: 8),
              Text(
                widget.scope == ShortcutScope.global
                    ? '全局快捷键在应用后台也会生效，至少需要一个 Ctrl/Alt/Meta 修饰键。'
                    : '按下组合键即可录制；Esc 取消。',
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
          confirmLabel: '确定',
        ),
      ),
    );
  }
}
