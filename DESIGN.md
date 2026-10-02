# SelfMusic 整体设计文档

> 定位：**去中心化的个人音乐服务器 + 双模式客户端**
> 上游约束：`开发思路.txt`（无中心账号 / 本地+SMB+WebDAV 曲库 / 加权播放 / 喜欢歌自动缓存）
> 状态：**阶段 0–3、阶段 5 已完成**（Android 壳对齐 / 认证·配对 / 客户端本地闭环·歌单·喜欢列表 / 直连 WebDAV·本地索引·增量扫描优化 / 多设备状态同步）；阶段 4（SMB）、阶段 6（转码+管理闭环）待实施。
> 在此之上，后续迭代全部落地：元数据后台补读与全源编辑、歌词、后台播放、睡眠定时四模式、播放页与集合页交互
> （层级返回 / 分组左右滑切 / 列表·卡片切换 / 队列·歌单自动定位高亮 / 标题显示格式 / 搜索追焦 / 编辑歌单）、
> 网络安全加固（默认 HTTPS + 允许不安全 HTTP / 信任自签名开关 + 明文凭据收敛到 secure storage，见 §6.7 与 问题.md）、
> 歌手身份聚合与 MusicBrainz 后台解析、通知栏 5 键（播放模式 / 退出软件）、歌单页并入播放器横滑带。
> **平台支线：鸿蒙 NEXT 端已落地**（2026-09 PoC 验收通过——fvp 播放 / AVSession 媒体播控 / 真机日常使用，见 §8 平台支线与 [DEVELOPER.md「鸿蒙适配」](DEVELOPER.md#鸿蒙适配)）。
> 各阶段交付、验收与落地状态见 §8；文中已用「✅ 已实现 / ⏳ 规划」标注能力与端点到现状。

> **文档地图**：本文 = **为什么这么设计**（架构取舍、数据模型意图、API 契约、播放算法与同步协议、路线图与风险）；
> 设置项完整清单见 [settings.md](settings.md)；
> **怎么开发、代码怎么写、改完怎么验证**（环境、命令、SQLite 写隔离、扫描隔离、鸿蒙适配、排障）见 [DEVELOPER.md](DEVELOPER.md)；
> 快速启动与服务端口见 [README.md](README.md)。
> 同一段实现细节只在一处出现：本文给机制与取舍，DEVELOPER 给写代码必守的规则。

## v2 相对 v1 的关键变化

| 变更 | 内容 |
|------|------|
| 无用户 → 单用户 | 引入"一服务器一主人"语义，配对 Token 认证，设备可管理可吊销 |
| 单模式 → 双模式 | App 在**无后端**时靠 SMB/WebDAV 直连完整可用；后端是增强层 |
| 新增 Source 抽象层 | Local / WebdavDirect / SmbDirect 三实现统一接口 |
| 新增客户端本地索引 | 直连模式下 SQLite 轻量建库，跨源搜索体验接近一体化曲库 |
| 路线图重排 | 按"骨架→核心体验→直连→SMB→同步→转码/管理"六阶段 |

---

## 目录

1. [总体架构](#1-总体架构)
2. [身份与设备配对](#2-身份与设备配对)
3. [数据模型](#3-数据模型)
4. [API 设计](#4-api-设计)
5. [后端模块与选型](#5-后端模块与选型)
6. [Flutter 客户端设计](#6-flutter-客户端设计)
7. [播放算法与同步协议](#7-播放算法与同步协议)
8. [分阶段路线图](#8-分阶段路线图)
9. [风险与开放问题](#9-风险与开放问题)

---

## 1. 总体架构

### 1.1 总体架构

```
                        ┌─────────────────────────────────┐
                        │         Flutter App              │
                        │                                  │
                        │  ┌────────────────────────────┐ │
                        │  │ 播放引擎（加权算法）          │ │ ←── 核心体验：
                        │  │ 本地 SQLite（状态事实源）     │ │      离线可用
                        │  │ 缓存管理（LRU、喜欢歌）       │ │
                        │  ├────────────────────────────┤ │
                        │  │      Source 抽象层           │ │
                        │  │  LocalDirectSource          │ │
                        │  │  WebdavDirectSource         │ │
                        │  │  SmbDirectSource（阶段4）     │ │
                        │  └────────────┬───────────────┘ │
                        └───────────────┼─────────────────┘
                                        │ 协议直连（App 内扫描/播放）
                                        ▼
                           ┌──────────────────────┐
                           │  音乐源（协议直连）    │
                           │  · NAS(SMB)          │
                           │  · WebDAV 服务        │
                           └──────────────────────┘
                                        ▲ 状态同步（权重/收藏/歌单/断点/播放源）
                                        │ 配对与设备管理（无曲库/无流媒体）
                           ┌──────────────────────┐
                           │ Spring Boot 后端      │
                           │ （个人单用户同步服务）  │
                           └──────────────────────┘
```

### 1.2 功能矩阵

| 功能 | 现状 | 说明 |
|------|:---:|------|
| 本地文件播放 | ✅ | 内嵌协议客户端 |
| SMB/WebDAV 浏览与播放 | ✅ | 不依赖后端 |
| 歌单 / 加权算法 / 喜欢·不喜欢 | ✅ | 本地 SQLite |
| 喜欢歌自动缓存 / 断网播放 | ✅ | 蓝图 §三.3 |
| 曲库浏览 / 跨源搜索 | ✅ | 本地轻量索引，首次需现场扫描 |
| 多设备状态同步 | ✅ | 权重/收藏/歌单/断点/播放源；需要后端 |
| 播放源同步 | ✅ | WebDAV/SMB 等远端源（本地文件夹源各机独立） |
| 后台增量扫描 | ✅ | 本地变化监听 + 周期快扫，指纹跳过零下载 |
| 上传 / 删除源文件 | ⚠️ | WebDAV 可直传；SMB 视权限 |

## 2. 身份与设备配对

### 2.1 语义

- 一台服务器 = 一个主人（自建自用）。没有注册/登录体系，但有明确的归属和准入控制。
- 去中心化：各人部署各自的服务器，互不联通；App 可保存多个服务器配置。

### 2.2 令牌模型（OAuth2 风格：access + refresh）

```
主配对令牌 (pairing_token)
  · 权威来源 = 环境变量 PAIRING_TOKEN；每次启动覆盖写入 settings 表（DB 仅为镜像）
  · 未提供 PAIRING_TOKEN 时沿用库中旧值；首次初始化（库中无）才随机生成
  · 仅用于 /auth/pair 配对一次，不用于日常请求
  · 以明文存储（需要展示成二维码）；改 .env 重启即生效，仅影响新设备，已配对设备不受影响

访问令牌 (access_token / device_token)
  · pair 成功后签发，TTL = 24h（expires_in=86400），仅存哈希（token_hash）
  · 日常请求携带 Authorization: Bearer <access_token>
  · 过期 → 请求被拒（HTTP 401 + 响应头 X-Token-Expired: true）

刷新令牌 (refresh_token)
  · TTL = 30d（refresh_expires_in=2592000），仅存哈希（refresh_token_hash）
  · 仅用于 POST /auth/refresh 换发新的一套 access+refresh
  · **轮换式**：用过的 refresh_token 立即作废，同一套 token 只能换一次

吊销 / 过期语义
  · 单台吊销不影响其他设备；吊销的设备 access/refresh 均失效
  · refresh 也过期 → App 回到"会话过期"，提示重新配对
```

### 2.3 配对与续签流程

```
┌────────┐                          ┌──────────┐
│ App    │  ①输入地址+令牌 或扫二维码   │  Server   │
│        │ ─── POST /auth/pair ────► │           │
│        │    {pairing_token,        │ 校验令牌    │
│        │     device_name,platform} │ 注册设备    │
│        │ ◄── {client_id,           │ 签发      │
│        │      access_token,        │  access+   │
│        │      refresh_token,       │  refresh   │
│        │      expires_in,          │           │
│        │      refresh_expires_in}  │           │
│ 保存到  │                           │           │
│ 安全存储│  ②日常请求带 Bearer access  │           │
│        │  ③access 过期 → 懒刷新     │  POST     │
│        │ ─── POST /auth/refresh ──►│ /refresh  │
│        │ ◄── 新 access+refresh     │ (轮换,匿名)│
└────────┘                          └──────────┘
```

- 二维码内容：`selfmusic://pair?host=xxx&port=18089&token=xxxx`
- **懒刷新（lazy refresh）**：不做定时器；仅当某请求命中 `401 + X-Token-Expired` 时，客户端才用 refresh_token 换发新 token，并对原请求重放一次（并发请求以"单飞 single-flight"共享一次刷新，避免重复轮换）
- 刷新失败（refresh 失效/过期）→ 客户端清空令牌，进入"会话过期"弹窗，引导重新配对
- 重置主令牌：旧令牌立即失效，已配对设备不受影响

---

## 3. 数据模型

### 3.1 服务端（MySQL 8）

> `scripts/init.sql` 为唯一事实源；应用启动 `ddl-auto: validate` 校验一致性。

| 表 | 说明 |
|----|------|
| `song_states` | 直连歌权重/收藏状态（`source_id`+`source_ref` 唯一，无曲库字段） |
| `sync_sources` | 播放源同步（`client_uuid` 唯一；`kind+address` 去重；config 不含密码） |
| `playlists` | 歌单 |
| `playlist_items` | 列表条目（自持 `source_id/source_ref` + 标题/歌手/专辑/时长快照） |
| `play_states` | 每列表断点（自持歌曲身份 + `device_client_id`） |
| `sync_events` | 同步事件流水（seq 单调 cursor） |
| `settings` | 全局设置（含 pairing_token） |
| `devices` | 已配对设备 |

> 原 `albums/songs/covers/scan_tasks` 已随服务端曲库移除（`migration_004_remove_library.sql`）。

#### devices

```
id                   BIGINT PK
client_id            CHAR(36) UNIQUE         -- UUID，配对时生成
name                 VARCHAR(100)            -- 设备昵称，可改
platform             VARCHAR(50)             -- linux/android/windows/harmony/...
token_hash           CHAR(64)                -- SHA-256(access_token 初值)，仅存哈希
token_expires_at     DATETIME                -- access 过期时间（24h）
refresh_token_hash   CHAR(64)                -- SHA-256(refresh_token)，仅存哈希
refresh_expires_at   DATETIME                -- refresh 过期时间（30d）
renewed_at           DATETIME                -- 最近一次 refresh 时间
revoked              BOOLEAN DEFAULT FALSE
paired_at            TIMESTAMP
last_seen_at         DATETIME NULL
INDEX idx_token(token_hash)
INDEX idx_refresh(refresh_token_hash)
```

#### settings 键清单

| 键 | 默认 | 说明 |
|----|------|------|
| `pairing_token` | 未提供 `PAIRING_TOKEN` 时首次随机 | 主配对令牌（env 镜像，供 /auth/pair 校验） |
| `pairing_token` 外键项均按需由环境变量镜像写入；`cache_*`/`scan_*`/`upload_*` 等旧键已随曲库功能移除。

`song_states` 权重相关字段与触发规则见 §7.1。

### 3.2 客户端（SQLite）

> 表结构权威定义在 `frontend/lib/data/local/schema.dart`（`applySchema()`，主读连接与写隔离共用、幂等）；写代码规则见 [DEVELOPER.md「客户端本地数据层」](DEVELOPER.md#客户端本地数据层sqlite-写隔离)。

| 表 | 说明 |
|----|------|
| `sources` | 源配置：`type(local/webdav/smb)`、名称、凭据引用键、enabled、last_scan_at（同步后含 `client_uuid`） |
| `idx_songs` | 直连模式本地索引：`source_key, ref, title, artist, album, track_no, year, genre, duration, format, size, mtime, etag, cover_path, missing`（增量指纹含 `mtime,size,etag`；`is_favorite` 旧列仅用于一次性回填迁移，阶段 2 起不再读写） |
| `cache` | 已缓存歌曲：`cache_key, source_key, ref, local path, size_bytes` + `cached_at, last_accessed_at`（阶段 2 补列，LRU 用） |
| `play_meta` | 歌曲播放元数据（阶段 2 新增）：`(source_key, song_ref)` 主键 + `like_streak, dislike_streak, factor, frozen, is_favorite`（**收藏统一收口**）+ `play_sec`（累计播放秒数，播放次数由此派生）+ `song_json`（同步快照；本机未配置对应源时用于展示） |
| `playlists` / `playlist_items` | 歌单与条目（阶段 2 新增）：条目含歌曲快照字段 + `sort_order`；播放时按 `(source_key, song_ref)` 重新解析 |
| `app_settings` | 客户端设置（阶段 2 新增）：键值表，`cache_max_bytes / cache_song_limit / auto_cache_favorites` 等 |
| `song_lyrics` | 歌词（迭代新增）：`(source_key, song_ref)` 主键 + `content`（LRC 文本）+ `updated_at`；三态收录（内嵌歌词 / 同名 `.lrc` / 标记缺失），避免每次播放重复读文件 |
| `play_state` | 断点（阶段 2 新增）：单行（`id=1`），`queue_json + index + position_ms` |
| `weight_outbox` / `breakpoint_mirror` | 同步流水与跨设备断点镜像（阶段 5 新增），语义见 §7.2 |
| `deep_lists` | 深层列表（见 §7.1 深层列表）：`playlist_uuid` 主键 + 有界历史栈 `entries_json` |

要点：

- `song_key` 统一为 `(来源标识, source_ref)` 复合键；同一首歌在不同模式下可解析到不同 Source 实现
- 收藏状态**统一收口** `play_meta.is_favorite`：迁移时从 `idx_songs.is_favorite=1` 回填一次，
  此后所有读取（搜索 / 收藏列表 / 歌单解析 / 断点恢复）统一 `LEFT JOIN play_meta`
- 凭据加密：WebDAV/SMB 密码经 `flutter_secure_storage` 存放，SQLite 只存引用键
- 离线优先：所有播放决策只查本地表；网络层的角色是把远端变更搬进本地
- **读写分离（Windows 启动写盘风暴修复）**：主 isolate 的连接**只做读**，所有写经后台写 isolate（`DbWriter`）串行执行并自动合并为单个事务（队列 256 条或 2ms 触发），WAL + `synchronous=NORMAL` 把「逐行 autocommit 的几万次小块写」收敛成少量大块顺序写。
  推论：**读改写必须在写连接内原子完成**（`applyWeightEvent` / `setFavorite` / `upsertPlayMeta` 等 op），主连接读到的是已提交数据；退出与备份导出前必须 `flushWrites()`。详见 DEVELOPER 同名章节
- 阶段 5 同步时：权重/歌单改动落 `weight_outbox` 流水上推，服务端按 `event_uuid` 幂等去重（阶段 5 已落地，见 §7.2）

---

## 4. API 设计

统一约定：

- 前缀 `/api/v1`
- 响应包：`{ "code": 0, "message": "ok", "data": ... }`
- **认证**：除 `/health`、`/auth/pair`、`/auth/refresh`（匿名）外全部要求 `Authorization: Bearer <access_token>`；无效/吊销返回 `code=40101`；**access 过期返回 `HTTP 401` + 响应头 `X-Token-Expired: true`**
- 设备识别头 `X-Client-Id` 必带（与 devices.client_id 对应）
- 分页：`page`（1 起）、`size`（默认 50，≤500）；响应含 `total`
- 状态图例：**✅** = 已实现（以后端 Controller 为准）· **⏳** = 规划（后续阶段）

### 4.1 认证与设备

| 方法 | 路径 | 说明 |
|------|------|------|
| ✅ GET | `/health` | 免认证存活检查 |
| ✅ POST | `/auth/pair` | `{pairing_token, device_name, platform}` → `{client_id, access_token, refresh_token, expires_in=86400, refresh_expires_in=2592000}`；主令牌错误返回 `code=40100` |
| ✅ POST | `/auth/refresh` | 匿名白名单；`{refresh_token}` → 轮换式换发新 `{access_token, refresh_token, ...}`；无效/过期返回 `code=40102` |
| ✅ POST | `/auth/unpair` | 自我注销（吊销当前设备） |
| ⏳ GET | `/meta/server` | 版本、ffmpeg 可用性、源概况（需认证） |

### 4.2 曲库与流媒体（已移除）

> 服务端不提供曲库索引与流式代理：歌曲由 App 在各播放源处扫描、直接从源播放；
> 后端仅提供认证/配对与状态同步（§4.4）。原 `/library/**`、`/stream/**`、
> `POST /songs/{id}/weight` 已删除。

### 4.4 状态同步 —— ✅ 已实现（阶段 5）

| 方法 | 路径 | 说明 |
|------|------|------|
| ✅ GET | `/api/v1/sync/pull?since_cursor=` | 增量拉取（歌单+权重+断点快照），返回新 cursor；`since=0` 为启动全量校准；超 2000 事件分页（`has_more`） |
| ✅ POST | `/api/v1/sync/push` | 批量上推事件流水；幂等按 `event_uuid` 去重；LWW 判输回 correction 快照；`device_client_id` 须与认证身份一致 |
| ✅ CRUD | `/api/v1/playlists` 系列（含 `{id}/items` 增删改） | 直接 REST 变更同样走事件管线（服务端代写事件），其它设备经 pull 可见 |
| ✅ PUT | `/api/v1/playstates/{playlistId}` | `{source_id, source_ref, position_ms}`；行级 LWW，判输回服务端快照 |

### 4.5 管理

| 方法 | 路径 | 说明 |
|------|------|------|
| ✅ GET | `/admin/pairing-token` | 主配对令牌明文（`设置→服务端→配对服务器` 展示用；密钥源自 env 镜像） |
| ✅ GET | `/admin/devices` · PUT/DELETE `/admin/devices/{id}` | 设备列表 / 改名 / 吊销 |
| ⏳ POST | `/admin/upload/init` → `/part/{n}` → `/commit` | 分片上传（16MB/片），阶段 6 |
| ⏳ PUT | `/admin/settings` | 设置读写（已实现 GET `/admin/config`，写接口仍规划） |

---

## 5. 后端模块与选型

### 5.1 包结构（`com.selfmusic.backend`，现状以代码为准）

> 带注释的仓库目录树见 [DEVELOPER.md「项目结构」](DEVELOPER.md#项目结构)。

```
auth/         AuthController(pair/refresh/unpair) + DeviceAdminController + SecurityConfig + TokenFilter
admin/        AdminSettingsController(config/pairing-token)
controller/   HealthController
common/       ApiResponse, BizException, GlobalExceptionHandler
config/       FirstBootInitializer, WebConfig(CORS)
domain/       JPA 实体（Playlist/PlaylistItem/PlayState/SongState/Device/SyncEvent/Setting）+ Repository + service
```

### 5.2 第三方库

| 用途 | 选型 | 备注 |
|------|------|------|
| SMB | `com.hynnet:java-smb`（jSMB/smbj 系） | PoC 先行，见风险 R1 |
| WebDAV | JDK 内置 `java.net.http`（PROPFIND 等） | 不引框架 |
| 标签 | `net.jthink:jaudiotagger` 3.x | 不支持的格式 ffprobe 兜底 |
| 转码 | 系统 `ffmpeg` 子进程 | 镜像内 apt 安装 |
| Token 哈希 | JDK `MessageDigest` SHA-256 | 不引额外依赖 |

### 5.3 认证过滤器

```
TokenFilter (OncePerRequestFilter)
  ├─ 白名单: /api/v1/health, /api/v1/auth/pair, /api/v1/auth/refresh
  ├─ 解析 Bearer → SHA-256 → 查 devices(token_hash, revoked=false)
  ├─ 命中且 access 未过期: 注入 DeviceContext(client_id)，刷新 last_seen_at（节流 60s）
  ├─ 命中但 access 已过期: 设响应头 X-Token-Expired: true，且不放行（→ 前端触发懒刷新）
  └─ 未命中: 401 {code:40101}
```

### 5.4 Docker 镜像

| 镜像 | 基座 | 变化 |
|------|------|------|
| prod | `eclipse-temurin:21-jre` | apt 加 `ffmpeg`；复用基镜像自带 `ubuntu` 用户运行（UID 1000，与 dev 对齐；自建同 UID 用户会构建失败） |
| dev | `maven:3.9-eclipse-temurin-21` | 同上加 `ffmpeg`（保持与 prod 行为一致） |

环境变量：`PAIRING_TOKEN`（可选，配对密钥权威来源；每次启动覆盖写入 settings，改后重启即生效；仅在首次初始化时以 WARN 打印一次密钥）、出流代理 `LOCAL_MUSIC_ROOT` / `WEBDAV_BASE_URL` / `WEBDAV_USER` / `WEBDAV_PASS`（库中既有行出流用）、其余同 v1。服务端扫描相关 env（`SCAN_*`）已随扫描移除而作废。

---

## 6. Flutter 客户端设计

### 6.1 客户端分层（`lib/`）

客户端按「**UI 壳 → 状态 → 数据**」三层组织，模块与职责如下（文件级目录树见 [DEVELOPER.md「项目结构」](DEVELOPER.md#项目结构)）：

| 模块 | 职责 |
|------|------|
| `main.dart` | 入口 + Provider 装配（Theme / Auth / Library / Player / Navigation）+ 平台 bootstrap |
| `theme/` | ★ 可配置主题核心：语义化颜色 token + 亮/暗与自定义强调色，运行时切换并持久化 |
| `layout/` | ★ 自适应模块化布局：桌面「侧边栏 / 内容 / 队列面板」与窄屏抽屉；顶栏（搜索 + 六分组滑动导航）；队列面板与迷你播放条（自动定位当前曲、强调色） |
| `providers/` | ★ 状态：导航（层级返回）、播放器（队列 / 四模式 / 睡眠定时（含到时退出软件）/ 歌词 / 预载 / 断点）、曲库（多源合并 + 专辑歌手分组）、直连源管理、歌单、配对与会话过期态 |
| `services/` | ApiClient（含懒刷新拦截器）、AuthService、ServerSettings、SyncEngine |
| `data/sources/` | ★ Source 抽象层（LocalDirect / WebdavDirect / SmbDirect）+ DirectAudioSource |
| `data/local/` | 本地库（`schema` 建表迁移 + `db_writer` 写隔离 + `local_index` 门面）+ 纯 Dart 头部解析 + 各 Store 封装 |
| `models/` `utils/` | 数据模型（Song / Album / Artist）；纯工具（时长格式、标题显示格式、LRC 解析） |
| `widgets/` | 共享组件（SongTile、CoverThumb、歌词页、加入·编辑歌单、列表·卡片切换、SortMenuButton、**AppToast 浮层弹窗**等）。`SongTile` 的 leading 恒为 `CoverThumb`（多选态为复选框），**播放指示 `Icons.graphic_eq` 跟在标题之后**而非顶替封面，由调用方传 `playing`（`PlayerProvider.isCurrent(s)`）；`SortMenuButton` 为两行合一弹窗：字段行 + 行内上下箭头，点箭头选方向、点字段名翻转方向。**AppToast**（改进.txt §1-1/1-2）：错误与成功统一 toast、不侵占 UI 文字；等宽浮层弹窗——强调色半透明背景（错误保留红 + 加透明度）、文字居中、`IgnorePointer` **点击穿透不阻碍被遮挡控件**；经根 `appNavigatorKey` 弹入 Overlay，同一时刻仅最新一条 |
| `platform/` | ★ 平台收口层：平台差异收敛于此，新增平台只补 `platform/<target>/`，不动上层 |
| `screens/` | 内容区 / 歌单 / 播放源 / 源内浏览 / 设置 / 播放页 / 配对 / 设备管理 |

> **为什么要有 `platform/` 层**：鸿蒙走三方 Flutter 分支而非官方 target，`Platform.isXxx` 行为与原生插件实现均可能与官方平台不一致，
> 因此业务代码禁止直接写平台判断，一律经 `lib/platform/` 收口。
> 现状、写法与鸿蒙实现见 [DEVELOPER.md「平台收口层」](DEVELOPER.md#平台收口层libplatform) 与「[鸿蒙适配](DEVELOPER.md#鸿蒙适配)」。
> 本地库用 `sqlite3` 轻量版（schema 统一建表迁移 + 后台写隔离），**不引 drift**；表结构见 §3.2。

### 6.2 Source 抽象层（双模式的基石）

```dart
abstract class MusicSource {
  String get key;                       // 稳定标识: 'smb:nas1'/'webdav:xx'/'local:xx'
  SourceKind get kind;
  Future<ScanResult> scan();            // 建本地索引（增量）
  Future<SongMeta> probe(String ref);   // 头部元数据（Range 读头部）
  Stream<List<int>> open(String ref, {IntRange? range}); // 音频流
  Future<void> close();
}
```

- 播放器只认 `MusicSource`（全部为直连实现）
- 直连播放优先级：离线缓存文件 → `directStream()`（原生 URL，ExoPlayer/native Range seek 更稳，WebDAV 用）→ 自建 `StreamAudioSource`（`open()`）回落
- WebDAV `ref` 存**解码后**路径（标题/去重友好），请求时按路径段重新编码；扫描头部元数据解析对大内嵌封面做了边界保护（超采样长度即停止解析，不抛 `RangeError`，随后按提示补读）
- 源列表 = `sources` 表里启用的源；配置后端地址后解锁多设备同步（与曲库无关）

### 6.3 SMB 直连平台策略（全平台目标）

| 平台 | 方案 | 工作量 |
|------|------|--------|
| Windows | 系统挂载（UNC `\\host\share\path`），`dart:io` 直接读 | 小 |
| Android | 平台通道嵌入 JVM **smbj**：Dart 侧请求 `open(ref)` 得 `sessionId`，循环 `read(sessionId, offset, len)` 取字节流喂 `StreamAudioSource` | **大（R1）** |
| 鸿蒙 | 复用 Android 通道方案；若三方 Flutter 分支通道兼容有问题 → 该端降级"直连仅 WebDAV" | 中（待验证） |

- 传输细节：smbj `InputStream` + 共享池；单次读 256KB；连接复用（每源一个 Session）
- 断点续播：`StreamAudioSource` 支持 Range 起播，seek 时重建流

### 6.4 直连模式本地轻量索引

直连源在客户端建本地索引（SQLite `idx_songs`，表结构见 §3.2）。**这一层的设计意图**是：让「直连一堆协议源」在体验上等价于一个一体化本地曲库，而流量与耗电可控。

**扫描流程（首次）**

- 列目录：WebDAV `PROPFIND Depth:1` 递归 + `_mapConcurrent` 并发（并发 6）；本地文件夹 `Directory.list(recursive:true)`
- **不读音频内容**：快速扫描只用枚举结果（ref/size/mtime/etag）落库，歌名取文件名，零 Range 请求。音频解析（`audio_metadata`，纯 Dart 支持 mp3(ID3v2) / flac / m4a(mp4) / ogg·opus / wav / aac(ADTS)）全部推迟到播放时补读与后台补读，按结构定位后精确 Range（见下方「补读」）
- 单事务批量 `upsertSongs` 落库 → `persistCover`（封面落 `covers/<hash>.jpg`，SQLite 存路径）→ `markMissingExcept`/`clearMissing` 标记消失项（保留缓存歌可播性）
- 大目录保护：单源上限 20k 首，超出提示分目录添加

**增量与扫描方式**

- 增量指纹 `(ref, size, mtime, etag)`：WebDAV 从 PROPFIND 解析 `getlastmodified`/`getetag`/`getcontentlength`；本地扫描 `stat` 取 size/mtime；**四元组未变直接跳过读头 → 二次扫描零音频下载**
- 扫描方式**写死「快速：只建索引」**（原 `scan_mode`/`scan_head_bytes`/`scan_embed_cover` 三个设置项已删除）：只用枚举拿到的 ref/size/mtime/etag 落库，零读头请求。六类格式均支持
- **取舍**：首扫只求「先让曲库能被搜到」，不求元数据齐全。缺的信息由播放时补读与后台补读按结构定位后精确读取补齐（那两条链路知道歌马上要放），而不是让首扫对整库盲目读头。代价：首扫无时长，故时长过滤要等补读到时长后才生效
- 播放时懒补全：`minimal` 入库的歌缺 时长/流派/年份/封面 → `PlayerProvider` 播放后后台 `open` 读头解析并 `enrichSong` 回填，失败不影响播放
- **播放时必然重读**：`_enrichLazily` 不依赖索引缓存，任何歌开始播放都再次读头解析并回填（兼修正断点/歌单旧快照），保证切歌即时刷新
- **读头部可能需要多段**：大内嵌封面（常见 1~3MB）一段读会整块丢失，moov-at-end 的 m4a / ogg 时长 / mp3 ID3v1 在文件尾部——因此有「两段读」与「尾部补读」策略。
  具体的 hint 计算、声明值上限（`kMetaRegionCapBytes` 16MB）、几何放大与结构跳的分工、同目录图片与 `.lrc` 回退优先级、一次性重取迁移（`kCoverReenrichV1Done`）等实现细节见 [DEVELOPER.md「客户端扫描与元数据」](DEVELOPER.md#客户端扫描与元数据实现要点)
- **全局后台补读**：任一首开始播放后，后台逐个补读各直连源「尚未读取过元数据」的歌曲（`DirectSourceManager` 分批循环读头回填），专辑/歌手/封面在扫描未覆盖时也能逐步补齐并在 UI 就地刷新（`LibraryProvider` 监听元数据版本号）
- **用户编辑优先于扫描**：播放页「修改歌曲元数据」落 `user_edited=1`，扫描不再覆盖（`LocalIndex.updateSongUserMeta` / `DirectSourceManager.updateSongMeta`）

**进程隔离与进度**

- 扫描在独立 Isolate（`scan_worker.dart` `runScan`：Isolate.spawn + 握手 `__cancel__` 通道 + 进度 `ScanProgress` 回调，listing/探测两阶段）；HTTP 客户端 / DB 句柄 / `LocalIndex` **不得跨 isolate**
- 进度事件经 `DirectSourceManager.scanProgressStream` 广播，UI（`SourceBrowseView`）节流渲染进度条并支持取消；`_inFlightScan` 全局互斥防重复扫描

**本地文件夹源与自动扫描**

- `LocalDirectSource`（全平台）：`key='local:<name>'`、`kind=local`；文件本体即缓存，`cachedFilePath` 直接返回绝对路径走 `setFilePath`；Android 读共享存储需运行时 `READ_MEDIA_AUDIO`(13+)/`READ_EXTERNAL_STORAGE`(≤12) 权限，扫描前申请
- 自动扫描：本地 `Directory.watch(recursive)` 变化去抖 2s 触发增量；`scan_auto_interval_min` 周期增量（WebDAV 协议无推送，靠周期低流量快扫兜底）

**健壮性取舍**

- 头部越界保护：元数据块声明长度超出头部采样即停止解析，不抛 `RangeError`（大内嵌封面场景）
- 时长探测：mp3 估算法（文件大小÷码率）或解析 Xing/VBRI 头；flac 读 STREAMINFO
- 旧索引乱码修复：`idx_songs` 行经 `upsert` 无条件覆写，重新扫描即自动更新，无需手动清库
- 各格式的文本编码解码规则见 [DEVELOPER.md「客户端扫描与元数据」](DEVELOPER.md#客户端扫描与元数据实现要点)

### 6.5 源内文件夹式浏览与全局歌曲合并

- 所有播放源默认激活（移除旧「单一激活源」概念），`direct_source_manager.dart` 仅维护源列表与本地索引，不再持有 `_activeKey`
- 点击源卡片 → `NavigationProvider.enterSource(key)` 将 `browsingSourceKey` 置为该源 key → `AppContent` 检测到 `sources + browsingSourceKey` → 内容区原地切换为 `SourceBrowseView`（不走 `Navigator.push`）
- `SourceBrowseView`：顶部返回按钮调用 `exitSource()`、显示源名、扫描/刷新按钮、搜索框、歌曲计数；扫描完成后自动调用 `LibraryProvider.loadSongs()` 刷新全局合并库
- 源列表页（`SourcesScreen`）支持**列表 / 卡片**两种展示（右上角切换，持久化 `view_mode_sources`，见 [settings.md](settings.md)）；列表行复用卡片组件（`plain` 参数）
- 源卡片右侧 `PopupMenuButton` 三点菜单：编辑、删除源（二次确认弹窗）
- 新增/编辑源弹窗统一为 `_SourceDialog`：添加态用 `SegmentedButton` 选 WebDAV/本地文件夹（本地态提供「选择目录」走 `file_selector.getDirectoryPath`）；编辑态按 key 从 `LocalIndex` 原始配置预填（密码从 SecretStore 回填），改名会派生新 key 并同步迁移 `sources/idx_songs/play_meta/playlist_items`（`LocalIndex.renameSource`）
- 全局歌曲/专辑/歌手合并：`LibraryProvider.loadSongs()` 聚合 `DirectSourceManager.allSongs()`；专辑和歌手按合并后的歌曲列表客户端聚合（`Album.fromSongs` / `Artist.fromSongs`），切换到对应栏目时自动拉取
- **列表排序**（`utils/collection_sort.dart` + `widgets/sort_menu_button.dart`）：按 `SortScope` 开放字段——
  歌曲类内容页（喜欢 / 歌曲 / 歌单详情）为 默认排序 / 字符 / 权重 / 播放时长 / 播放次数 / 时长，
  集合类内容页（歌单 / 播放源 / 专辑 / 歌手）为 默认排序 / 字符 / 曲数，每个字段各有升降序；
  选择逐页持久化在 `app_settings`（`sort_songs / sort_favorites / sort_playlist_detail / sort_albums /
  sort_artists / sort_playlists / sort_sources`，值存枚举名，`CollectionSort.parse` 对未知值回落默认排序）。
  播放时长与播放次数都来自 `play_meta.play_sec`（见 §7.1），由调用方注入 `playSecOf` / `countOf` 读取函数，
  取不到值的行排在末尾。菜单为「字段 + 行内方向箭头」两行合一（点箭头选方向、点字段翻方向），当前方向以强调色标出
- 播放路由：`PlayerProvider.attachSourceResolver` 注册解析函数，按歌曲 `sourceKey` 逐首从 `DirectSourceManager.sourceByKey` 解析源实现；无本机源的快照行不参与播放

### 6.6 网络与离线

- `dio`：API 超时 5s、指数退避重试 3 次；流式请求超时 ∞
- **懒刷新拦截器（ApiClient）**：`onRequest` 自动带 `Bearer access`；`onError` 命中 `401 + X-Token-Expired` 时用 `refresh_token` **单飞（single-flight）**换发新 token 并对原请求重放一次；刷新失败清空令牌并触发 `onSessionExpired` → "会话过期"弹窗重新配对。
- 断网判定：连续失败 → 进"离线模式"，UI 顶栏提示；播放范围收缩为 `cache` 命中项
- 恢复网络：SyncEngine 自动恢复，先推 outbox 再拉增量

### 6.7 客户端用户设置（✅ 已实现）

> **设置项的权威清单在 [settings.md](settings.md)**（键名、默认值、入口、生效范围、实现顺序），本文不重复抄表。
> 设计上的两点约定：
>
> 1. **单设备体验优先**：客户端设置完全本地闭环、离线可改；与服务器同名的配置项（缓存上限等）采用「跟随服务端 / 自定义」双来源
> 2. **职责单一**：一个配置只属于一个分区，不在多处重复出现（如配对密钥归入「服务端 → 配对服务器」，设置页只做遮显、副标题复用同一份值）

侧边栏 6 个分区面板均已落地：

| 分区 | 内容 |
|------|------|
| 备份 | 设置 / 歌单分开导出导入 |
| 播放 | 默认播放模式、断点续播、淡入淡出、均衡器（Android）、播放页手势、睡眠定时（四模式 + 时长/曲数记忆 + 播完退出）、音频焦点 |
| 服务端 | 后端地址、配对服务器（含配对密钥遮显）、预载、缓存配置双来源、允许不安全 HTTP、信任自签名证书 |
| 歌曲 | 收藏自动缓存、扫描方式（写死快速：只建索引）、忽略音频过滤、仅 Wi-Fi 扫描、标题显示格式、集合页展示形式 |
| 界面 | 主题（亮/暗/强调色）等 |
| 通知 | 通知栏播放控制 / 后台播放开关 |

网络与凭据相关的两个开关（`allow_insecure_http` / `allow_self_signed`）是**安全边界**而非普通偏好：关时显式 `http://` 地址被拒、缺 scheme 恒默认补 `https://`，约束后端 / WebDAV / 配对地址；自签名信任只作用于 dio 与直连 WebDAV 的 TLS 回调，播放器层不受影响。

### 6.8 歌词与后台播放

- **歌词三通道**：内嵌标签（mp3 `USLT` / FLAC `LYRICS`·`UNSYNCEDLYRICS`）→ 同目录同名 `.lrc`（local/WebDAV 通用，UTF-8/UTF-16 BOM 兼容）（后端不提供歌词）；解析为 LRC 文本入库 `song_lyrics`（`(source_key,song_ref)` 主键，三态：内容 / 显式标记缺失 / 未读取），缺失标记避免每次播放重复读文件
- **歌词页**：与播放进度同步滚动 + 居中高亮当前行 + 点击任意行 seek；手动拖动暂停跟随，空闲「歌词追焦等待」超时后回中，切歌归位；`lrc_parser.dart` 支持多标签 / `offset` / 毫秒位数 / 纯文本退化 / 二分定位
- **歌词跟焦为自愈式**（`lyrics_view.dart`）：每次位置事件都按真实布局复核当前行是否在位，不以「行号是否变化」为触发条件——`ListView.builder` 懒构建导致目标行尚未构建（`PageView` 滑入时该页才刚创建）时，先临时把 `cacheExtent` 加宽让目标行被构建出来（经典 `double` 写法以兼容 ohos 分支，最多补滚 3 次），再用 `RenderAbstractViewport.getOffsetToReveal` 只滚歌词列表（不用 `Scrollable.ensureVisible`，避免遍历祖先把外层 `PageView` 一起拖动）；首次归位 `jumpTo`、换行 `animateTo`，行高动画后再快速二次校正一次；拖动抑制为续期式空闲计时（`ScrollStart` 即启动，拖动/惯性中不断续期），手势被打断收不到 `ScrollEnd` 也不会永久卡住
- **后台播放**：Android 走 `audio_service` 自定义处理器（`SelfMusicAudioHandler`，通知按钮转发 `PlayerProvider`）；返回桌面/切后台**继续播放**（`androidStopForegroundOnPause=false` 暂停不撤前台服务，与 `androidNotificationOngoing` 互斥故弃用 ongoing）；通知栏「退出软件」/ 划掉任务（`onTaskRemoved`）/ 侧边栏「退出」（先 `shutdown()` 再 `exit(0)`）才真正停止并置空闲；`notification_controls=false` 时不注册前台服务、后台保活不成立
- **通知栏 5 键（自定义 `SelfMusicAudioHandler`）**：`main()`（Android 开关注册）用 `AudioService.init(builder:)` 装自研 handler，不再走 `just_audio_background` 的默认 4 键。`sync()` 回推的 `PlaybackState.controls` 为 5 键——上一首 / 播放·暂停（随播放态二选一）/ 下一首 / 播放模式 / 退出软件，`androidCompactActionIndices=[0,1,2]`；前四个与「退出软件」用 `MediaControl` 自绘品牌矢量图标（`ic_np_previous/play/pause/next/mode/exit.xml`，`0xFF00A098`），播放模式与退出是 `MediaAction.custom` + `CustomMediaAction(name: 'play_mode'/'exit_app')`，回调经 `customAction` 转发 provider：`play_mode`→`cycleMode()`（与播放页模式按钮同序循环），`exit_app`→`shutdown()` 落盘断点后 `super.stop()` 收前台服务再 `exit(0)`。不劫持 just_audio 平台实例，状态变化全由 provider 的 `_syncSystemMedia()` 调 `sync()` 驱动（Android `MediaSession` 自动外推 position，无需逐 tick 上报）
- **鸿蒙媒体播控（AVSession 桥，与 Android 同构的非劫持薄转发）**：鸿蒙没有应用自绘媒体通知，媒体卡由系统统一渲染（通知栏 / 锁屏 / 播控中心三处）——provider 同一 `_syncSystemMedia` 时机全量推送元数据 / 播放态 / 收藏 / 内嵌歌词至 ArkTS `AvSessionBridge` 喂 `AVSession`，配 `backgroundTaskManager` AUDIO_PLAYBACK 长时任务（媒体卡即鸿蒙的通知形态，无第二条常驻通知）；LoopMode 显式 int 映射（sequence→SEQUENCE / loopOne→SINGLE / loopList→LIST / weighted→SHUFFLE）；封面两段式（元数据先行秒出卡片，PixelMap 异步解码补推，同曲去重 + 快速切歌票据竞态淘汰）。实现细节与真机验收见 [DEVELOPER.md「鸿蒙适配」](DEVELOPER.md#鸿蒙适配)
- **睡眠定时（含到时退出）**：四模式无变化（指定时间 / 时长 / 曲数 / 列表结尾 + 播放完最后曲目），新增弹窗 UI 与语义——四种模式卡片改用小字号正文 + 灰色提示行；「指定时长/曲数」用滚轮选择并**记忆上次值**（持久化 `sleep_default_duration_minutes` / `sleep_default_count`，下次打开预选）；新增「播放结束退出软件」开关（仅当次生效）。到时行为：退出开关开时 `_sleepStop()` 先读 `_sleepExitApp` 落局部再清睡眠态，走 `_quitAfterSleep()` = `await shutdown()`（落盘断点/队列）后 `exit(0)`；否则维持原有「暂停并驻留后台」
- **播放页（带式）控件自动隐藏（`player_auto_hide_idle_sec`，默认 5，0=不隐藏）**：仅播放页（滑带的第 1 页，竖屏/横屏同位）计静置；超时淡出左上「返回内容」与封面右上「更多」两个纯入口（封面/进度条/控制键常显）；根布局 `Listener(translucent)` 任何触摸都 `_rearmAutoHide()`（取消旧定时 → 恢复显示 → 重设定时），进入歌单页 / 歌词页 / 切到内容区不参与隐藏
- **歌单页并入播放器横滑带（`lib/screens/player_screen.dart`）**：竖屏 `PageView` 三页 `[歌单页 | 播放页 | 歌词页]`、横屏两页 `[歌单页 | 整幅播放布局]`，切换全部由内层 `PageView` 原生跟手（与播放页↔歌词页一致的横向拖动体验，**不受「页面切换动画」设置影响**；手势关闭时禁滑、封面「更多」菜单补「歌单」入口点按跳页）。歌单页在**有绑定歌单**时展示持久化歌单——与内容区歌单详情共用 `widgets/song_list.dart` 的 `SongList`：同源（`PlaylistsProvider` + `LocalIndex`）、同行形态（完整 `SongTile`）、同写回语义（移除/上移/下移改写真实歌单并经 `onPlaylistSongRemoved` 联动播放器）；保留「播放 / 从头播放」按钮，**无**左上返回箭头与右上关闭（右滑即回播放页）。**无绑定歌单**（全部歌曲/喜欢/专辑/歌手/播放源点播）时兜底展示运行时播放队列（`lib/screens/queue_page.dart`：搜索 / 排序 / 当前曲高亮 / 单曲移除 / 清空 / 多选批量移除）

### 6.9 列表 / 卡片 / 多选（✅ 已统一）

> 此前同一形态在 10 处各写一遍：行高与分隔线缩进字面量、4 份逐字相同的行包装器
> （`_AlbumRow`/`_ArtistRow`/`_playlistRow`/`_SourceRow`）、歌单详情与队列两处自绘歌曲
> 行、4 页各自的视图模式样板。现在按「外壳 / 行 / 卡片 / 多选」四层收口。

**四层职责**

| 层 | 载体 | 约定 |
|----|------|------|
| 外壳 | `widgets/row_list.dart` 的 `RowList` | 唯一固定行高列表外壳：统一 `itemExtent`、分隔线缩进、末行不带线、可选下拉刷新；行本体由调用方给 |
| 行 | `widgets/song_list.dart` 的 `SongTile` | 唯一歌曲行：封面 + 标题 + 副标题 + 时长/菜单；集合类行（歌单 / 专辑 / 歌手 / 播放源）用 `ListTile` + `CoverThumb` |
| 卡片 | `widgets/square_card.dart` 的 `SquareCard` / `SquareCardGrid` | 唯一方形卡片：封面恒 1:1（列宽按可用宽度算，不写死 `childAspectRatio`）、标题 2 行上限、按「最大宽 × 设备像素比」降采样解码 |
| 多选 | `widgets/list_selection.dart` 的 `Selection<T>` + `widgets/selection_bar.dart` | 选择状态内核与批量栏；勾选标记统一 `widgets/selection_badge.dart` |

**几何常量**（`row_list.dart`，改动须同步 `playlists_view_test` 的 `itemExtent` 断言）

| 常量 | 值 | 含义 |
|------|-----|------|
| `kRowHeight` | 72 | 行高（双行 `ListTile`） |
| `kRowSeparatorHeight` | 1 | 分隔线 |
| `kRowExtent` | 73 | `itemExtent`，供 Sliver 虚拟化与深位置定位 |
| `kRowDividerIndent` | 72 | 分隔线缩进（与 44 封面 + 左右内边距对齐） |
| `kListHeaderHeight` | 44 | 计数头与多选栏等高（进出多选模式内容不跳动） |

**为什么 `itemExtent` 不能省**：没有它时 Sliver 为定位深处目标需从第 0 行逐行排到目标行——千首歌单一帧构建 700+ 行与封面，进入必卡（实测 712 项 vs 16 项，`playlists_view_test` 有回归用例）。

**行形态**

- 标题**常驻加粗**（`w600`），播放中 / 选中只再叠主色区分，不靠字重跳变；卡片标题同为 `w600`，两形态一致。
- 封面位恒为封面（改进.txt）：播放指示（`graphic_eq`）排在标题之后，不顶替封面。
- 播放页 / 队列面板 / 队列兜底页与内容区歌曲列表**同一完整行形态**（封面 + 标题 + 副标题 + 时长/菜单）：`SongTile` 不再有 `compact` 紧凑形态，队列原有第 4 份自绘行与其一并移除。
- `SongTile.extraMenuItems` / `onExtraMenu`：歌单详情的上移 / 下移 / 移除追加在内置项之后（自定义 value 用 `row:` 前缀避免撞名）。
- 集合类 leading 统一 `CoverThumb`（`shape` 圆形/圆角 + `fallbackIcon`），歌手保留圆形。

**多选语义**

- 勾选框**叠在封面左上角**（`SelectionBadge`，半透明圆形底衬），不再用勾选框顶替封面——多选时仍能靠封面认出是哪首；无封面的行（歌单行的 `queue_music` 图标）才由勾选框顶替。
- 多选态隐藏单曲三点菜单（防误触），保留时长作为信息；卡片隐藏右上角角标菜单。
- 「已选 N」、全选与批量动作的口径统一为**当前可见项**：搜索过滤后不统计、也不作用于被过滤掉的项。
- 队列面板不参与多选。

**视图模式**：`ViewModeState` mixin + `ViewModeSlot`（`view_mode_toggle.dart`）收口歌单 / 播放源 / 专辑 / 歌手四页的切换逻辑；切换写 SQLite 设置不触发 provider 通知，故 mixin 内保留 `setState` 本地覆盖。

---

## 7. 播放算法与同步协议

### 7.1 加权播放（蓝图 §三.2 的落地）

设列表 n 首（n≥2）：

```
基础权重 w₀ = 1/n
weight = w₀ × factor
factor ∈ [0.5, 1.5]，连续取值、步长 0.1，初始 1.0：
  连续完整播放（like_streak≥3）→ factor 提高 0.1（上限 1.5）
  连续中断（dislike_streak≥3）→ factor 降低 0.1（下限 0.5）
  liked / 手动喜欢        → factor 直接 1.5（并解除「不喜欢」锁定）
  手动不喜欢（开关）       → factor 直接降到最低 0.5 并锁定（frozen=true）
  frozen=true（不喜欢锁定）→ 权重锁定最低值，跳过自动调权
选中概率 p_i = factor_i / Σfactor_j（对候选集合归一化）
```

选歌（加权随机模式，`PlayerProvider` 实现）：**并非无放回抽取**——每步从队列**全量**（排除上一首，
n≥2 时对剩余归一化）按 factor 采样，喜欢的歌因此可在一轮中播放多次、不喜欢的歌可能要若干轮才播一次，
无固定"单轮"长度，每步独立随机采样。

**时长削弱**（改进.txt 功能8，设置`>歌曲`：`curve_weight_enabled` + `curve_weight_segments`）：
`_weightedPickIndex` 在抽样时按歌曲时长乘分段系数 `effective = factor × curve(duration)` 再钳回 [0.5,1.5]。
分段作用域 `[min,max)` 命中第一段即止，`max=null` 表示「超过 min 恒生效」（即「超过设定值」的开启要点），
未命中 / 时长未知 = 1.0（不削弱）。**仅抽样侧即时计算**：不落库、不改 `play_meta`、服务端零改动；
队列下一首与歌单加权起播共用同一入口。

事件规则（阶段 2 为**纯客户端本地**落地，后端逻辑与服务端一致、以服务端为准，阶段 5 再接同步上推）：

| 事件 | 触发 | 效果 |
|------|------|------|
| complete | 自然结束且播放比例 >95% | like_streak++，dislike_streak=0；非锁定态 like_streak≥3 → factor=min(1.5, factor+0.1)、streak 清零；不喜欢锁定态只记 streak 不调权 |
| complete_manual | **用户手动点播**且自然完播（>95%；时长不可判定而自然结束也按手动完播记一行）+0.1 直达一档 | **like_streak=0、dislike_streak=0，factor=min(1.5, factor+0.1)**（不依赖 3 次门槛——主动点选并听完本身就是强正面信号，改进.txt 功能7）；不喜欢锁定态不动权重 |
| skip | 被 next/prev/换歌打断且比例 <30% | dislike_streak++，like_streak=0；非锁定态 dislike_streak≥3 → factor=max(0.5, factor−0.1)、streak 清零；不喜欢锁定态只记 streak 不调权 |
| liked | 手动喜欢 / 收藏 | favorite=true，factor=1.5，解除「不喜欢」锁定（frozen=false） |
| unfavorite | 取消喜欢 / 收藏 | favorite=false；非锁定态 factor 回 1.0；不喜欢锁定态保持最低权重 |
| disliked | 手动不喜欢（开关式） | favorite 不变；开 → factor=0.5 且 **frozen=true（权重锁定最低、跳过自动调权）**；关 → 解锁回 1.0 |
| reset | 手动重置 | 双 streak 清零，factor 回 1.0，解除「不喜欢」锁定 |

> complete_manual 的触发集合：仅**用户主动选择**（playAt / playQueue / 播放页点行 / 歌单「播放全部」）——`_play(manual: true)`
> 起始的歌自然完播才计数；`next()`/`prev()`/自动下一首/失败重试均为非手动起点（`manual: false`），不算。后端 `SyncService`
> 与本地 `db_writer` 严格镜像同一语义（含「不喜欢」锁定态不动权重），事件经 `song.complete_manual` 同步。

播放模式：`sequence`（当前顺序播放，播完即停）/ `loopList`（列表循环）/ `loopOne`（单曲循环）/
`weighted`（加权随机），切换入口播放页 + 队列面板；`next()` 与自动下一首按当前模式路由。

**歌单起播**（`PlayerProvider.startIndexForPlaylist` → 纯函数 `startIndexForOrder`）：歌单详情「播放」
的**起始曲**同样按当前模式决定，而非固定从头——加权随机按权重抽样（与队列下一首共用
`_weightedPickIndex`）、列表循环接续当前曲（末尾回绕）、顺序/单曲循环取首曲。队列本身仍按歌单
当前排序装载（不按模式重排），「从头播放」是显式例外：固定首曲且不读远端断点。

**播放统计**（`play_meta.play_sec` + `utils/play_stats.dart`）：播放次数不单独落库，由**累计播放秒数**派生——
`播放次数 = play_sec / duration`，展示保留 1 位小数（= 四舍五入的「次」），同时可显示 `x 小时 y 分` / `y 分 z 秒` 标签。
采集用**挂钟口径**（`DateTime.now` 差值，不采样播放位置），因此后台/息屏节流不影响统计；结算点为
「暂停 / 切歌 / 退出 / 播放位置事件」四类，落库走 `DbWriter.addPlaySec`（写连接内累加），
写隔离关闭前 flush。挂钟口径的代价是「暂停后立刻切歌」会按 0 秒结算，故以 `>=1s` 为有效增量。

**深层列表**（`data/deep_list.dart`，隐藏能力）：锚定列表的「仅可修改末尾值」有界历史栈，容量 = 该列表歌曲总数。
列表内播放推入末尾（超容量视为播完一轮，清空后从当前曲重来）；外部点歌只替换末尾、不切换锚定；「上一首」弹出末尾并重播新的末尾。
**不影响「下一首」语义**——未来播放顺序仍由队列与加权算法决定。它是显式改动加权随机「同首不连续」观感的手段。

> **写路径**：调权/收藏不是「先算再存」，而是由 `applyWeightEvent` 等 op 在**写连接的单个事务内**完成读改写并同时入 outbox，
> 避免与并发收藏/歌单写互相覆盖。实现约定见 [DEVELOPER.md「客户端同步与缓存批处理」](DEVELOPER.md#客户端同步与缓存批处理)。

### 7.2 同步协议

- **方向**：客户端本地 SQLite 是运行时事实源；后端是多设备汇聚点
- **Pull**：启动全量校准 + 每 30s `GET /api/v1/sync/pull?since_cursor=`；cursor 为服务端 `sync_events.seq` 单调递增变更号
- **Push**：本地产生权重事件/断点/歌单改动 → 写 `weight_outbox`（带 event_uuid）→ 2s 防抖批量上推；服务端按 uuid 幂等去重
- **累计播放时长**：`play_sec` 随 `song.state` 上下推（服务端 `song_states.play_sec` 行级 LWW），客户端应用快照时取 `max(本地, 服务端)` 单调合并，累计值不会因乱序/旧快照倒退
- **冲突（字段级合并，阶段 5 落地）**：权重走**事件重算**而非绝对值覆盖（两设备并发点赞按到达序重放，不互抹）；收藏/歌单元数据/删除墓碑/断点走**行级 LWW**（事件 `occurred_at` vs 行 `last_event_at`，输方收 correction 回执自纠；仲裁时钟为服务端 `arrived_at`）；歌单条目按 seq 到达序重放（后到达胜出）；直接 REST 变更（歌单 CRUD/断点 PUT/调权 POST）同样先记事件再生效，保证 pull 可见
- **歌曲身份**：服务端无曲库，统一为 `source_id + source_ref`（source_id=客户端源实例 uuid，旧数据/旧客户端为 `legacy:<协议>`）；权重/收藏落 `song_states`，歌单条目与断点自持身份及展示快照（标题/歌手/专辑/时长，pull 不覆盖客户端本地标题）；pull 身份收集恒不建行（已删歌曲不复活）。未配对（无后端地址）时直连事件不进队，避免 outbox 无限积压；`sync_enabled` 关闭同样全跳
- **播放源同步**：`source.create/update/delete` + 行级 LWW；身份 `client_uuid`，去重键 `(kind, address)`（名称不参与），本地文件夹源不参与，密码不入服务端（设备本地 SecretStore，新设备显示「待配置密码」）；应用后重建内存源列表；存量远端源接入时补 uuid 并补发一次 create；旧协议级身份（`legacy:<协议>`）在设备重新上报时由服务端懒迁移到源实例 uuid
- **跨设备断点消费**：`breakpoint.set` 快照带来源设备；客户端 pull 落 `breakpoint_mirror`；启动恢复与歌单「播放全部」会比较本机 `play_state`（含歌单归属 `playlist_uuid`）与镜像的 `updated_at`，远端更新时自动从该进度续播并 toast 提示（歌单详情保留「从头播放」入口）；目标歌本机无源时退到其后第一首可播条目，全不可播则回落本机恢复
- 直连模式（无服务器）：上述全部跳过，数据只在本机

> 客户端侧实现（先落库再上报、2s 推 / 30s 拉、指数退避、快照 op、缓存攒批）见
> [DEVELOPER.md「客户端同步与缓存批处理」](DEVELOPER.md#客户端同步与缓存批处理)。

---

## 8. 分阶段路线图

> 每阶段独立可交付；估时按单人业余投入。
>
> **平台开发原则（约定）**：**Linux 桌面与 Android 同步开发，双平台进度对齐**。
> `lib/` 下的 UI/主题/播放器/鉴权/状态层均为跨平台 Dart 代码，演进时不另起分支；
> 任何特性在落地时必须有 Linux + Android 双平台的平台层配套（音频后端/权限/生命周期差异分别用条件导入或平台插件收口），
> 以"两个平台都能跑通验收项"作为阶段完成的判定标准，避免出现平台壳长期空缺、进度脱节。
> 原因与验收口径只在此处；各平台构建矩阵与所需构建机见 [DEVELOPER.md](DEVELOPER.md#多平台构建矩阵)。

### 阶段 0：Android 平台对齐

> **状态：已完成✅** —— `frontend/android/` 壳工程已重建（Gradle/Kotlin 构建 + AndroidManifest + MainActivity 齐全），
> `flutter build apk --debug / --release` 与 Linux 双端均可出包；Android 真机（无线 adb）已能 `flutter run` 启动，
> 加载与 Linux 完全一致的 `lib/` 跨平台代码。此后各阶段验收均按 §8 顶部「双平台同步」约定推进。

- ✅ 重建安卓壳工程：`flutter create --platforms android .`（`build.gradle.kts` / `AndroidManifest.xml` / `MainActivity` / `gradle/wrapper` / `res/` 齐全）
- ✅ 网络与播放器后端：`INTERNET` 权限、内网 http 走 `usesCleartextTraffic`；音频**无需手动平台分支**——`just_audio` 在 Android 走默认 ExoPlayer、Linux 由联邦插件接管 mpv，`lib/` 不直接引用平台插件
- ✅ 双端共用同一 `lib/`：主题 / 认证 / 播放器 / 配对页 / 内容区 / 队列均复用
- ✅ 阶段 0 遗留的通知栏 / 后台播放 / 音频焦点已落地（`audio_service` 自定义处理器 + `notification_controls` / `audio_focus_enabled` 开关，见 §6.7 / §6.8 / settings.md §3.6）；真机行为待验证
- ✅ `secure_storage` Keystore 细节已过（Android 默认 Keystore-backed）
- 验收口径：`flutter build apk --release` 成功出包；Android 真机与 Linux 完成同一套功能验收清单

### 阶段 1：双模式骨架 + 服务器核心（~1.5 周）

> **状态：已完成✅** —— 认证（access/refresh 轮换 + 过期懒刷新）、可换主题的自适应 UI 框架、全局播放器、配对页均已落地。后端的曲库/流媒体能力已彻底移除（历史阶段产物），现仅保留认证/配对与状态同步。

- 后端：SecurityConfig+TokenFilter(**含过期校验/X-Token-Expired**) + devices/auth API(**pair + refresh 轮换**)
- App：Source 层直连实现、**可换主题自适应 UI 框架（theme/layout/providers)**、基础播放器（顺序播放）、配对页
- 验收：配对一台真机 → 浏览服务器曲库 → 任选一首流式播放；未带 token 的请求被拒

### 阶段 2：加权播放 + 歌单 + 喜欢歌缓存（~1 周，蓝图核心）

> **状态：客户端本地闭环 + 歌单/喜欢列表 UI 已完成✅**。本轮整体按「**纯客户端本地**」落地：
> 后端不新增 API；直连歌曲的权重 / 收藏 / 断点同样落本地，阶段 5 再接同步上推。
> `flutter analyze` 0 问题，`flutter build linux --debug` 与 `flutter build apk --debug` 均通过。

- ✅ 播放模式 ×4：顺序（默认）/ 列表循环 / 单曲循环 / 加权随机；切换入口播放页 + 队列面板
- ✅ 加权随机：factor 连续 0.5~1.5 步长 0.1；每步全量排除上一首采样（非无放回）；complete/skip 事件自动调权（详见 §7.1）
- ✅ 喜欢 / 不喜欢 UI（播放页 ❤️/👎 + 权重芯片；SongTile 收藏通用化，含本机无源的同步快照行）
- ✅ 收藏统一收口 `play_meta.is_favorite`（单一数据源）；旧 `idx_songs.is_favorite` 一次性回填迁移
- ✅ 喜欢列表：内容区「喜欢」分栏目走 `direct.favoriteSongs()`（同 play_meta 统一数据源）
- ✅ 歌单：`PlaylistStore` + `PlaylistsProvider`；`playlists_view.dart` 列表/详情原地子视图（新建/重命名/删除/播放全部/上移/下移/移除）+ SongTile ⋮「加入歌单」弹层
- ✅ 断点续播：`Song.toJson/fromJson` + `play_state` 单行（2s 节流），启动恢复为**暂停态**不自动播放
- ✅ 喜欢歌自动缓存 + LRU（`cached_at/last_accessed_at`，跳过正在播放）；收藏自动缓存开关在 `设置 → 歌曲`，缓存上限已迁至 `设置 → 服务端`（双来源，见 settings.md §3.3）
- ✅ 设置项面板全部落地（播放模式 / 权重显示 / 断点恢复 / 淡入淡出 / 均衡器 / 缓存双来源 / 通知控制 / 忽略音频过滤 / 仅 Wi-Fi 扫描 / 导入导出），键名与默认值见 [settings.md](settings.md)
- 验收（蓝图 §三 核心行为）：加权随机按概率选歌、同首不连续播放、喜欢可一轮多次 / 不喜欢可能多轮一次；连续 3 次完整播放 factor 提高（反之降低）；杀 App 重开断点续播；四种模式切换正确

### 阶段 3：直连 WebDAV + 本地索引（~1 周）

> **状态：已完成✅（含后续扫描优化迭代）** —— 直连 WebDAV/本地源 + 本地索引全链路落地（§6.4 / §6.5），
> 增量指纹（size/mtime/etag）、快速只建索引扫描、播放时懒补全、进度/取消、本地变化自动扫描均已落地（均为 APP 侧扫描；服务端不再扫描入库）。
> 双端构建通过、`webdav_scan_test` 3 条 + `audio_metadata_test` 8 条全部通过。
> 早期附加 mp3/flac 乱码修复：需对已有源重新扫描一次覆写旧索引行（`upsert` 无条件覆盖）。

- ✅ `WebdavDirectSource`：dart:io `PROPFIND Depth:1` 并发递归（`package:xml`）+ `Range` 流式（seek/断点）+ 纯 Dart 头部元数据解析（mp3 ID3v2 / flac STREAMINFO+VORBIS_COMMENT），头部越界保护
- ✅ 本地轻量索引（§6.4）：`LocalIndex`（sources/idx_songs/cache）、Isolate 扫描器（`scan_worker.dart`）、`(ref,size,mtime,etag)` 增量与 missing 标记、封面落 `covers/<hash>.jpg`
- ✅ 扫描优化：快速只建索引（零读头）、批量 `upsertSongs`、进度/取消、并发池、自动扫描（本地 watcher + 周期快扫）、播放时 `enrichSong` 懒补全（§6.4）
- ~~✅ 后端扫描增量：`MusicScanner` 指纹跳过 + `getlastmodified` 解析 + 并发探测 + album 缓存 + `@Scheduled` 定时（§4.5 / settings.md §5.1）~~ 已移除（服务端不再扫描；歌曲只由 APP 在播放源处扫描）
- ✅ 直连浏览：`SourcesScreen` 卡片三点菜单 + `SourceBrowseView` 文件夹式内页（扫描/进度/取消 → 搜索 → 播放 → 收藏 → 缓存全链路）；离线缓存（§6.6）
- ✅ 全局库合并（§6.5）：`LibraryProvider` 聚合直连源（去重），专辑/歌手客户端聚合；按 `sourceKey` 逐首解析源实现
- ✅ 源骨架：Webdav / Local 完整，SMB（阶段 4）
- 验收（卸载后端场景）：只配 WebDAV / 本地源，完成扫描→搜索→播放→收藏→断网播缓存 全链路

### 阶段 4：全平台 SMB 直连（~1–2 周，风险最高）

- Windows UNC 通路（先行，半天）；Android smbj 平台通道 PoC（1 天硬门槛）→ 正式实现；鸿蒙验证（三方分支 + 核心依赖 just_audio/path_provider/sqlite3 的鸿蒙可用性逐项核查，同时此阶段才搭建 DevEco 环境）
- 验收：Android 真机直连 NAS 播放 SMB 歌曲，seek/断点正常；鸿蒙给出可行/降级结论

### 阶段 5：多设备状态同步（~1 周）

> **状态：已实现✅（跳过阶段 4 先行）** —— `/api/v1/sync/*` + 歌单 CRUD + 断点 PUT + 调权 POST（§4.4）；
> `SyncService`（事件去重/§7.1 服务端重算/行级 LWW/correction 回执/seq cursor）；
> 客户端 `weight_outbox` + 四处埋点（调权/收藏/歌单/断点，有身份歌曲；直连歌需连着服务器，未配对不进队）+ `SyncEngine`
> （2s tick 推/30s 拉/退避/手动）+ 设备管理页；后端 8 单测 + 前端 5 单测全绿；
> scratch 库 11 步端到端验证通过（幂等/LWW/墓碑/冒充拒绝全覆盖）。
> 断点按"播放歌单归属 + 有身份歌曲"上报（直连歌需连着服务器），远端断点进 `breakpoint_mirror`（不碰运行时 play_state）。

- ✅ `/sync/*` 全套；SyncEngine；设备管理页
- 验收：两台设备 30s 内状态收敛；断网操作恢复网络后正确合并（待三端真机验收：Linux 桌面 + 双手机）

### 阶段 6：转码 + 管理闭环（~1 周）

- ffmpeg 按需转码管线与并发上限；分片上传；删除/隐藏
- 管理端设置：`GET /api/v1/admin/config`（缓存建议值）与 `GET /api/v1/admin/pairing-token` **已随暂缓项提前落地**；`PUT /admin/settings` 与设置页仍在本阶段
- 验收：FLAC 源按 128k 出流实测流量达标；上传 50MB 文件入库可播

### 平台支线：鸿蒙 NEXT 端（2026-09 完成 PoC 验收）

> **状态：PoC 验收通过、真机日常使用中✅** —— 不占用原六阶段排期，在阶段 5 之后独立推进；SMB 直连的鸿蒙通道方案仍归阶段 4。
> 原风险 R2（三方分支通道兼容 + 插件生态缺口）已逐项验证可控：核心依赖全部落地——fvp 音频后端 / secure_storage 双层适配 / sqlite3 随包分发 / path_provider 重试包装 / audio_session 容错 / audio_service 由自建 AVSession 桥替代；仅 `cached_network_image`（sqflite 传递依赖缺失）曲库封面降级为已知问题。
> 交付清单：启动白屏双地雷修复、直连 WebDAV 全链（扫描/点播/鉴权折叠）、AVSession 媒体播控（§6.8）、横竖屏、应用图标、自动切歌修复、装载看门狗、宽屏队列面板。细节全记录在 [DEVELOPER.md「鸿蒙适配」](DEVELOPER.md#鸿蒙适配)。

### 暂缓项：已配对设备设置页明文显示配对密钥

> **状态：已实现✅**（`GET /api/v1/admin/pairing-token` + `设置→服务端→配对服务器` 副标题遮显、配对页明文可复制，与淡入淡出/均衡器/通知控制等暂缓项一并落地；功能 7「设置整理」后密钥归入服务端分区，不再放常规）。

- 后端：新增需已配对设备 token 的端点，返回当前 `pairing_token`（从 settings 镜像读取，权威源为 env）。
- 前端：`设置→服务端→配对服务器` 条目副标题遮显同一份配对密钥（未配对也显示），进入配对页可显示/复制。
- 动机：首次启动日志仅打印一次，后续查看密钥需此入口（替代已移除的 `pairing-token/reset`）。

---

## 9. 风险与开放问题

| # | 风险 | 影响 | 缓解 |
|---|------|------|------|
| R1 | smbj×Android 平台通道（性能/稳定性未知） | 阶段 4 可能返工 | PoC 硬门槛前置；备选 jSMB/系统 smbclient 子进程；最坏降级"移动端直连仅 WebDAV" |
| R2 | 鸿蒙三方 Flutter 分支的平台通道兼容性 + **pub 插件生态缺口** —— **已验证可控（2026-09 PoC 验收，见 §8 平台支线）**：核心依赖全部落地（fvp / secure_storage 双层适配 / sqlite3 随包 / path_provider / audio_session / AVSession 替代 audio_service），仅 `cached_network_image` 封面降级 | 鸿蒙端已可日常使用；选型仍受「优先纯 Dart 包」约束 | 逐项核对结论与实现见 DEVELOPER「鸿蒙适配」；stable 新 API 须双 SDK analyze 验证；SMB 直连的鸿蒙通道方案仍待阶段 4 验证 |
| R3 | WebDAV 服务端差异（PROPFIND 深度/鉴权/限流） | 个别云盘不可用 | 连接测试按钮 + 超时重试封装；适配名单维护在文档 |
| R4 | 直连扫描耗流量/电量 | 用户感知差 | 仅 Wi-Fi 扫描开关；增量指纹（size/mtime/etag）跳过未变文件；快速只建索引扫描零读头；补读走严格 Range（按结构定位，不整读）；单源上限 |
| R5 | ffmpeg 容器 CPU 占用 | 多设备并发卡顿 | 全局并发上限默认 2；超限降级透传 |
| R6 | 大曲库查询性能 | 列表慢 | 索引齐备；`q` 前缀匹配；预留 FTS 开关 |
| R7 | 公网暴露 | 曲库/上传被滥用 | Bearer 认证已是第一道门；文档仍建议叠加 IP 白名单 |
| R8 | 转码流 position 精度 | VBR 断点 ±2s | 文档注明；CBR 精确 |

### 待拍板（沿用 v1，默认按文中执行）

1. 上传落点 `Uploads/` 可配 —— 默认如此
2. ~~服务端定时扫描 —— 默认开启（`SCAN_SCHEDULING_ENABLED=true`、6h 间隔），可在 `.env` 关闭~~ 已作废（服务端不再扫描）
3. 封面 128/512 两档 —— 默认如此
4. `hard=true` 仅限 local 源 —— 默认如此
5. `frozen` 是否暴露 UI —— 已定：以「不喜欢」开关形式暴露（播放页 👎 / 列表 ⋮），开即锁定最低权重，见 §7.1
