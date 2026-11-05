/// `sourceRef`（源内相对路径，`/` 分隔）的纯字符串工具。
///
/// 与 `utils/source_folders.dart` 的区别：这里**保持原串**（不折叠空段、
/// 不处理 `.`/`..`），只回答「父目录 / 文件名 / 去扩展名」；目录树归一化
/// 请继续用 source_folders。
library;

/// 父目录；源根（无斜杠或首段前无内容）返回 `''`。
String refParent(String ref) {
  final slash = ref.lastIndexOf('/');
  return slash <= 0 ? '' : ref.substring(0, slash);
}

/// 末段文件名；无斜杠时返回原串。
String refLeaf(String ref) {
  final slash = ref.lastIndexOf('/');
  return slash < 0 ? ref : ref.substring(slash + 1);
}

/// 去扩展名的**文件名**（不含目录）；无扩展名或隐藏文件名返回叶子名。
String refStem(String ref) {
  final leaf = refLeaf(ref);
  final dot = leaf.lastIndexOf('.');
  return dot > 0 ? leaf.substring(0, dot) : leaf;
}

/// 去扩展名的**完整 ref**（保留目录）；无扩展名返回原 ref。
String refStemPath(String ref) => refStemPathOrNull(ref) ?? ref;

/// 去扩展名的**完整 ref**（保留目录）；无扩展名返回 null。
String? refStemPathOrNull(String ref) {
  final slash = ref.lastIndexOf('/');
  final dot = ref.lastIndexOf('.');
  if (dot <= slash || dot == slash + 1) return null;
  return ref.substring(0, dot);
}
