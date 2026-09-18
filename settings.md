# SelfMusic 设置指南

> 状态：**设置体系的权威清单 + 后续实现指南**。✅ = 已实现；⏳ = 规划待实现；🔧 = 占位分区。
> 规划来源：DESIGN §6.7（客户端用户设置）、§9 R4（仅 Wi-Fi 扫描）、阶段 0 遗留（通知/音频焦点）、本指南侧边栏批注。
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
| 服务端全局设置 | MySQL `settings` 表（`PAIRING_TOKEN` 镜像写入） | `/admin/settings`（规划）、宿主机 `.env` | 全部已配对设备 | `scan_interval_min` |

> 设计原则：**单设备体验优先**——客户端设置完全本地闭环、离线可改；与服务器同名的配置项（缓存上限等）采用「跟随服务端 / 自定义」双来源，见 §3.3 与 §5。

关联代码：`lib/screens/settings_screen.dart`（分区面板）、`lib/data/local/app_settings.dart`（键定义与默认值）、`lib/data/local/local_index.dart`（`settings` 键值表）。

---

## 2. 设置入口结构（侧边栏分区）

`SettingsItem` 枚举（`lib/theme/app_theme.dart`）定义 6 个分区，`SettingsScreen` 按分区渲染面板：

| 分区 | 键 | 当前状态 | 内容与规划 |
|------|----|---------|-----------|
| 常规 | `general` | ✅ 已实现 | 设置 / 歌单 分开导出导入（§3.5，支持选择文件导入）；配对密钥明文显示（§3.5，DESIGN「暂缓项」已实现） |
| 播放 | `playback` | ✅ 已实现 | 默认播放模式 / 断点自动恢复 / 淡入淡出 / 均衡器（§3.2） |
| 服务端 | `server` | ✅ 已实现 | 后端地址 + 配对入口（`设置 → 服务端`，`pairing_token`）；缓存配置「跟随服务端 / 自定义」双模式（§3.3）。首次启动不强制配对——未配对可正常使用直连模式，服务端 / 代理功能需配对 |
| 歌曲 | `songs` | ✅ 已实现 | 收藏自动缓存 / 权重信息显示 / 忽略音频过滤 / 仅 Wi-Fi 扫描 |
| 通知 | `notifications` | 🔧 占位 | 面板已就绪（信息展示）；Android 通知栏 / 后台播放 / 音频焦点（§3.6，阶段 0 遗留） |

---

## 3. 客户端键值设置（app_settings）

> 存储约定：`LocalIndex.settings`（`settingsGet/settingsSet`），值一律为字符串；布尔用 `'0'`/`'1'`；未写入时用默认值。
> 未指定键名的新增项标注「键待定」，正式实现时先立键再开发。

### 3.1 歌曲分区 · 已实现

| 键 | 默认 | 说明 |
|----|------|------|
| `auto_cache_favorites` | `true` | 喜欢（收藏）的歌自动缓存到本地 |

### 3.2 播放分区 · 已实现

| 设置项 | 键 | 建议默认 | 说明 |
|--------|----|---------|------|
| 默认播放模式 | `play_mode_default` | `sequence` | 启动时读入并初始化播放模式（`sequence / loopList / loopOne / weighted`）；播放模式切换时同步写回。配合 `PlayerProvider` 现有模式状态 |
| 断点续播自动恢复 | `resume_on_startup` | `true`（开） | 启动时读取 `play_state` 恢复上次队列与播放位置，**保持暂停态**不自动播放；关闭则忽略 `play_state` |
| 淡入淡出 | `fade_enabled` + `fade_duration_ms` | 开，1000 ms（1~3 s） | 从暂停恢复到播放 / 播放挥手暂停前做 `setVolume` 软件渐变（16 ms 周期），全平台可用；不依赖音频后端 crossfade。关闭时无渐变直接切换 |
| 均衡器 | `equalizer_enabled` + `eq_bands` | 关 | 5 频段增益（`eq_bands`=JSON 整数数组：低音 60 Hz / 中低 230 Hz / 中音 910 Hz / 中高 3.6 kHz / 高音 14 kHz，范围 -12~+12 dB）。**仅 Android**（just_audio `AndroidEqualizer` 注入 `AudioPipeline`）；Linux/macOS 无公开 mpv Dart API，开关与滑块界面仍可见但不生效 |

