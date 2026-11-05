import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../../widgets/app_dialog_actions.dart';

class ColorDot extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final bool isCustom;
  const ColorDot(
      {required this.color,
      required this.selected,
      required this.onTap,
      this.icon,
      this.isCustom = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isCustom ? Colors.transparent : color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? colorScheme.primary
                : colorScheme.onSurface.withValues(alpha: 0.2),
            width: selected ? 3 : 1,
          ),
        ),
        child: isCustom
            ? Center(child: Icon(icon, color: color))
            : (selected
                ? const Icon(Icons.check, color: Colors.white, size: 20)
                : null),
      ),
    );
  }
}

class SwatchPreview extends StatelessWidget {
  final Color color;
  const SwatchPreview({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Theme.of(context).colorScheme.outline)),
    );
  }
}

/// 简易取色器：预设的饱和色网格 + 常用色。
class ColorPickerDialog extends StatefulWidget {
  final String title;
  final ValueChanged<Color> onPicked;
  const ColorPickerDialog({required this.title, required this.onPicked});

  @override
  State<ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<ColorPickerDialog> {
  static const List<List<Color>> _grid = [
    [
      Color(0xFF000000),
      Color(0xFF434343),
      Color(0xFF7B7B7B),
      Color(0xFFBFBFBF),
      Color(0xFFF2F2F2),
      Color(0xFFFFFFFF),
    ],
    [
      Color(0xFFB71C1C),
      Color(0xFFC62828),
      Color(0xFFE53935),
      Color(0xFFF44336),
      Color(0xFFEF9A9A),
      Color(0xFFFFCDD2),
    ],
    [
      Color(0xFF880E4F),
      Color(0xFFAD1457),
      Color(0xFFD81B60),
      Color(0xFFE91E63),
      Color(0xFFF48FB1),
      Color(0xFFF8BBD0),
    ],
    [
      Color(0xFF4A148C),
      Color(0xFF6A1B9A),
      Color(0xFF8E24AA),
      Color(0xFF9C27B0),
      Color(0xFFCE93D8),
      Color(0xFFE1BEE7),
    ],
    [
      Color(0xFF1A237E),
      Color(0xFF283593),
      Color(0xFF3949AB),
      Color(0xFF3F51B5),
      Color(0xFF9FA8DA),
      Color(0xFFC5CAE9),
    ],
    [
      Color(0xFF0D47A1),
      Color(0xFF1565C0),
      Color(0xFF1E88E5),
      Color(0xFF2196F3),
      Color(0xFF90CAF9),
      Color(0xFFBBDEFB),
    ],
    [
      Color(0xFF006064),
      Color(0xFF00838F),
      Color(0xFF00ACC1),
      Color(0xFF00BCD4),
      Color(0xFF80DEEA),
      Color(0xFFB2EBF2),
    ],
    [
      Color(0xFF004D40),
      Color(0xFF00695C),
      Color(0xFF00897B),
      Color(0xFF009688),
      Color(0xFF80CBC4),
      Color(0xFFB2DFDB),
    ],
    [
      Color(0xFF1B5E20),
      Color(0xFF2E7D32),
      Color(0xFF43A047),
      Color(0xFF4CAF50),
      Color(0xFFA5D6A7),
      Color(0xFFC8E6C9),
    ],
    [
      Color(0xFFE65100),
      Color(0xFFEF6C00),
      Color(0xFFF57C00),
      Color(0xFFFF9800),
      Color(0xFFFFCC80),
      Color(0xFFFFE0B2),
    ],
    [
      Color(0xFF263238),
      Color(0xFF37474F),
      Color(0xFF546E7A),
      Color(0xFF607D8B),
      Color(0xFFB0BEC5),
      Color(0xFFCFD8DC),
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _grid)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final col in row)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => widget.onPicked(col),
                      child: Container(
                        width: 32,
                        height: 32,
                        margin: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: col,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: Theme.of(context).colorScheme.outline),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
      actions: [appDialogCloseAction(context, label: '取消')],
    );
  }
}
