# SFTP 性能优化方案（Android / OHOS 通用）

> 状态：**第一步（SFTP Worker Isolate）已落地**，待真机验证。
> 适用代码：`frontend/lib/data/sources/`。

## 1. 现象

- 使用 SFTP 源时，Android 与 HarmonyOS 都会出现明显 UI 卡顿：
  - 起播/seek 时掉帧；
  - 连接测试、元数据补读、封面/歌词读取期间持续顿挫；
  - HarmonyOS 上严重时出现 `THREAD_BLOCK_6S`（主线程 6 秒无响应被系统强杀）。
- 扫描（全盘列出）反而不卡：扫描本来就在独立 isolate。

## 2. 根因

`dartssh2` 是纯 Dart 实现，SSH 传输层的 AEAD（AES-GCM）解密在**持有 SSH socket 的那个 isolate** 里同步执行：

```
SSHTransport._consumeAeadPacket()
  → pointycastle GCMBlockCipher
```

代码里绝大多数 SFTP 路径（播放 `open()`、`probe()`、元数据补读、封面/歌词读取、上传/删除/建目录）都运行在 **UI isolate**。因此网络一活跃，解密就会在 UI 事件循环里连续占满，表现为掉帧甚至 `THREAD_BLOCK_6S`。

关键不对称：

| 路径 | 运行 isolate | 卡不卡 |
| --- | --- | --- |
| SFTP 扫描 `_sftpWalk` | `runScan` 启动的 worker isolate | 不卡 |
| SFTP 播放 `open()` / `probe()` | UI isolate | 卡 |
| 元数据补读 / 封面 / LRC | UI isolate | 卡 |
| 上传 / 删除 / 建目录 | UI isolate | 卡 |

现有缓解措施只加在 OHOS：

- `sftp_direct_source.dart`：`maxPendingRequests: 1` + 16KB 块；
- `meta_enrich.dart`：读一块歇一块的节拍。

它们只是把单次同步块压小，**没有把解密移出 UI isolate**，所以 Android 同样卡，且 OHOS 只是“卡得没那么容易触发强杀”。同时首页连接后的 `_pumpUnread()` 会持续补读未读歌曲，这就是“连上后一直卡”的原因。

## 3. 方案：每个 SFTP 源一个长活 worker isolate

### 3.1 架构

```
UI isolate                          worker isolate
─────────                           ──────────────
SftpIsolateTransport                _sftpWorkerEntry
  ├─ open/read ──────命令──────►      SftpConnection.open（SSH 握手/KEX/验签）
  ├─ upload/remove/mkdir              SFTP 请求
  └─ close                            AES-GCM 解密
        ◄────明文块/错误/EOF────
```

- SSH 握手、主机指纹校验、SFTP 协议编解码、AEAD 解密全部在 worker isolate。
- UI isolate 只收发明文 `Uint8List`，不再执行任何密码学同步计算。
- 连接仍按源复用：一个 `SftpDirectSource` 懒启动一个 worker；掉线时重建一次再试。
- 打开的文件句柄随读流生命周期走：EOF/出错/取消都会关闭远端句柄。

### 3.2 协议（`sftp_worker.dart`）

命令（UI → worker）：

| 命令 | 说明 |
| --- | --- |
| `open` | 打开文件，返回 `contentLength` / `totalLength` |
| `read` | 请求一批明文（默认 256KB，worker 内按 64KB × 4 并发读） |
| `cancel` | 取消读流并关闭句柄 |
| `probe` | 读 1 字节预热 |
| `uploadStart` / `uploadChunk` / `uploadEnd` / `uploadAbort` | 流式上传 |
| `remove` / `mkdir` / `isDir` | 写操作与目录探测 |
| `close` | 关闭 SFTP/SSH 并退出 worker |

事件（worker → UI）：`openOk` / `data` / `batchDone` / `eof` / `error` / `closed`。

流控：主 isolate 一次只请求一批，收到 `batchDone` 且未暂停才请求下一批；暂停/取消立即停止拉取。内存上限约为「一个 256KB 批 + 主 isolate 控制器缓冲」。

错误跨 isolate 用结构化载荷传递（`kind` + `message` + `code`），在主 isolate 还原为：

- `SourceAuthException`：鉴权失败；
- `SshHostKeyMismatch`：主机指纹失配；
- `SftpStatusException(code)`：远端 SFTP 状态错误（上传/删除的权限、文件不存在分支继续可用）；
- `StateError`：配置/未知主机等。

### 3.3 平台开关与降级

`SftpWorker.enabled`：

- Android / iOS / 桌面默认 **true**；
- OHOS 因 fork engine 的长活 isolate 行为尚未真机 PoC，默认 **false**，走旧直连；
- OHOS 验证时可编译期打开：

```bash
flutter build hap --dart-define=SFTP_WORKER_ISOLATE=true
```

旧直连（`sftp_direct_transport.dart`）完整保留，行为与改动前一致：共享连接、掉线重建一次、`maxPendingRequests: 1`、OHOS 让出节拍。这样即使 worker 在某平台不稳定，也能一键切回。

### 3.4 生命周期与泄漏控制

本次一并处理了 worker 化后最危险的几个泄漏点：