### 3.3 服务端分区 · 缓存配置（已实现，双来源）

> 背景：`cache_max_bytes / cache_song_limit` 与服务器 `settings` 表同名（见 §5）。
> 这两项已从「歌曲」迁到「服务端」分区，并提供两种来源：跟随服务端 / 自定义。

| 设置项 | 键 | 默认 | 说明 |
|--------|----|------|------|
| 来源模式 | `cache_config_mode` | `custom` | `custom`=用本地自定义值；`follow_server`=用服务端建议值（服务端 `GET /api/v1/admin/config` 下发 —— 已实现） |
| 自定义缓存上限 | `cache_max_bytes` | `536870912`（512 MB） | 字节；`custom` 模式生效 |
| 自定义歌曲上限 | `cache_song_limit` | `200` | `custom` 模式生效 |

**生效值解析规则**（`settings.md` 落地为 `AppSettings.effectiveCacheMaxBytes / effectiveCacheSongLimit`）：

```
mode == custom        → 取本地 cache_max_bytes / cache_song_limit
mode == follow_server → 取服务端 settings 表同键值（1 GB / 500）
                        （服务端不可达时回退本地自定义值，并提示）
```

**UI 与迁移（已完成）**：
- `设置 → 服务端` 新增「缓存配置」区块：来源选择器（跟随服务端 / 自定义）+ 自定义时两个输入框行；下方展示当前生效值；右上角同步按钮手动刷新服务端建议值
- 已从 `设置 → 歌曲` 移除 `cache_max_bytes / cache_song_limit`（原存储值保留为「自定义」模式的取值）
- `follow_server` 选项在成功拉到服务端建议值后可用（`GET /api/v1/admin/config`），拉取失败时灰显并提示检查后端连接；进入该分区与显式点同步按钮都会触发一次拉取

### 3.4 歌曲分区 · 已实现

| 设置项 | 键 | 建议默认 | 说明 |
|--------|----|---------|------|
| 播放页权重信息显示 | `player_show_weight` | `true`（显示） | 播放页是否展示当前歌曲 liked / factor 权重芯片（读取 `play_meta`） |
| 忽略音频（时长过滤） | `scan_ignore_min_duration_sec` | `0`（关；启用建议 `60`） | 直连扫描 / 全局合并时过滤过短的明显非音乐文件 |
| 忽略音频（大小过滤） | `scan_ignore_min_size_bytes` | `0`（关） | 同上，按文件大小过滤 |
| 仅 Wi-Fi 扫描 | `scan_wifi_only` | `true`（移动端） | 移动端直连扫描仅 Wi-Fi 下进行（DESIGN R4）；桌面端忽略此开关 |
| 扫描模式 | `scan_mode` | `minimal` | `fast` 仅文件名建索引（零读头）/ `minimal` 只解析标题·歌手·专辑，其余播放时再补全 / `full` 解析全部元数据+封面 |
| 读取音频头部 | `scan_head_bytes` | `65536`（64KB） | 扫描时每个音频最多读取的字节数；越小扫描越快，但超长标签/封面可能缺失（建议 ≥64KB） |
| 提取内嵌封面 | `scan_embed_cover` | `true` | `full` 模式下把内嵌封面另存到本地；关闭可加快大曲库扫描 |
| 自动扫描间隔 | `scan_auto_interval_min` | `0`（关） | 按固定周期对全部直连源增量扫描（指纹未变零下载）；本地目录变化即使未开启也会自动触发 |

### 3.5 常规分区 · 备份与迁移（动作型，非键值）

> 属「动作入口」，不进 `app_settings`；放在 `设置 → 常规`。
> **设置与歌单分开导出导入**（独立文件），导入支持从任意位置选择文件（`file_selector`），方便跨机迁移。

