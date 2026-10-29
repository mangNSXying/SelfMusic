# SFTP 性能优化方案（Android / OHOS 通用）

> 状态：**worker isolate 全平台默认启用**（OHOS 2026-10-20 翻默认）；鸿蒙真机 PoC 已验证流播 / seek / 并发 spawn 修复，上传断线续传、启动失败自动降级、多源软上限、编译期强制回退开关均已落地。
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
| `open` | 打开文件，返回 `contentLength` / `totalLength`；调用方给了索引大小时跳过 `stat`（seek 少一个 RTT）；`priority` 决定读槽优先级 |
| `read` | 请求明文；worker 内 64KB 流水线，受下面读闸门调度 |
| `cancel` | 取消读流并关闭句柄 |
| `probe` | 读 1 字节预热 |
| `uploadStart` / `uploadChunk` / `uploadEnd` / `uploadAbort` | 流式上传；批带绝对偏移，连接类失败可用 `truncate: false` 重开会话续传 |
| `remove` / `mkdir` / `isDir` | 写操作与目录探测 |
| `close` | 关闭 SFTP/SSH 并退出 worker |

事件（worker → UI）：`openOk` / `data` / `batchDone` / `eof` / `error` / `closed`。

流控：主 isolate 每次发一条 `read`（`maxBytes` 256KB），收到 `batchDone` 且未暂停才发下一条；暂停/取消立即停止拉取。打开时已知文件总长（索引大小，`handleOpen` 会跳过 `stat`）时，一条 `read` 命令内 worker 会按 64KB 流水线把剩余区间持续传完，不再逐批往返；未知总长时才按 256KB 一批往返。主 isolate 收到的数据进入流的 `StreamController`，内存上界为当前打开的单个区间（单曲量级）。

读调度（`_WorkerReadGate`）：`open`/`probe`/`isDir` 等控制请求优先——控制请求在飞期间不再下发新读；全 worker 在飞读请求上限 4（原先每流各 4、多流叠加无上限）。读槽按 `open` 的 `priority` 从高到低分配，同优先级按 `tie`（越大越新）再 FIFO；MediaProxy 用「Range 越短优先级越高」的规则，播放器 seek 时新开的短 Range 优先于旧的全文件流，同长度 Range（AVPlayer 重复请求）由新流优先，避免旧流占满读槽把 seek 饿死（Windows 真机曾出现 seek 流 31s 只拿到 131KB）。MediaProxy 还会在 session 启动 probe 时预读尾部 64KB，播放器的尾部 Range（FLAC seektable）直接命中缓存，不再受控制 `open` 排队影响（真机约 5.8s）。真机口径：seek 的 `open` 从 3.5s 降到毫秒级。

错误跨 isolate 用结构化载荷传递（`kind` + `message` + `code`），在主 isolate 还原为：

- `SourceAuthException`：鉴权失败；
- `SshHostKeyMismatch`：主机指纹失配；
- `SftpStatusException(code)`：远端 SFTP 状态错误（上传/删除的权限、文件不存在分支继续可用）；
- `StateError`：配置/未知主机等。

诊断：`--dart-define=SFTP_WORKER_TRACE=true` 打开 `[sftp-worker]` 日志（spawn / 握手 / 首块 / 取消 / 重连），正常构建无输出。

### 3.3 平台开关与降级

`SftpWorker.enabled`（全平台默认 **true**，含 OHOS；2026-10-20 翻默认）：

- 编译期开关（全平台 `--dart-define`，不需要改代码）：
  - `SFTP_WORKER_DIRECT=true`：强制旧直连（应急回退，优先级最高）；
  - `SFTP_WORKER_ISOLATE=false`：显式关闭 worker（`=true` 与默认等价）；
- OHOS 真机 PoC（开关启用时的历史路径）用 `SFTP_WORKER_ISOLATE=true` 验证，现已并入默认；临时回退旧直连：

```bash
flutter build hap --dart-define=SFTP_WORKER_DIRECT=true
```

旧直连（`sftp_direct_transport.dart`）完整保留，行为与改动前一致：共享连接、掉线重建一次、`maxPendingRequests: 1`、OHOS 让出节拍。这样即使 worker 在某平台不稳定，也能一键切回。

运行时自动降级（传输层，`SftpIsolateTransport`）：

- worker **启动类**失败（`Isolate.spawn` 抛错 / 30s boot 超时 / 无命令端口）时，当次操作立即转旧直连，不把启动错误抛给播放链路；已转直连的实例后续操作零等待，不再为每次调用白付一次 spawn/boot 超时；
- 连续 2 次启动失败后，该源实例永久改走旧直连（`[sftp-worker]` 日志记录）。首次失败只影响当次、下一次仍给 worker 一次机会——偶发瞬态失败（内存压力等）不至于让整个源会话退回 UI isolate 解密；
- 只有启动类失败触发降级；SSH 连不上 / 鉴权失败 / 指纹失配等业务错误原样上抛（旧直连会遇到同样的失败，降级只会掩盖真实原因）；
- 命令已下发（含掉线重放）后重连再启动失败时不转直连：操作可能已在远端生效，重复投递会改变语义（如删除第二次报「不存在」）。

