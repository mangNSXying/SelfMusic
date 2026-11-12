import 'package:flutter/cupertino.dart' show CupertinoPicker;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_dialog_actions.dart';

/// 滚轮的一列：只负责展示文案，值由 [showWheelPickerDialog] 的 resultOf 反算。
class WheelColumn {
  const WheelColumn({required this.labels});

  final List<String> labels;
}

/// 通用滚轮选择弹窗：支持多列、校验与键盘操作。
///
/// 键盘：↑/↓ 逐项，PgUp/PgDn ±10，Home/End 首尾；多列时 ←/→ 切换列，
/// Enter 确认，Esc 取消。
Future<T?> showWheelPickerDialog<T>({
  required BuildContext context,
  required String title,
  required List<WheelColumn> columns,
  required List<int> initialIndices,
  required T Function(List<int> indices) resultOf,
  bool Function(T value)? valid,
  String? hint,
}) {
  assert(columns.isNotEmpty);
  assert(columns.length == initialIndices.length);
  for (final column in columns) {
    assert(column.labels.isNotEmpty);
  }
  return showDialog<T>(
    context: context,
    builder: (c) => _WheelPickerDialog<T>(
      title: title,
      columns: columns,
      initialIndices: initialIndices,
      resultOf: resultOf,
      valid: valid,
      hint: hint,
    ),
  );
}

/// 单列整数滚轮。
///
/// 会自动把 [value] 并入候选列表，兼容旧数据中不在档位内的值；未改动直接
/// 确认时原值保留。
Future<int?> showNumberWheelDialog({
  required BuildContext context,
  required String title,
  required int value,
  required List<int> values,
  required String Function(int value) labelOf,
  String? hint,
}) {
  assert(values.isNotEmpty);
  final merged = <int>{...values, value}.toList()..sort();
  return showWheelPickerDialog<int>(
    context: context,
    title: title,
    columns: [
      WheelColumn(labels: [for (final v in merged) labelOf(v)]),
    ],
    initialIndices: [merged.indexOf(value)],
    resultOf: (indices) => merged[indices.first],
    hint: hint,
  );
}

/// [min, max] 闭区间、步进 [step] 的整数序列（含两端）。
List<int> wheelRange(int min, int max, int step) {
  assert(step > 0);
  return [for (var v = min; v <= max; v += step) v];
}

class _WheelPickerDialog<T> extends StatefulWidget {
  const _WheelPickerDialog({
    required this.title,
    required this.columns,
    required this.initialIndices,
    required this.resultOf,
    required this.valid,
    required this.hint,
  });

  final String title;
  final List<WheelColumn> columns;
  final List<int> initialIndices;
  final T Function(List<int> indices) resultOf;
  final bool Function(T value)? valid;
  final String? hint;

  @override
  State<_WheelPickerDialog<T>> createState() => _WheelPickerDialogState<T>();
}

class _WheelPickerDialogState<T> extends State<_WheelPickerDialog<T>> {
  late final List<int> _indices;
  late final List<FixedExtentScrollController> _controllers;
  final FocusNode _focusNode = FocusNode(debugLabel: 'wheel-picker-dialog');
  int _activeColumn = 0;

  @override
  void initState() {
    super.initState();
    _indices = [
      for (var c = 0; c < widget.columns.length; c++)
        _clampIndex(widget.initialIndices[c], c),
    ];
    _controllers = [
      for (final index in _indices)
        FixedExtentScrollController(initialItem: index),
    ];
  }

  int _clampIndex(int index, int column) {
    final max = widget.columns[column].labels.length - 1;
    if (index < 0) return 0;
    if (index > max) return max;
    return index;
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  T get _value => widget.resultOf(_indices);

  bool get _valid => widget.valid?.call(_value) ?? true;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      _move(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _move(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _move(-10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _move(10);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home) {
      _jump(0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.end) {
      _jump(widget.columns[_activeColumn].labels.length - 1);
      return KeyEventResult.handled;
    }
    if (widget.columns.length > 1) {
      if (key == LogicalKeyboardKey.arrowLeft) {
        _switchColumn(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        _switchColumn(1);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_valid) _confirm();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _move(int delta) {
    final current = _indices[_activeColumn];
    _select(_clampIndex(current + delta, _activeColumn));
  }

  void _jump(int index) => _select(_clampIndex(index, _activeColumn));

  void _select(int next) {
    if (next == _indices[_activeColumn]) return;
    setState(() => _indices[_activeColumn] = next);
    final controller = _controllers[_activeColumn];
    if (!controller.hasClients) return;
    controller.animateToItem(
      next,
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeOut,
    );
  }

  void _switchColumn(int delta) {
    final count = widget.columns.length;
    setState(() => _activeColumn = (_activeColumn + delta + count) % count);
  }

  void _confirm() => Navigator.of(context).pop(_value);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDesktop = defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS;
    final keyHint = widget.columns.length > 1 ? '↑↓ 选择 · ←→ 切换列' : '↑↓ 选择';
    final hint = widget.hint ?? (isDesktop ? keyHint : null);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: widget.columns.length > 1 ? 360 : 320,
        height: 236,
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: Column(
            children: [
              Expanded(
                child: Row(
                  children: [
                    for (var c = 0; c < widget.columns.length; c++)
                      Expanded(
                        child: Listener(
                          onPointerDown: (_) {
                            if (_activeColumn != c) {
                              setState(() => _activeColumn = c);
                            }
                            _focusNode.requestFocus();
                          },
                          child: CupertinoPicker(
                            scrollController: _controllers[c],
                            itemExtent: 40,
                            magnification: 1.15,
                            onSelectedItemChanged: (i) {
                              if (_indices[c] != i) {
                                setState(() => _indices[c] = i);
                              }
                            },
                            children: [
                              for (final label in widget.columns[c].labels)
                                Center(
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      fontSize: 17,
                                      color: _activeColumn == c
                                          ? cs.onSurface
                                          : cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              if (hint != null)
                Text(
                  hint,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withValues(alpha: 0.5),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: appDialogActions(
        context,
        confirmLabel: '确定',
        confirmEnabled: _valid,
        onCancel: () => Navigator.of(context).pop(),
        onConfirm: _confirm,
      ),
    );
  }
}