| 功能 | 行为 |
|------|------|
| 配对密钥明文显示 | `设置 → 常规` 顶部展示 `GET /api/v1/admin/pairing-token` 返回的 `pairing_token`（默认遮显，可显示/复制）；附注「修改服务端 .env 重启后生效，仅影响新设备」；需已配对 |
| 导出设置 | `app_settings`（已知键）+ 服务端地址 + 主题偏好 → JSON 快照；**不含令牌与源凭据** |
| 导入设置（选择文件） | 文件选择器选取任一路径的设置备份恢复；兼容旧综合备份中对应部分 |
| 导出歌单 | 全部 `playlists / playlist_items`（含歌曲快照）→ JSON 快照 |
| 导入歌单（选择文件） | 文件选择器选取任一路径的歌单备份恢复；按 `(source_key, song_ref)` 重新解析挂载；缺失的源给出提示 |

实现要点（已在 stage 2 落地，本节为拆分细化）：JSON 文件统一放在应用支持目录
`selfmusic/backups/`，命名 `selfmusic-settings-<yyyyMMdd-HHmmss>.json` 与
`selfmusic-playlists-<yyyyMMdd-HHmmss>.json`；`设置 → 常规` 面板四个动作入口
（导出/导入 各两个），导入经 `file_selector` 打开系统文件选择器（Android SAF / 桌面原生对话框），
并可对本机备份文件列表点选导入 / 删除；schema 为 `selfmusic_backup / 1` 且以 `type` 字段
（`settings` / `playlists`）区分内容，导入先校验版本再写回对应部分并重建相关状态。
旧版综合备份（无 `type`）仍可导入；本机备份条目按类型标注（设置 / 歌单 / 设置+歌单）。

### 3.6 通知分区 · 已实现（Android，待真机验证）

> 阶段 0 遗留项已在客户端联结 + Android 壳层落地（`audio_service` 自定义处理器），
> 真机行为需验证；本分区提供开关。

| 设置项 | 键 | 默认 | 说明 |
|--------|----|------|------|
| 通知栏播放控制 / 后台播放 | `notification_controls` | `true` | **启动时生效**：开启则 `main()` 注册 `AudioService`（媒体通知 + 前台服务），自作 `SelfMusicAudioHandler` 把通知按钮转发到 `PlayerProvider`，播放状态/媒体信息回推通知；关闭则不注册。改动后重启应用生效 |
| 音频焦点（自动暂停/恢复） | `audio_focus_enabled` | `true` | 来电 / 其他 App 抢占时的暂停-恢复。just_audio `handleInterruptions`，切换后重建播放器即时生效（Android） |

---

## 4. 客户端运行配置（独立持久化）

| 配置 | 存储 | 说明 |
|------|------|------|
| 服务端地址 `baseUrl` | 应用支持目录 `.server/server_settings.json`（`ServerSettings`） | `设置 → 服务端` 运行时修改；空串=未配置。优先级高于编译期 `API_BASE_URL` |
| 主题偏好 | `flutter_secure_storage`（`ThemeProvider`） | 亮/暗模式、强调色 |
| 访问/刷新令牌 | `flutter_secure_storage`（`AuthProvider`） | `access_token` + `refresh_token` + `client_id` |
| 直连源凭据索引 | SQLite `sources.credential_ref` → `flutter_secure_storage` | WebDAV/SMB 密码不落库，只存引用键 |

> 与 app_settings 的区别：这些是**程序内部运行态**，无 UI 分区管理（服务端地址除外）。

---

## 5. 服务端全局设置与同键解析

> 源：`scripts/init.sql` + `application.yml`；DESIGN §3.1。
> 写入口：`PAIRING_TOKEN` 每次启动由 env 镜像覆盖写入；读取端 `GET /api/v1/admin/config`（缓存建议值）与 `GET /api/v1/admin/pairing-token`（配对密钥）已实现；`PUT /admin/settings` 仍规划。

