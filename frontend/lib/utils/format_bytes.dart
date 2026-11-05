/// 字节数 → 人类可读文本（全应用唯一入口）。
library;

enum ByteUnit { b, kb, mb, gb }

/// 按 1024 进制格式化；[minUnit] 以下不再降级（如设置页的容量统一按 MB 起）。
///
/// 默认输出 KB/MB/GB；[minUnit] = [ByteUnit.b] 时不足 1KB 显示 `N B`。
String formatBytes(
  int bytes, {
  String zero = '0 KB',
  ByteUnit minUnit = ByteUnit.kb,
  int kbDecimals = 0,
  int mbDecimals = 0,
  int gbDecimals = 1,
  bool useGb = true,
}) {
  if (bytes <= 0) return zero;
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (useGb && (bytes >= gb || minUnit == ByteUnit.gb)) {
    return '${(bytes / gb).toStringAsFixed(gbDecimals)} GB';
  }
  if (bytes >= mb || minUnit == ByteUnit.mb) {
    return '${(bytes / mb).toStringAsFixed(mbDecimals)} MB';
  }
  if (bytes >= kb || minUnit == ByteUnit.kb) {
    return '${(bytes / kb).toStringAsFixed(kbDecimals)} KB';
  }
  return '$bytes B';
}
