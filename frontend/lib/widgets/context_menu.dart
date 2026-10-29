import 'package:flutter/material.dart';

/// 在指针位置弹出右键菜单（桌面鼠标 / 触控板 secondary click）。
///
/// [globalPosition] 取触发事件的全局坐标；菜单从指针处向右下展开，
/// 越界时由 [showMenu] 自动翻转 / 钳位。菜单项与三点按钮由调用方共用，
/// 保证两种入口完全同源。
Future<T?> showContextMenuAt<T>(
  BuildContext context,
  Offset globalPosition, {
  required List<PopupMenuEntry<T>> items,
}) {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      Rect.fromPoints(globalPosition, globalPosition),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
}