| 键 | 默认 | 说明 | 与客户端同键？ |
|----|------|------|--------------|
| `pairing_token` | env 提供 / 首次随机 | 配对主令牌（明文可展示二维码） | — |
| `cache_max_bytes` | `1073741824`（1 GB） | 全局建议值，供客户端 `follow_server` 模式采纳 | ✅ 是 → 客户端解析见 §3.3 |
| `cache_song_limit` | `500` | 同上 | ✅ 是 → 客户端解析见 §3.3 |
| `scan_interval_min` | `0`（关） | 服务端定时扫描间隔（分钟），已迁移为 env `SCAN_INTERVAL_MS` / `SCAN_SCHEDULING_ENABLED`、`SCAN_HEAD_BYTES`、`SCAN_PROBE_POOL`（见 §5.1） | — |
| `transcode_max_concurrency` | `2` | ffmpeg 并发上限（超限降级透传） | — |
| `upload_dir` | `{LOCAL_ROOT}/Uploads` | 上传落点 | — |
| `scan_head_bytes` | `65536` | 服务端扫描每个音频最多读取的头部字节数 | — |
| `scan_scheduling_enabled` | `true` | 是否启用服务端定时增量扫描 | — |

### 5.1 服务端扫描配置（`application.yml` → env）

| env | 默认 | 说明 |
|-----|------|------|
| `SCAN_INTERVAL_MS` | `21600000`（6h） | 定时增量扫描间隔（`@Scheduled fixedDelay`） |
| `SCAN_SCHEDULING_ENABLED` | `true` | 关闭则仅手动扫描 |
| `SCAN_HEAD_BYTES` | `65536` | 每个音频最多读取的头部字节数（标签解析） |
| `SCAN_PROBE_POOL` | `4` | 标签探测并发池大小 |

> 服务端增量：PROPFIND 解析 `getcontentlength` + `getlastmodified` 作为指纹，
> 与库里 `file_size`/`file_mtime` 一致则跳过读头与写库（二次扫描近乎零成本）。

> **同键项设计约定**：客户端与服务器同名的配置（当前为缓存两项），客户端一律用
> 「`follow_server` / `custom`」双来源（§3.3）。客户端默认值与服务端建议值不同属正常：
> 服务端值为团队/全设备建议，客户端 `custom` 为单机覆盖。`follow_server` 已随
> `GET /api/v1/admin/config` 落地。

---

## 6. 实现顺序与待办（指南）

| 待实现项 | 前置 / 归属 | 建议时机 |
|---------|-----------|---------|
| `play_mode_default` / `resume_on_startup` / `player_show_weight` | 客户端本地，无后端依赖 | ✅ 已实现 |
| 忽略音频过滤、仅 Wi-Fi 扫描 | 直连扫描体验 | ✅ 已实现 |
| 缓存配置迁入「服务端」+ `follow_server` | 需服务端下发 API | ✅ 已实现（`GET /api/v1/admin/config` + 客户端跟随模式） |
| 导入导出设置 / 歌单 | 本地文件 + `file_selector`，无后端依赖 | ✅ 已实现（设置、歌单分开导出；导入支持选择文件） |
| 淡入淡出 / 均衡器 | 音频后端能力验证 | ✅ 已实现（淡入淡出全平台；均衡器仅 Android，真机验证） |
| 通知栏 / 后台播放 / 音频焦点 | Android 壳 + `audio_service` | ✅ 已实现（实现见 §3.6；真机验证） |
| 配对密钥明文显示（`设置 → 常规`） | 后端端点 + 前端 | ✅ 已实现（`GET /api/v1/admin/pairing-token`） |
| 服务端 `PUT /admin/settings` | 阶段 6 | `GET` 已实现；`PUT`（管理端改设置）仍规划 |

> 仍规划：服务端【管理设置】 `PUT /api/v1/admin/settings`（阶段 6）；
> 其余暂缓项（淡入淡出 / 均衡器 / 通知分区 / 配对密钥明文）均已实现，见各分区。