### 3.4 生命周期与泄漏控制

本次一并处理了 worker 化后最危险的几个泄漏点：

1. **备用源缓存**：`lineCandidates()` 每次播放都调用旧 `fallbackSourcesOf()`，旧实现每次新建 SFTP 实例 → 每个备用源一个 worker。现在按主源 key 缓存备用实例，配置/密钥变化时签名失效重建；旧实例不主动 close（可能正在播放），交给 worker 空闲回收。
2. **worker 空闲回收**：worker 内没有打开的读流、也没有未完成命令时，若持续 10 分钟空闲则自动关闭 isolate 与 SSH 会话。暂停中的播放仍保留读流，不会被误关。
3. **源删除/整体重载**：删除源时关闭主源与备用源实例；重载时清理已不存在主源的备用缓存。
4. **Manager dispose**：关闭所有主源与备用源。
5. **并发 spawn 去重**：`_ensureWorker` 对「正在启动」的 worker 去重（起播 / 补读 / 歌词同帧并发只起一个）；`close()` 期间新起的 worker 自动回收，不留孤儿会话。
6. **测试连接 isolate 化**：取指纹走一次性 `Isolate.run`，测试连接弹窗期间 UI 不再被 SSH 握手/解密占据（异常跨 isolate 结构化还原，类型不变）。
7. **多源 worker 软上限**：全局存活 worker 上限 3；新 worker 启动前若已达上限，回收最久未用的**空闲** worker（无读流、无在飞命令、无操作租约）。全部忙时不强行回收——宁可短暂超一点，不打断正在播放/补读的源。避免多 SFTP 源同时活动时各自常驻一条 SSH 连接、互相抢带宽。当前操作窗口与整次上传期间持有租约，不会被当成空闲回收。

## 4. 改动文件

| 文件 | 内容 |
| --- | --- |
| `frontend/lib/data/sources/sftp_common.dart` | 新增：认证方式/纯函数/异常、`SftpOpenResult`、`SftpTransport` 抽象、`SftpConnection`（SSH 建连与指纹、测试连接一次性 isolate、`sftpTrace` 开关） |
| `frontend/lib/data/sources/sftp_direct_transport.dart` | 新增：旧直连传输实现（行为与改动前一致） |
| `frontend/lib/data/sources/sftp_worker.dart` | 新增：worker 入口、RPC、64KB 读流水线、`_WorkerReadGate` 读调度、并发 spawn 去重、启动失败降级、多源软上限、`SftpIsolateTransport`、空闲回收 |
| `frontend/lib/data/sources/sftp_direct_source.dart` | 改造：业务逻辑走 `SftpTransport`；测试连接走一次性 isolate；扫描 isolate 不变；缓存让出节拍改为仅旧直连启用 |
| `frontend/lib/data/sources/meta_enrich.dart` | 让出节拍改为仅旧直连启用 |
| `frontend/lib/providers/direct_source_manager.dart` | 备用源缓存、删除/重载/dispose 时关闭会话 |

兼容性：`SftpAuthMethod`、`parseSftpAuthMethod`、`sftpHostPort`、`sftpOriginUrl`、`sftpGuardWriteName/Parent`、`SftpStatusException`、`SshHostKeyMismatch` 仍从 `sftp_direct_source.dart` 导出，原有 import 不需要改。

## 5. 实施阶段

- [x] 第一步：worker isolate 与传输抽象落地（Android/桌面/iOS 启用，OHOS 保留旧直连）。
  - 已在 Linux 上用本地 SFTP 服务端做协议冒烟：worker 启动、全量读、Range 读、上传（跨批/跨块）、建目录、删除文件、关闭，全部通过。
