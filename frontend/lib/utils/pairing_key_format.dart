/// 配对密钥遮罩：保留首尾 4 位，长度 ≤8 时整串遮罩。
///
/// 配对页与「设置 → 网络」共用，避免两处实现漂移。
String maskPairingKey(String token) {
  if (token.length <= 8) return '••••••••';
  return '${token.substring(0, 4)}••••••${token.substring(token.length - 4)}';
}
