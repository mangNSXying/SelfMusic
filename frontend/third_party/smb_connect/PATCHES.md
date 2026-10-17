# smb_connect vendored fork（SelfMusic 补丁）

`smb_connect` 0.0.9 的本地副本，**仅鸿蒙（ohos）端 SMB 用**（纯 Dart，无原生
二进制；其余平台走 `dart_smb2` FFI，见 DEVELOPER.md「客户端播放源」）。上游已停更（2025-01），
原版方言最高到 SMB 2.1（SMB3 代码路径未启用/未修完）；本 fork 修复了
SMB 3.1.1 协商并允许主工程协商到 3.1.1。

## 为什么 fork

1. 上游 `pointycastle: ^3.9.1` 与 `dartssh2`（SFTP 必需，`pointycastle ^4.0.0`）
   版本解算冲突，主工程无法同时依赖两者；
2. ohos 分支偶发需要小补丁时有地方落（上游不维护）。

## 方言兼容（ohos SMB 连不上的根因）

部分 NAS / Samba 配置只接受 SMB3（典型：`server min protocol = SMB3_11`）。
此时原版 `smb_connect` 用 SMB 2.0.2/2.1 协商会收到
`STATUS_NOT_SUPPORTED (0xc00000bb)`，`SmbTransport._connect` 又吞掉异常，
最终 UI 只能看到 `Can't connect to host` / `Instance of 'SmbException'`。
安卓端走 libsmb2（支持 3.1.1）所以同一组主机/共享/账密可用——这就是
“安卓能连、鸿蒙不能”的差异来源。

本 fork 的处理：

- 修复 SMB 3.1.1 协商上下文解析（原代码 `List.generate(length, …)` 中
  `length` 此时恒为 0，服务器返回 3.1.1 时必抛 `RangeError`）；
- 主工程 `SmbConnectBackend` 默认 `maximumVersion: SMB311`，SMB3 建连失败
  （非鉴权原因）自动回退 `SMB210`；
- 协商失败不再吞异常，`SmbException.toString()` 返回 message，便于 UI/日志
  定位 `NOT_SUPPORTED` / `LOGON_FAILURE` 等具体原因。

仍不支持：SMB3 强制加密（`smb encrypt = required`）。若服务器强制加密，
需在 NAS 端允许 SMB2.1（`server min protocol = SMB2_10`）或改用 WebDAV/SFTP。

## 改动清单（相对 0.0.9）

- `pubspec.yaml`：`version` 加 `+selfmusic1` 后缀；`sdk` 下限对齐主工程
  `>=3.4.0`；`pointycastle` 放宽到 `^4.0.0`。
- `lib/smb_connect.dart`：追加公开导出 `BaseConfiguration` /
  `NtlmPasswordAuthenticator` / `DialectVersion`（ohos 后端自建匿名·账密配置用，
  避免主工程 import `src/` 私有路径）；追加导出 `SmbException` /
  `SmbAuthException`（错误分类用）。
- `lib/src/connect/impl/smb2/smb2_session.dart`：SMB3.1.1 preauth 完整性链
  补齐 SESSION_SETUP 请求/响应（`SmbTransport.updatePreauthIntegrityHash`），
  并在派生签名密钥前取 `getPreauthIntegrityHash()`；否则账密成功后的
  签名校验/后续请求签名会因缺少 preauth hash 失败。
- `lib/src/connect/impl/smb2/nego/smb2_negotiate_response.dart`：
  SMB3.1.1 negotiate context 列表改用 `negotiateContextCount` 定长分配，
  修复 3.1.1 响应解析 `RangeError`。
- `lib/src/exceptions.dart`：`SmbException.toString()` 返回 message
  （上游 PR #10 同款修复；原为 `Instance of 'SmbException'`，既丢 NTSTATUS
  文案也无法做错误映射）。
- `lib/src/connect/smb_transport.dart`：协商异常改为 rethrow（原 `print` 后
  `return false`）；`close()` 容忍未初始化 socket，避免失败清理时二次抛错。
- `lib/src/connect/smb_connect.dart`：`connect()` 失败时关闭底层 transport，
  防止 SMB3→2.1 回退/重试泄漏半开连接。
- 其余 `lib/` 与上游 0.0.9 一致（若后续打补丁，在此追加记录）。

## 依赖接入

`frontend/pubspec.yaml` 直接 `path` 依赖（非 override，主工程显式声明）：

```yaml
smb_connect:
  path: third_party/smb_connect
```

## pointycastle v4 兼容验证

- [x] `flutter pub get` 解算通过
- [x] `flutter analyze` 无 error（vendored 目录纳入主工程分析）
- [x] 错误映射/异常文案单测：`frontend/test/smb_source_test.dart`
- [ ] 真机联调：鸿蒙 SMB 枚举/点播（NTLM 鉴权是 pointycastle 的主要消费点，
      无 NAS 时无法验证，加大门槛走真机验收）
- [ ] 真机联调：SMB 3.1.1-only 服务器（本机已用协议探测确认协商到
      `0x0311` 并进入 SESSION_SETUP；账密成功后的签名/读写仍需真机覆盖）