1. **备用源缓存**：`lineCandidates()` 每次播放都调用旧 `fallbackSourcesOf()`，旧实现每次新建 SFTP 实例 → 每个备用源一个 worker。现在按主源 key 缓存备用实例，配置/密钥变化时签名失效重建；旧实例不主动 close（可能正在播放），交给 worker 空闲回收。
2. **worker 空闲回收**：worker 内没有打开的读流、也没有未完成命令时，若持续 10 分钟空闲则自动关闭 isolate 与 SSH 会话。暂停中的播放仍保留读流，不会被误关。
3. **源删除/整体重载**：删除源时关闭主源与备用源实例；重载时清理已不存在主源的备用缓存。
4. **Manager dispose**：关闭所有主源与备用源。

## 4. 改动文件

| 文件 | 内容 |
| --- | --- |
| `frontend/lib/data/sources/sftp_common.dart` | 新增：认证方式/纯函数/异常、`SftpOpenResult`、`SftpTransport` 抽象、`SftpConnection`（SSH 建连与指纹） |
| `frontend/lib/data/sources/sftp_direct_transport.dart` | 新增：旧直连传输实现（行为与改动前一致） |
| `frontend/lib/data/sources/sftp_worker.dart` | 新增：worker 入口、RPC、流控、`SftpIsolateTransport`、空闲回收 |
| `frontend/lib/data/sources/sftp_direct_source.dart` | 改造：业务逻辑走 `SftpTransport`；扫描 isolate 不变；缓存让出节拍改为仅旧直连启用 |
| `frontend/lib/data/sources/meta_enrich.dart` | 让出节拍改为仅旧直连启用 |
| `frontend/lib/providers/direct_source_manager.dart` | 备用源缓存、删除/重载/dispose 时关闭会话 |

兼容性：`SftpAuthMethod`、`parseSftpAuthMethod`、`sftpHostPort`、`sftpOriginUrl`、`sftpGuardWriteName/Parent`、`SftpStatusException`、`SshHostKeyMismatch` 仍从 `sftp_direct_source.dart` 导出，原有 import 不需要改。

## 5. 实施阶段

- [x] 第一步：worker isolate 与传输抽象落地（Android/桌面/iOS 启用，OHOS 保留旧直连）。
  - 已在 Linux 上用本地 SFTP 服务端做协议冒烟：worker 启动、全量读、Range 读、上传（跨批/跨块）、建目录、删除文件、关闭，全部通过。
- [ ] OHOS PoC：真机 spawn 长活 isolate，验证 10 分钟以上播放/补读/上传后 UI 无 `THREAD_BLOCK_6S`，再打开 `SFTP_WORKER_ISOLATE=true`。
- [ ] 上传断线重试：当前上传不自动重试（字节流一次性），失败后由调用方重新打开源文件再传；可考虑 worker 内暂存最近批次做幂等重放。
- [ ] worker 崩溃自动降级：连续启动失败时回退旧直连并记录日志。
- [ ] 多源并发上限：多 SFTP 源同时活动时限制 worker 数量/带宽，避免互相抢网络。

## 6. 验证清单

### 6.1 Android（首要）

1. 配置一个 100+ 首歌的 SFTP 源；
2. 连接测试、首次扫描、连续播放 120 秒、seek、后台自动续播；
3. 打开「元数据补读」，让 100 首歌的封面/标签补读跑完；
4. 上传一个音频 + 一个 `.lrc`/封面 sidecar，删除一个 sidecar，新建一个目录；
5. 播放中途编辑/删除该源，确认无异常弹窗、无残留会话。

### 6.2 判定标准

- `[perf] stall` 中 `gap >= 250ms` 的次数接近 0（与改动前对比）；
- HarmonyOS 无 `THREAD_BLOCK_6S`；
- 起播/seek 主观无卡顿，元数据补读期间界面可滚动；
- 断开 WiFi 后重连，播放能自动恢复（掉线重建一次）；
- 上传/删除/建目录行为与旧版一致；
- 退出播放页/删除源后，worker 数量能回落（空闲 10 分钟后自动关闭）。

### 6.3 OHOS PoC

在 `SftpWorker.enabled` 为 false 的默认构建验证旧直连行为不回退；再用：

```bash
flutter build hap --dart-define=SFTP_WORKER_ISOLATE=true
```

观察：

- worker 能否稳定启动（`Isolate.spawn` + 长活 ReceivePort）；
- 长时间播放/补读后是否出现线程强杀、isolate 崩溃；
- 若失败，记录 `SFTP worker 启动失败`/`意外退出` 日志，保持默认 false 即可。

## 7. 回滚

- OHOS：不传 `--dart-define` 即走旧直连。
- Android/桌面/iOS：临时把 `SftpWorker.enabled` 改为 `false`（或加同样的 dart-define 反向开关）即可全局回到旧直连；旧直连代码与节拍逻辑完整保留。

## 8. 已知限制

- 上传不自动重试（一次性字节流），断线后需调用方重发；
- 未给单个 worker 设置带宽上限，非常快的网络下 worker 会尽量占带宽，但只影响该源，不影响 UI isolate；
- 打开但从未被监听的读流仍会持有远端句柄，直到 worker 空闲回收；正常播放/补读路径都会监听或取消。
