# SelfMusic 设置指南

> 状态：**设置体系的权威清单 + 后续实现指南**。✅ = 已实现；⏳ = 规划待实现；🔧 = 占位分区。
> 规划来源：DEVELOPER.md「数据模型」（客户端 app_settings 表）、DEVELOPER.md「风险与开放问题」R4（仅 Wi-Fi 扫描）、阶段 0 遗留（通知/音频焦点）、本指南侧边栏批注。
> 部署类配置（`.env`、`--dart-define`、Nginx、Docker）**不属于软件内设置**，已在 DEVELOPER.md 中说明，本文件不重复。

---

## 目录

1. [定位与分层总览](#1-定位与分层总览)
2. [设置入口结构（侧边栏分区）](#2-设置入口结构侧边栏分区)
3. [客户端键值设置（app_settings）](#3-客户端键值设置app_settings)
4. [客户端运行配置（独立持久化）](#4-客户端运行配置独立持久化)
5. [服务端全局设置与同键解析](#5-服务端全局设置与同键解析)
6. [实现顺序与待办（指南）](#6-实现顺序与待办指南)

---

## 1. 定位与分层总览

| 层 | 存储位置 | 管理入口 | 生效范围 | 示例 |
|----|---------|---------|---------|------|
| 客户端键值设置 | SQLite `app_settings`（`LocalIndex.settings`） | App `设置` 各分区 | 单台设备 | `auto_cache_favorites` |
| 客户端运行配置 | `server_settings.json` / `flutter_secure_storage` | `设置 → 服务端 / 界面` | 单台设备 | 后端地址、主题偏好、令牌 |
| 服务端全局设置 | MySQL `settings` 表（`PAIRING_TOKEN` 镜像写入） | `/admin/settings`（规划）、宿主机 `.env` | 全部已配对设备 | `pairing_token` |

> 设计原则：**单设备体验优先**——客户端设置完全本地闭环、离线可改；与服务器同名的配置项（缓存上限等）采用「跟随服务端 / 自定义」双来源，见 §3.3 与 §5。

关联代码：`lib/screens/settings_screen.dart`（分区面板）、`lib/data/local/app_settings.dart`（键定义与默认值）、`lib/data/local/local_index.dart`（`settings` 键值表）。

---

## 2. 设置入口结构（侧边栏分区）

`SettingsItem` 枚举（`lib/theme/app_theme.dart`）定义 6 个分区，`SettingsScreen` 按分区渲染面板。

| 分区 | 键 | 当前状态 | 内容与规划 |
|------|----|---------|-----------|
| 常规 | `general` | ✅ 已实现 | 快捷键（窗口内 / 全局）+「备份与迁移」单入口弹窗：本机备份选择恢复、设置 / 歌单导出导入（§3.5） |
| 歌曲 | `songs` | ✅ 已实现 | 收藏自动缓存 / 忽略音频过滤（**已入库歌曲即时生效**）/ 时长削弱（权重-时长曲线）/ 仅 Wi-Fi 扫描 / 扫描方式（写死快速：只建索引）/ 自动扫描间隔 / 标题显示格式（§3.4） |
| 播放 | `playback` | ✅ 已实现 | 默认播放模式 / 加权随机开关 + 削峰（次数冷却 + 曲数冷却，见 §3.2）/ 断点自动恢复 / 播放页手势 / 睡眠定时（四种模式 + 时长/曲数默认记忆 + 播放结束退出软件）/ 播放页权重信息显示 / 播放页屏幕常亮（可限定蓝牙设备，见 §3.2）/ 淡入淡出 / 均衡器 / 音频焦点自动暂停恢复 / 静音暂停 / 断连暂停（§3.2） |
| 界面 | `appearance` | ✅ 已实现 | 明暗主题 / 强调色 / 背景色 / 文字（自定义字体导入，§3.7）/ 播放页切换动画 / 播放页滑动手势 / 播放页权重信息 / 标题显示格式 / 播放页控件自动隐藏 / 长按展开/折叠 / 压缩图像画质 + 清理缩略图缓存（§3.7） |
| 通知 | `notifications` | ✅ 已实现 | 通知栏播放控制（自研 5 键：上一首/播放·暂停/下一首/播放模式/退出软件）+ 返回桌面后台续播（真正停止需通知栏「退出软件」或侧边栏「退出」）（§3.6） |
| 服务端 | `server` | ✅ 已实现 | 后端地址 + 配对服务器（副标题遮显同一份配对密钥，配对页明文可复制）；预载下一首（§3.2）；缓存配置「跟随服务端 / 自定义」双模式（§3.3）+ 缓存目录展示；「网络与安全」（§3.3.1）：允许不安全 HTTP / 信任自签名证书；「多设备同步」（§3.3.2）：总开关 / 立即同步 / 已配对设备管理。首次启动不强制配对——未配对可正常使用直连模式，服务端 / 代理功能需配对 |

---

## 3. 客户端键值设置（app_settings）

> 存储约定：`LocalIndex.settings`（`settingsGet/settingsSet`），值一律为字符串；布尔用 `'0'`/`'1'`；未写入时用默认值。
> 未指定键名的新增项标注「键待定」，正式实现时先立键再开发。

### 3.2 播放分区 · 已实现

| 设置项 | 键 | 建议默认 | 说明 |
|--------|----|---------|------|
| 默认播放模式 | `play_mode_default` | `sequence` | 启动时读入并初始化播放模式（`sequence / loopList / loopOne / weighted`）；`weighted` 显示为「随机播放」，实际算法由 `weighted_random_enabled` 决定。播放模式切换时同步写回。配合 `PlayerProvider` 现有模式状态 |
| 加权随机 | `weighted_random_enabled` | `true`（开） | 随机播放模式下的算法开关：开=按 factor 权重抽样；关=普通随机（按深层列表不放回，池 = 完整基座 - 深层已播身份 - 当前曲，深层满容量自动换轮）。关闭后下方次数/曲数冷却设置置灰且不生效 |
| 加权随机·次数冷却 | `weighted_draw_cooldown` | `normal` | 加权随机削峰规则1：一首歌播放后，再次被抽中的前 N 次直接抛弃、第 N+1 次才作数（N 按权重分档）。三档：`off`（关，0/0）、`weak`（弱，factor>1.0 抛 1 次 / 其余抛 2 次）、`normal`（正常，factor>1.0 抛 2 次 / 其余抛 3 次）。仅对加权随机生效；加权随机关闭时置灰 |
| 加权随机·曲数冷却 | `weighted_count_cooldown_ratio` | `0.2` | 加权随机削峰规则2（池排除）：深层列表（持久化播放历史）末尾 `round(列表长度 × 本比例)` 条内的歌**不参与随机**（进轮盘前即从候选池剔除）；取值 0~1.00，`0`=关闭。例：1000 首 × 0.2 = 最近 200 首内不再抽。窗口覆盖整表时回退全量。与规则1 解耦：窗口内不再抽中-抛弃，也不再给规则1 供数。仅对加权随机生效；加权随机关闭时置灰 |
| 断点续播自动恢复 | `resume_on_startup` | `true`（开） | 启动时读取 `play_state` 恢复上次队列与播放位置，**保持暂停态**不自动播放；关闭则忽略 `play_state` |
| 播放页滑动手势 | `player_gesture_swipe` | `true`（开） | 横滑切换播放页与歌词页、下滑返回列表；关闭后仅用按钮操作 |
| 睡眠定时默认播完最后曲目 | `sleep_play_through_default` | `true`（开） | 睡眠弹窗「播放完最后的曲目」开关默认值；弹窗内可单独调整 |
| 睡眠定时默认时长 | `sleep_default_duration_minutes` | `30` | 睡眠弹窗「指定时长」模式的默认分钟数（播放页内可临时调整，弹窗内记忆上次选值） |
| 睡眠定时默认曲数 | `sleep_default_count` | `3` | 睡眠弹窗「指定曲数」模式的默认首数（播放页内可临时调整，弹窗内记忆上次选值） |
| 预载下一首 | `preload_next` | `true`（开） | 播放时按播放顺序算法确定下一首并后台缓存（开关在 `设置 → 服务端`；随机播放也先抽样确定并在切歌时复用；开关只决定是否预载） |
| 播放页权重信息显示 | `player_show_weight` | `true`（显示） | 播放页是否展示当前歌曲 liked / factor 权重芯片（读取 `play_meta`；「不喜欢」锁定态显示 0.1） |
| 播放页屏幕常亮 | `player_keep_screen_on` | `false`（关） | 仅在播放页打开期间生效，离开播放页恢复系统熄屏策略（ohos 无 `wakelock_plus` 实现，跳过） |
| 常亮限定蓝牙设备 | `keep_screen_on_device` | `''`（不限定） | 仅在下列**任一**蓝牙设备处于连接状态时才保持常亮；值是设备名 JSON 数组（如 `[" buds","car"]`，旧版单对象 `{"a":" buds"}` 仍可读，由 `btDevicesFromSetting` 兼容）。设备名来自**已配对**列表（`getBondedDevices`），选择器为多选复选框；进入播放页后每 5s 轮询连接状态（`BluetoothProfile.LE_AUDIO`，Android 13+ 需该 profile；已授权 `BLUETOOTH_CONNECT` 才有意义，权限被收回时提示未授权） |
| 淡入淡出 | `fade_enabled` + `fade_duration_ms` | 开，2000 ms（0.5~2 s） | 从暂停恢复到播放 / 播放挥手暂停前做 `setVolume` 软件渐变（16 ms 周期），全平台可用；不依赖音频后端 crossfade。关闭时无渐变直接切换。时长有效域 [500, 2000] ms（0.1 s 步进），越界历史值读取时钳制到最近边界 |
| 均衡器 | `equalizer_enabled` + `eq_bands` | 关 | 5 频段增益（`eq_bands`=JSON 整数数组：低音 60 Hz / 中低 230 Hz / 中音 910 Hz / 中高 3.6 kHz / 高音 14 kHz，范围 -12~+12 dB）。**仅 Android**（just_audio `AndroidEqualizer` 注入 `AudioPipeline`）；Linux/macOS 无公开 mpv Dart API，开关与滑块界面仍可见但不生效 |
| 音频焦点（自动暂停/恢复） | `audio_focus_enabled` | `true` | 来电 / 其他 App 抢占时的暂停-恢复。**Android**：just_audio `handleInterruptions`（`audio_session`），切换后重建播放器即时生效。**鸿蒙**：`AvPlayerBridge.ets` 监听 AVPlayer `audioInterrupt`；系统强制暂停后同步 AVPlayer/Dart `playing` 与真实位置并落断点，`INTERRUPT_HINT_RESUME` 时由 `PlayerProvider` 按本开关自动续播（原生 AVPlayer 不会自动恢复；关闭开关只取消自动续播，系统抢占仍会强制暂停）。原在「通知」分区，现归「播放」分区 |
| 静音暂停 | `pause_on_zero_volume` | `false`（关） | 媒体音量归零时自动暂停当前播放。**仅 Android/鸿蒙**：自持原生监听（Android：`Settings.System` 音量变化，`AudioGuard.kt`；鸿蒙：系统音量事件，`AudioGuardBridge.ets`），不经 `audio_session` 的 becoming-noisy（后者只在音频焦点开启时注册）。其它平台开关可见但不生效 |
| 断连暂停 | `pause_on_device_disconnect` | `false`（关） | 当前播放输出设备（蓝牙音箱/耳机/有线/USB）断开时自动暂停。**仅 Android/鸿蒙**：Android 监听 `ACTION_AUDIO_BECOMING_NOISY`（系统在**活跃输出**被移除时广播）；鸿蒙监听设备连接状态变化并比对活跃输出（`AudioGuardBridge.ets`）。因此「蓝牙连着但声音走扬声器」时断开蓝牙不暂停、用户主动从蓝牙切扬声器也不暂停，符合预期语义。其它平台开关可见但不生效 |

> **中位播放进度**（派生统计，无设置键）：每首歌按「离开曲目时的最终播放百分比」维护 101 桶直方图（0..100%，1% 粒度；自然结束记 100%，30%~95% 的离开也采样，暂停不采样），全历史中位数即中位播放进度。它是升权的第二条线：目标 factor 1.1 需中位 ≥50%，每 +0.1 门槛 +5 个百分点（1.2≥55% … 1.5≥70%）；目标 ≤1.0 不设门槛，有效样本 <3 条时闸门不满足；降权仍只看连续跳过。展示在「歌曲信息」弹窗与侧边栏「歌曲信息 → 播放数据」明细中；同步与存储见 DEVELOPER.md。

### 3.3 服务端分区 · 缓存配置（✅ 已实现，阶段6闭环）

> 背景：`cache_max_bytes / cache_song_limit` 与服务器 `settings` 表同名（见 §5）。
> 这两项已从「歌曲」迁到「服务端」分区，并提供两种来源：跟随服务端 / 自定义。

| 设置项 | 键 | 默认 | 说明 |
|--------|----|------|------|
| 来源模式 | `cache_config_mode` | `custom` | `custom`=用本地自定义值；`follow_server`=用服务端建议值（`GET /api/v1/admin/config` 下发，进入分区与点同步按钮时拉取；失败灰显并提示，服务端不可达回退本地自定义） |
| 自定义缓存上限 | `cache_max_bytes` | `536870912`（512 MB） | 字节；`custom` 模式生效（`follow_server` 时输入行禁用） |
| 自定义歌曲上限 | `cache_song_limit` | `200` | `custom` 模式生效 |
| 服务端镜像 | `cache_server_max_bytes` / `cache_server_song_limit` | 空 | 拉取到的服务端建议值本地镜像（不进 `knownKeys`，不随备份导出） |

**生效值解析规则**（`AppSettings.effectiveCacheMaxBytes / effectiveCacheSongLimit`，`CacheManager.evictIfNeeded` 消费）：

```
mode == custom        → 取本地 cache_max_bytes / cache_song_limit
mode == follow_server → 有服务端镜像用镜像，无镜像回退本地自定义
```

### 3.3.1 服务端分区 · 网络与安全（已实现）

> 同在 `设置 → 服务端`（「预载下一首」下方的「网络与安全」区块）。

| 设置项 | 键 | 默认 | 说明 |
|--------|----|------|------|
| 允许不安全 HTTP | `allow_insecure_http` | `false`（关） | 关时显式 `http://` 地址一律拒绝并提示（后端地址 / WebDAV 地址 / 配对弹窗均受约束）；缺省协议恒补默认 `https://`，与开关无关。运行时 URL 归一化见 `ApiClient.normalizeBaseUrl` / `webdavNormalizeBase` |
| 信任自签名证书 | `allow_self_signed` | `false`（关） | 开时 dio API 与直连 WebDAV（dart:io `badCertificateCallback`）接受自签名/自建 TLS 证书，配置即生效（重建 WebDAV 源 + 替换 dio adapter）；**播放器层**（Android ExoPlayer / 桌面 mpv 原生起流）不受此开关影响，仍需 CA 有效证书 |

> 明文凭据收敛（历史安全整改项）：WebDAV 密码（`SecretStore` 键 `webdav_pwd:<sourceKey>`）与配对密钥（键 `pairing_key`）均改存 `flutter_secure_storage`；`sources.config` 与 `server_settings.json` 不再落地明文，旧数据启动时自动迁移并回写清理。
> Android 清单保留 `usesCleartextTraffic=true`：这是运行期「允许不安全 HTTP」可用的平台前提（network_security_config 无法运行期切换）。

### 3.3.2 服务端分区 · 多设备同步（阶段5，已实现）

> 同在 `设置 → 服务端`（「网络与安全」下方的「多设备同步」区块）；同步协议语义见 DEVELOPER.md「播放算法与同步协议」。
> 有歌曲身份即参与：权重 / 收藏 / 歌单 / 断点经服务端在设备间收敛；直连歌曲在连着服务器时同样同步（服务端按 `(source, source_ref)` 建影子行承载状态），未配对时直连事件不进队。

| 设置项 | 键 | 默认 | 说明 |
|--------|----|------|------|
| 多设备同步 | `sync_enabled` | `true`（开） | 总开关；关=仅本地，不上推也不拉取（效果等同直连模式） |
| 同步 cursor | `sync_cursor` | `0` | 服务端 `sync_events.seq` 增量基准；`SyncEngine` 每次成功后推进，`0` 表示下次全量校准 |
| 上次同步 | `last_sync_at` | 空 | 上次同步成功时间（ISO-8601），服务端分区「立即同步」行副标题展示 |

> 行为：本地变更先写 `weight_outbox`（带 event_uuid），引擎 2s 防抖批量上推（服务端按 uuid 幂等去重，LWW 判输回 correction 快照自纠）；
> 启动全量校准 + 每 30s 增量拉 + 回前台追一次 + 「立即同步」手动触发；断网进退避（上限 30s），恢复后自动追上。
> 断点仅当"从已同步歌单播放 + 当前歌曲有身份"时上报（服务器歌恒上报，直连歌需连着服务器），远端断点进 `breakpoint_mirror`（只读，不驱动运行时播放）。
> 「已配对设备」入口：列表 / 改名 / 吊销（调后端设备管理接口；本机按配对 client_id 高亮，吊销本机后需重新配对）。

### 3.4 歌曲分区 · 已实现

| 设置项 | 键 | 建议默认 | 说明 |
|--------|----|---------|------|
| 收藏自动缓存 | `auto_cache_favorites` | `true` | 喜欢（收藏）的歌自动缓存到本地 |
| 标题显示格式 | `song_title_format` | `artistTitle`（歌手 - 歌名） | 歌曲标题展示格式：`fileName` 文件名 / `titleOnly` 歌名 / `artistTitle` 歌手-歌名 / `titleArtist` 歌名-歌手；仅显示层（列表/歌单/播放页/队列/迷你条/通知栏），**不修改存储字段**；补读元数据后即按此展示 |
| 集合页展示形式 | `view_mode_playlists` / `view_mode_sources` / `view_mode_albums` / `view_mode_artists` | 播放列表=`list`，播放源/专辑/歌手=`card` | 播放列表 / 播放源 / 专辑 / 歌手四页右上角「列表 / 卡片」切换按钮的持久化取值（`list`/`card`）；切换在页面内进行，不进设置页 |
| 忽略音频（时长过滤） | `scan_ignore_min_duration_sec` | `0`（关；启用建议 `60`） | 直连扫描 / 全局合并时过滤过短的明显非音乐文件；**已入库歌曲同样即时过滤**（设置变更后歌曲/喜欢/专辑/歌手/源浏览按新规则生效；时长未知 `NULL/<=0`（快扫未读头）一律放过） |
| 忽略音频（大小过滤） | `scan_ignore_min_size_bytes` | `0`（关） | 同上，按文件大小过滤；已入库歌曲即时过滤（未知大小放过） |
| 时长削弱 | `curve_weight_enabled` + `curve_weight_segments` | 关 + 空 | **权重-时长分段函数**（改进.txt 功能8）：加权随机抽样时按歌曲时长乘削弱系数（长歌权重降低，避免长歌垄断；仅加权随机开启时生效）。`curve_weight_segments`=JSON 数组：`[{"min_sec":300,"max_sec":600,"factor":0.8}, {"min_sec":600,"max_sec":null,"factor":0.6}]`，`max_sec=null` 表示 ≥min_sec 恒生效（即「超过设定值」）；作用域左闭右开 `[min,max)`，命中第一段即止，未命中/时长未知=1.0；系数钳回 0.5–1.5。**只是抽样侧即时计算，不落库、不改 `play_meta`、服务端零改动**；列表「权重」排序不受影响 |
| 仅 Wi-Fi 扫描 | `scan_wifi_only` | `true`（移动端） | 移动端直连扫描仅 Wi-Fi 下进行（见 DEVELOPER.md「风险与开放问题」R4）；桌面端忽略此开关 |
| 扫描方式 | —（已写死） | 快速：只建索引 | **无设置项**：固定「快速：只建索引」，只用枚举拿到的 ref/size/mtime/etag 落库，不读任何音频内容（零读头请求）。原 `scan_mode`/`scan_head_bytes`/`scan_embed_cover` 三项已删除——它们让首扫在整库上盲目读头，代价与收益倒挂。元数据与封面由播放时补读、后台补读按结构定位后精确读取 |
| 自动扫描间隔 | `scan_auto_interval_min` | `0`（关） | 按固定周期对全部直连源增量扫描（指纹未变零下载）；本地目录变化即使未开启也会自动触发 |

### 3.5 备份与迁移（动作型，非键值，位于「常规」分区）

> 属「动作入口」，不进 `app_settings`；放在 `设置 → 常规 → 备份与迁移`（弹窗）。
> **设置与歌单分开导出导入**（独立文件），导入支持从任意位置选择文件（`file_selector`），方便跨机迁移。

| 功能 | 行为 |
|------|------|
| 导出设置 | `app_settings`（已知键）+ 服务端地址 + 主题偏好 → JSON 快照；**不含令牌与源凭据** |
| 导入设置（选择文件） | 文件选择器选取任一路径的设置备份恢复；兼容旧综合备份中对应部分 |
| 导出歌单 | 全部 `playlists / playlist_items`（含歌曲快照）→ JSON 快照 |
| 导入歌单（选择文件） | 文件选择器选取任一路径的歌单备份恢复；按 `(source_key, song_ref)` 重新解析挂载；缺失的源给出提示 |

实现要点（已在 stage 2 落地，本节为拆分细化）：JSON 文件统一放在应用支持目录
`selfmusic/backups/`，命名 `selfmusic-settings-<yyyyMMdd-HHmmss>.json` 与
`selfmusic-playlists-<yyyyMMdd-HHmmss>.json`；`设置 → 常规 → 备份与迁移` 弹窗四个动作入口
（导出/导入 各两个），导入经 `file_selector` 打开系统文件选择器（Android SAF / 桌面原生对话框），
弹窗内直接列出本机备份文件，点选导入 / 也可删除；schema 为 `selfmusic_backup / 1` 且以 `type` 字段
（`settings` / `playlists`）区分内容，导入先校验版本再写回对应部分并重建相关状态。
旧版综合备份（无 `type`）仍可导入；本机备份条目按类型标注（设置 / 歌单 / 设置+歌单）。

### 3.6 通知分区 · 已实现（Android，待真机验证）

> 阶段 0 遗留项已在客户端联结 + Android 壳层落地（`audio_service` 自定义处理器），
> 真机行为需验证；本分区提供开关。

| 设置项 | 键 | 默认 | 说明 |
|--------|----|------|------|
| 通知栏播放控制 / 后台播放 | `notification_controls` | `true` | **启动时生效，开关只控「按钮」，不控「后台播放」**：Android 侧 `AudioService`/`SelfMusicAudioHandler`（前台服务 + 播放期 wake lock）**恒注册**——此前关开关会一并 gate 掉前台服务与唤醒锁，息屏/Doze 下播放必被回收（已修）；鸿蒙侧 `OhosMediaSessionBridge` 同语义恒建，开关只控制建不建 AVSession（通知栏/锁屏/播控中心播控卡），`AUDIO_PLAYBACK` 长时任务恒随播放申请。**通知栏 5 键（`SelfMusicAudioHandler` 自绘，仅按钮渲染受开关控制）**：上一首 / 播放·暂停（随播放态切换）/ 下一首 / 播放模式（循环切换）/ 退出软件（落盘断点后结束进程），收起视图取前三个；图标为品牌色（`0xFF00A098`）矢量 `ic_np_*`。**后台播放语义**：返回桌面 / 切后台继续播放（Android `androidStopForegroundOnPause=false`，暂停不撤前台服务；audio_service 断言禁止与 `androidNotificationOngoing:true` 同用）；通知栏「退出软件」、划掉任务（`onTaskRemoved`）或侧边栏「退出」才**真正停止**并置空闲。改动后重启应用生效 |

---

### 3.7 界面分区 · 已实现

| 设置项 | 键 | 默认 | 说明 |
|--------|----|------|------|
| 页面切换动画 | `player_transition` | `fade` | 播放页、分组、设置、源内、歌单详情等全部页面切换效果：`none` 关闭 / `fade` 淡入 / `slide` 整页滑动（前进从右进、返回从左进，类似抽屉） / `scale` 缩放 |
| 长按展开/折叠 | `long_press_collapse_groups` | `false`（关） | 关（A）：长按专辑/文件夹组头进入多选并选中整组，分类菜单提供「全部展开/折叠」；开（B）：长按组头全部展开/折叠，分类菜单提供「多选」。多选态点组头/文件夹行切换整组三态勾选，右侧箭头折叠或进入目录且不改选择；播放源逐级文件夹行没有折叠语义，长按始终选中整个子树 |
| 播放页滑动手势 | `player_gesture_swipe` | `true`（开） | 自「播放」分区迁入：横滑切换播放页与歌词页、下滑返回列表；关闭后仅用按钮操作 |
| 播放页权重信息显示 | `player_show_weight` | `true`（显示） | 自「播放」分区迁入：播放页是否展示当前歌曲 liked / factor 权重芯片 |
| 标题显示格式 | `song_title_format` | `artistTitle`（歌手 - 歌名） | UI 置于「界面」，键语义仍归「歌曲」分区（§3.4）：所有列表/播放页/队列的标题展示格式 |
| 播放页控件自动隐藏 | `player_auto_hide_idle_sec` | `5` | 播放页（竖屏第 0 页 / 横屏整页）停留该秒数且无触摸时，自动淡出左上返回键与封面右上「更多」，**只隐藏入口**（封面/进度条/控制按钮常显）；任何触摸立即恢复并重新计时；`0`=不隐藏 |
| 压缩图像画质 | `cover_thumb_compress` | `false`（关，原图优先） | 开=列表/卡片/迷你条用 768 长边 JPEG82 缩略图（滑动更省）；关=一律显示封面原图，画质无损（播放页恒用原图）。关闭仅忽略已有 `*.thumb.jpg`，另有「清理缩略图缓存」手动删除；由关切开且存量未补齐时后台补回填 |
| 自定义字体（「文字」） | `custom_font_family` / `custom_font_file` / `custom_font_label` | 空（系统默认） | 设置 → 界面 → 文字：导入 TTF/OTF 后复制到应用支持目录 `selfmusic/fonts/`，`FontLoader` 运行时注册并写入 `ThemeData.fontFamily`，**全局界面与歌词生效**；恢复系统字体会删除字体文件并清空三键。**设备本地**：三键不进 `knownKeys`，不随设置导出/同步；文件缺失/损坏自动回退系统字体。TTC 集合不支持，缺字由系统字体回退；播放页时间与来源/格式/时长的等宽显示仍保留 `monospace` |

> 明暗主题 / 强调色 / 背景色存主题偏好（`flutter_secure_storage`，见 §4），不进 `app_settings`；自定义字体是设备本地资源，走 `app_settings` 三键 + 应用支持目录字体文件，同样不随备份导出。

## 4. 客户端运行配置（独立持久化）

| 配置 | 存储 | 说明 |
|------|------|------|
| 服务端地址 `baseUrl` | 应用支持目录 `.server/server_settings.json`（`ServerSettings`） | `设置 → 服务端` 运行时修改；空串=未配置。优先级高于编译期 `API_BASE_URL` |
| 主题偏好 | `flutter_secure_storage`（`ThemeProvider`） | 亮/暗模式、强调色 |
| 访问/刷新令牌 | `flutter_secure_storage`（`AuthProvider`） | `access_token` + `refresh_token` + `client_id` |
| 直连源凭据索引 | SQLite `sources.credential_ref` → `flutter_secure_storage` | WebDAV/SMB 密码不落库，只存引用键 |

> 与 app_settings 的区别：这些是**程序内部运行态**，无 UI 分区管理（服务端地址除外）。
> 自定义字体不在本表：字体文件在应用支持目录 `selfmusic/fonts/`，选择记录在 `app_settings`
> 的 `custom_font_*` 三键（设备本地，不随设置导出/同步，见 §3.7）。

---

## 5. 服务端全局设置与同键解析

> 源：`backend/src/main/resources/db/migration/V*.sql` + `application.yml`；服务端表定义见 DEVELOPER.md「数据模型」。
> 写入口：`PAIRING_TOKEN` 与缓存建议值（`CACHE_MAX_MIB` MiB / `CACHE_SONG_LIMIT` 首）每次启动由 env 镜像覆盖写入（改 `.env` 重启生效）；读取端 `GET /api/v1/admin/pairing-token`（配对密钥）、`GET /api/v1/admin/config`（缓存建议值）与 `GET /api/v1/meta/server`（版本/ffmpeg/水位）均已实现；`PUT /api/v1/admin/settings`（管理端改缓存两键）已实现——注意 env 重启覆盖语义，PUT 值会被带 env 重启覆盖。转码并发 `TRANSCODE_MAX_CONCURRENCY` 只 env（默认 2），不进表。

| 键 | 默认 | 说明 | 与客户端同键？ |
|----|------|------|--------------|
| `pairing_token` | env 提供 / 首次随机 | 配对主令牌（明文可展示二维码） | — |
| `cache_max_bytes` | `5368709120`（5 GiB） | 全局建议值（字节；V1 迁移预置 + `CACHE_MAX_MIB` env 覆盖），供客户端 `follow_server` 模式采纳 | ✅ 是 → 客户端解析见 §3.3 |
| `cache_song_limit` | `200` | 同上（`CACHE_SONG_LIMIT` env 覆盖） | ✅ 是 → 客户端解析见 §3.3 |
| `scan_interval_min` | `0`（关） | ❌ 已移除（服务端不再扫描；歌曲只由 APP 在播放源处扫描） | — |
| `transcode_max_concurrency` | `2` | ❌ 已移除（后端既不出流也不 ffmpeg 转码） | — |
| `upload_dir` | `{LOCAL_ROOT}/Uploads` | ❌ 已移除（无服务端上传） | — |

> **同键项设计约定**：客户端与服务器同名的配置（当前为缓存两项），客户端一律用
> 「`follow_server` / `custom`」双来源（§3.3）。客户端默认值与服务端建议值不同属正常：
> 服务端值为团队/全设备建议，客户端 `custom` 为单机覆盖。`follow_server` 的**解析规则已落地**，
> 服务端 `GET /api/v1/admin/config` **已实现**（建议值由 env 镜像）；客户端 `follow_server` 接线**已实现**（进入分区自动拉取，不可达回退自定义）。

---

## 6. 实现顺序与待办（指南）

| 待实现项 | 前置 / 归属 | 建议时机 |
|---------|-----------|---------|
| 歌词功能（内嵌 USLT / FLAC LYRICS + 同名 `.lrc` + 歌词页） | 客户端本地，无后端依赖 | ✅ 已实现（实现见 DEVELOPER.md「歌词与后台播放」） |
| 后台播放完善（返回桌面续播，停止才真正停） | Android `audio_service` | ✅ 已实现（§3.6） |
| 睡眠定时四模式（指定时间/时长/曲数/列表结尾 + 播放完最后曲目） | 播放页弹窗 | ✅ 已实现（可配置，不再写死） |
| 播放页封面「更多」→ 歌曲信息 / 修改歌曲元数据（全源） | 客户端本地 | ✅ 已实现（直连 `user_edited=1` 扫描不覆盖；服务器本地覆盖） |
| 顶部搜索框键入追焦（除非手动去除焦点） | 顶栏控制器 | ✅ 已实现 |
| 播放页「加入歌单」→「编辑歌单」（列全部播放列表，点按即加入/移出） | 客户端本地 | ✅ 已实现（其他入口仍为「加入歌单」） |
| 播放列表/播放源/专辑/歌手 列表·卡片切换 | 客户端本地 | ✅ 已实现（`view_mode_*`，§3.4） |
| 打开播放队列 / 歌单详情自动定位当前曲并强调色显示 | 客户端本地 | ✅ 已实现（按 sourceKey+sourceRef 判当前） |
| 标题显示格式（文件名/歌名/歌手-歌名/歌名-歌手） | 客户端本地 | ✅ 已实现（§3.4 默认歌手-歌名） |
| `play_mode_default` / `resume_on_startup` / `player_show_weight` | 客户端本地，无后端依赖 | ✅ 已实现 |
| 忽略音频过滤、仅 Wi-Fi 扫描 | 直连扫描体验 | ✅ 已实现 |
| 缓存配置迁入「服务端」+ `follow_server` 接线 + `PUT /admin/settings` | 阶段 6 | ✅ 已实现（双来源 UI/解析/生效值 + `GET /admin/config` + 进入分区自动拉取；不可达回退自定义；`PUT` 仅缓存两键 + env 覆盖语义文档化） |
| 代理设置（开关 + 码率三档 + 响度均衡 `transcode_enabled`/`transcode_bitrate`/`transcode_loudnorm`，响度默认关、仅代理转码生效）+ `GET /meta/server` | 阶段 6 | ✅ 已实现（无状态代理，失败回落直连；无 ffmpeg/未配对时灰显） |
| 直写上传/删除/新建文件夹（WebDAV PUT/DELETE/MKCOL + 本地直写，二次确认全删） | 阶段 6 | ✅ 已实现（SMB 仍骨架；鸿蒙写暂不支持） |
| 导入导出设置 / 歌单 | 本地文件 + `file_selector`，无后端依赖 | ✅ 已实现（设置、歌单分开导出；导入支持选择文件） |
| 淡入淡出 / 均衡器 | 音频后端能力验证 | ✅ 已实现（淡入淡出全平台；均衡器仅 Android，真机验证） |
| 通知栏 / 后台播放 | Android 壳 + `audio_service` | ✅ 已实现（实现见 §3.6；真机验证） |
| 音频焦点自动暂停/恢复 | just_audio `handleInterruptions` / 鸿蒙 AVPlayer `audioInterrupt` | ✅ 已实现（`设置 → 播放`；Android 沿用既有链路，鸿蒙待真机回归） |
| 配对密钥显示/复制（`设置 → 服务端 → 配对服务器`） | 后端端点 + 前端 | ✅ 已实现（`GET /api/v1/admin/pairing-token`，配对服务器副标题遮显、配对页明文可复制） |
| 缓存目录展示（`设置 → 服务端`） | 客户端本地 | ✅ 已实现（真实路径 + 占用 + 点击复制） |
| 默认 HTTPS + 「允许不安全 HTTP」+「信任自签名证书」开关 | 网络安全加固 | ✅ 已实现（§3.3.1；`ApiClient.validateEndpointUrl` 约束后端/WebDAV/配对地址，自签名开关覆盖 dio + dart:io 直连） |
| 明文凭据收敛（WebDAV 密码 / 配对密钥 → `flutter_secure_storage`，清理 `sources.config` 与 `server_settings.json` 明文） | 网络安全加固 | ✅ 已实现（`SecretStore`；老数据启动自动迁移） |
| 多设备同步（权重/收藏/歌单/断点收敛 + SyncEngine + 设备管理页） | 阶段 5 | ✅ 已实现（§3.3.2；协议见 DEVELOPER.md「播放算法与同步协议」；后端 11 步端到端验证通过，三端真机验收待做） |

> 截至最新迭代，阶段 6 已落地：`PUT /admin/settings`、`follow_server`、`GET /meta/server`、无状态转码代理、直写上传/删除。