- [x] worker 生命周期与诊断收口（`7960b30`）：并发 spawn 去重 / `close()` 竞态回收、测试连接 `Isolate.run` 化、`SFTP_WORKER_TRACE` 日志开关。
- [x] OHOS worker 真机 PoC 核心链路（`fe7def7`）：spawn / 流播 / seek 精准落点 / 快速连点；读调度闸门把 seek 的 `open` 从 3.5s 收到毫秒级。
- [x] OHOS 默认切换：全平台默认 worker（`resolveWorkerEnabled` 去平台分支，默认 true）。一键回退：`--dart-define=SFTP_WORKER_DIRECT=true`（全平台强制旧直连）/ `SFTP_WORKER_ISOLATE=false`；此外 worker 启动类失败会自动降级。真机 soak 复核仍建议执行（见 §6.3）。
- [x] 上传断线续传（worker 路径）：每批带绝对偏移发送；连接类失败自动重连一次——已有确认落盘的数据时以 `truncate: false` 重开会话并重放最后一批（相同字节覆盖写，幂等），否则重新截断从头来。业务错误（权限/不存在）不重试、原样抛出。本地故障注入冒烟通过（8MB 上传中途掐线，重连续传后读回逐字节一致）。旧直连路径仍不重试（见 §8）。
- [x] worker 启动失败自动降级：启动类失败（spawn 抛错 / boot 超时 / 无命令端口）当次操作转旧直连，连续 2 次后本源永久降级；SSH/鉴权错误不降级。故障注入单测（`test/sftp_worker_fallback_test.dart`）+ 本地服务端冒烟（降级后读/上传真实可用、字节一致）通过。
- [x] 多源并发上限：全局存活 worker 软上限 3；新 worker 启动前回收最久未用的空闲 worker（无读流、无在飞命令、无租约），全忙时不强行回收。当前操作与整次上传持租约。本地 5 源冒烟：存活数始终 ≤ 3、进行中的读流不被回收、全部关闭后归零。

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

已完成（真机，`flutter build hap --dart-define=SFTP_WORKER_ISOLATE=true`）：

- worker 稳定启动（`Isolate.spawn` + 长活 ReceivePort），无 THREAD_BLOCK 类强杀；
- 流播正常；seek 精准落点（46.7% 目标点 `open` 9ms 返回、10 秒后位置=目标+播放时长）；
- 快速连点 6 次落点仍准确，无归零 / 卡旧值；
- 期间修复：并发 spawn 去重、读调度闸门（见 §5）。
- 本次 PoC 同时确认 OHOS 可长期运行 `Isolate.spawn`（长活 worker + 双向端口）；`DEVELOPER.md` 旧「fork 引擎无子 isolate」表述已于 2026-10-20 更正。

切换后复核（建议，真机默认即 worker）：

- 10 分钟以上连续播放 + 全库元数据补读 + 上传 / 删除，确认无 `THREAD_BLOCK_6S`；
- 排查可加 `--dart-define=SFTP_WORKER_TRACE=true` 看 `[sftp-worker]` 生命周期日志；
- 若出现异常：`--dart-define=SFTP_WORKER_DIRECT=true` 强制旧直连回退（或 `SFTP_WORKER_ISOLATE=false`）。

## 7. 回滚

- 所有平台：`--dart-define=SFTP_WORKER_DIRECT=true` 强制旧直连（不用改代码；旧直连代码与节拍逻辑完整保留）。
- 任意平台显式关闭/打开 worker：`--dart-define=SFTP_WORKER_ISOLATE=false|true`。
- OHOS 现已随全平台默认启用 worker（2026-10-20 翻默认，真机 PoC 与修复已验证）。
- 另：worker 启动类失败会自动降级旧直连（见 §3.3），不需要手动干预。

## 8. 已知限制

- 上传断线续传只覆盖 worker 路径；旧直连（显式回退 / 启动失败自动降级时生效）仍是一次性字节流，断线后需调用方重发；
- 未给单个 worker 设置带宽上限，非常快的网络下 worker 会尽量占带宽，但只影响该源，不影响 UI isolate；
- 打开但从未被监听的读流仍会持有远端句柄，直到 worker 空闲回收；正常播放/补读路径都会监听或取消。

## 9. 更新记录

- 2026-10-19 `80deaee`：第一步落地（worker isolate + 传输抽象 + 生命周期收口）。
- 2026-10-19 `7960b30`：并发 spawn 去重与 `close()` 竞态回收；测试连接 `Isolate.run` 化；`SFTP_WORKER_TRACE` 日志开关。
- 2026-10-20 `fe7def7`：读调度闸门（控制请求优先 + 全局在飞读上限 4）、64KB 读流水线、已知大小时 `open` 跳过 `stat`；鸿蒙真机流播 / seek 验证。
- 2026-10-20 `fc1d4d1`：worker 路径上传断线续传（绝对偏移批写 + 一次重连 + 最后一批幂等重放）；本地故障注入冒烟通过。
- 2026-10-20：worker 启动失败自动降级旧直连（当次操作转直连 + 连续 2 次永久降级并记录日志）；故障注入单测与本地服务端冒烟通过。
- 2026-10-20：多源 worker 软上限 3（LRU 回收空闲 worker、忙/持租约不回收；操作与上传持租约）；本地 5 源冒烟通过。
- 2026-10-20：worker 路径编译期强制回退开关 `SFTP_WORKER_DIRECT=true`（全平台）+ `SFTP_WORKER_ISOLATE=true|false` 双向显式指定；开关矩阵单测。
- 2026-10-20：OHOS 默认翻转为 worker（全平台默认启用；回退开关与自动降级保持不变）。
