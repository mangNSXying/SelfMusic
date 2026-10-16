import 'package:flutter/material.dart';

/// 歌曲信息详情页共用：宽窄断点与单元格样式。
///
/// 断点复用侧边栏规则（`NavigationProviderHelper.isNarrow` 取反）：
/// 宽度 >= 900 或横屏（宽 > 高）即宽屏，其余为窄屏。
bool isWideDetail(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return size.width >= 900 || size.width > size.height;
}

/// 文本单元格：宽度上限，超出部分横向滚动（不截断、不换行）。
Widget cappedCell(String text, double maxWidth, {TextStyle? style}) {
  final t = text.isEmpty ? '—' : text;
  return ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(t, maxLines: 1, softWrap: false, style: style),
    ),
  );
}
