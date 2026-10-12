# smb_connect vendored fork（SelfMusic 补丁）

`smb_connect` 0.0.9 的本地副本，**仅鸿蒙（ohos）端 SMB 用**（纯 Dart，无原生
二进制；其余平台走 `dart_smb2` FFI，见 DEVELOPER.md「客户端播放源」）。上游已停更（2025-01），
方言最高到 SMB 2.1（无 SMB3）；NAS 需允许 SMB2 方言协商。

## 为什么 fork

1. 上游 `pointycastle: ^3.9.1` 与 `dartssh2`（SFTP 必需，`pointycastle ^4.0.0`）
   版本解算冲突，主工程无法同时依赖两者；
2. ohos 分支偶发需要小补丁时有地方落（上游不维护）。

## 改动清单（相对 0.0.9）

- `pubspec.yaml`：`version` 加 `+selfmusic1` 后缀；`sdk` 下限对齐主工程
  `>=3.4.0`；`pointycastle` 放宽到 `^4.0.0`。
- `lib/smb_connect.dart`：追加公开导出 `BaseConfiguration` /
  `NtlmPasswordAuthenticator` / `DialectVersion`（ohos 后端自建匿名·账密配置用，
  避免主工程 import `src/` 私有路径）。
- 其余 `lib/` 与上游 0.0.9 逐字节一致（若后续打补丁，在此追加记录）。

## 依赖接入

`frontend/pubspec.yaml` 直接 `path` 依赖（非 override，主工程显式声明）：

```yaml
smb_connect:
  path: third_party/smb_connect
```

## pointycastle v4 兼容验证

- [ ] `flutter pub get` 解算通过
- [ ] `flutter analyze` 无 error（vendored 目录纳入主工程分析）
- [ ] 真机联调：鸿蒙 SMB 枚举/点播（NTLM 鉴权是 pointycastle 的主要消费点，
      无 NAS 时无法验证，加大门槛走真机验收）
