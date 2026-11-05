import 'package:flutter/material.dart';

/// 行内加载圈（设置项 trailing / 源操作按钮等共用）。
class InlineSpinner extends StatelessWidget {
  final double size;
  final double strokeWidth;

  const InlineSpinner({super.key, this.size = 16, this.strokeWidth = 2});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(strokeWidth: strokeWidth),
    );
  }
}
