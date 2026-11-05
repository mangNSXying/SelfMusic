/// 枚举按 `name` 解析（持久化 / 同步载荷的唯一入口）。
library;

/// 命中返回枚举值，否则 null（非 String 输入同样返回 null）。
T? enumByNameOrNull<T extends Enum>(List<T> values, Object? name) {
  if (name is! String) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// 命中返回枚举值，否则返回 [fallback]。
T enumByNameOr<T extends Enum>(List<T> values, Object? name, T fallback) =>
    enumByNameOrNull(values, name) ?? fallback;
