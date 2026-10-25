import 'package:flutter/material.dart';

bool primaryFocusIsTextInput() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  if (ctx.findAncestorWidgetOfExactType<EditableText>() != null) return true;
  return ctx.findAncestorWidgetOfExactType<TextField>() != null;
}
