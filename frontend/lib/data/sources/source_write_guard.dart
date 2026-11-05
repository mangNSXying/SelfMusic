/// 直写路径守卫（WebDAV / SFTP / SMB / 本地共用口径）。
library;

/// 写文件名：禁空、`/`、`\` 与 `..`。
void guardWriteName(String name) {
  if (name.isEmpty || name.contains('/') || name.contains('\\')) {
    throw StateError('文件名非法：$name');
  }
  if (name == '.' || name == '..' || name.contains('..')) {
    throw StateError('文件名非法（路径穿越）：$name');
  }
}

/// 写父目录：各段禁 `.` / `..`。
void guardWriteParent(String parentRef) {
  final parts = parentRef.split('/').where((s) => s.isNotEmpty);
  if (parts.any((s) => s == '.' || s == '..')) {
    throw StateError('目录非法（路径穿越）：$parentRef');
  }
}
