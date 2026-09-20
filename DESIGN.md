# SelfMusic 整体设计文档

> 定位：**去中心化的个人音乐服务器 + 双模式客户端**
> 上游约束：`开发思路.txt`（无中心账号 / 本地+SMB+WebDAV 曲库 / 加权播放 / 喜欢歌自动缓存）
> 状态：**阶段 0–3、阶段 5 已完成**（Android 壳对齐 / 认证·配对 / 客户端本地闭环·歌单·喜欢列表 / 直连 WebDAV·本地索引·增量扫描优化 / 多设备状态同步）；阶段 4（SMB）、阶段 6（转码+管理闭环）待实施。
> 在此之上，后续迭代全部落地：元数据后台补读与全源编辑、歌词、后台播放、睡眠定时四模式、播放页与集合页交互
> （层级返回 / 分组左右滑切 / 列表·卡片切换 / 队列·歌单自动定位高亮 / 标题显示格式 / 搜索追焦 / 编辑歌单）、
> 网络安全加固（默认 HTTPS + 允许不安全 HTTP / 信任自签名开关 + 明文凭据收敛到 secure storage，见 §6.7 与 问题.md）。
> 各阶段交付、验收与落地状态见 §8；文中已用「✅ 已实现 / ⏳ 规划」标注能力与端点到现状。

> **文档地图**：本文 = 整体设计 + 落地状态；设置项完整清单见 [settings.md](settings.md)；环境搭建、常用命令、调试与常见问题见 [DEVELOPER.md](DEVELOPER.md)。

## v2 相对 v1 的关键变化

| 变更 | 内容 |
|------|------|
| 无用户 → 单用户 | 引入"一服务器一主人"语义，配对 Token 认证，设备可管理可吊销 |
| 单模式 → 双模式 | App 在**无后端**时靠 SMB/WebDAV 直连完整可用；后端是增强层 |
| 新增 Source 抽象层 | Local / WebdavDirect / SmbDirect / ServerProxy 四实现统一接口 |
| 新增客户端本地索引 | 直连模式下 SQLite 轻量建库，跨源搜索体验接近服务器模式 |
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

### 1.1 双模式总览

```
                        ┌─────────────────────────────────┐
                        │         Flutter App              │
                        │                                  │
                        │  ┌────────────────────────────┐ │
                        │  │ 播放引擎（加权算法）          │ │ ←── 两模式共用
                        │  │ 本地 SQLite（状态事实源）     │ │      核心体验：
                        │  │ 缓存管理（LRU、喜欢歌）       │ │      离线可用
                        │  ├────────────────────────────┤ │
                        │  │      Source 抽象层           │ │
                        │  │  LocalSource                │ │
                        │  │  WebdavDirectSource         │ │
                        │  │  SmbDirectSource            │ │
                        │  │  ServerProxySource          │ │
                        │  └──────┬──────────┬──────────┘ │
                        │   直连模式│          │服务器模式    │
                        └────────┼──────────┼────────────┘
                                 │          │
             ┌───────────────────┘          └────────────────┐
             ▼                                               ▼
   ┌──────────────────┐                    ┌──────────────────────────┐
   │  音乐源（协议直连） │                    │ Spring Boot 后端          │
   │  · NAS(SMB)       │                    │ （个人单用户媒体服务器）    │
   │  · WebDAV 服务    │◄───────────────────│ · 统一扫描索引 → MySQL     │
   └──────────────────┘    后端也连这些源     │ · 流式代理 + ffmpeg 转码   │
                                             │ · 多设备状态同步           │
                                             │ · 设备配对与管理           │
                                             └──────────────────────────┘
```

### 1.2 功能矩阵（两模式能力边界）

| 功能 | 直连模式 | 服务器模式 | 说明 |
|------|:---:|:---:|------|
| 本地文件播放 | ✅ | ✅ | |
| SMB/WebDAV 浏览与播放 | ✅ 内嵌协议客户端 | ✅ 走 `/stream` | |
| 歌单 / 加权算法 / 喜欢·不喜欢 | ✅ 存本地 SQLite | ✅ 同左 + 同步 | 算法纯客户端 |
| 喜欢歌自动缓存 / 断网播放 | ✅ | ✅ | 蓝图 §三.3 |
| 曲库浏览 / 跨源搜索 | ✅ 本地轻量索引 | ✅ 服务端索引 | 直连首次连接需现场扫描 |
| 多设备状态同步 | ❌ 各设备独立 | ✅ | 需要后端 |
| 音频转码省流量 | ❌ 原码率 | ✅ 按需码率 | 需要后端 ffmpeg |
| 后台增量扫描 | ✅ 自动（本地变化监听 + 周期快扫，指纹跳过零下载） | ✅ 定时+手动 | |
| 上传 / 删除源文件 | ⚠️ WebDAV 可直传；SMB 视权限 | ✅ 统一管理 API | |

> 设计原则：**凡是能在客户端闭环的能力一律不依赖后端**；后端只做客户端做不了/做不好的事（跨设备一致、转码、后台扫描）。

---

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

| 表 | 说明 | 相对 v1 |
|----|------|--------|
| `albums` | 专辑（artist+album 归并） | 不变 |
| `songs` | 歌曲（元数据+源定位+权重状态） | 不变 |
| `covers` | 封面落盘记录 | 不变 |
| `playlists` | 歌单 | 不变 |
| `playlist_items` | 列表条目 | 不变 |
| `play_states` | 每列表断点 | 不变 |
| `scan_tasks` | 扫描任务 | 不变 |
| `settings` | 全局设置（含 pairing_token） | 增加键 |
| `devices` | 已配对设备 | **新增** |

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
| `cache_max_bytes` | 1073741824 (1GB) | 全局建议值，App 可下发 |
| `cache_song_limit` | 500 | |
| `scan_interval_min` | 0（关） | ❌ 已移除（服务端不再扫描；歌曲只由 APP 在播放源处扫描，见 §6.4） |
| `transcode_max_concurrency` | 2 | 全局 ffmpeg 并发上限 |
| `upload_dir` | `{LOCAL_ROOT}/Uploads` | 上传落点 |

`songs` 权重相关字段与触发规则见 §7.1。

### 3.2 客户端（SQLite，`sqlite3` 轻量版已落地，见 §6.4）

| 表 | 说明 |
|----|------|
| `sources` | 源配置：`type(local/webdav/smb/server)`、名称、凭据引用键、enabled、last_scan_at |
| `idx_songs` | 直连模式本地索引：`source_key, ref, title, artist, album, track_no, year, genre, duration, format, size, mtime, etag, cover_path, missing`（增量指纹含 `mtime,size,etag`；`is_favorite` 旧列仅用于一次性回填迁移，阶段 2 起不再读写） |
| `cache` | 已缓存歌曲：`cache_key, source_key, ref, local path, size_bytes` + `cached_at, last_accessed_at`（阶段 2 补列，LRU 用） |
| `play_meta` | 歌曲播放元数据（阶段 2 新增）：`(source_key, song_ref)` 主键 + `like_streak, dislike_streak, factor, frozen, is_favorite`（**收藏统一收口**）+ `song_json`（服务器歌快照） |
| `playlists` / `playlist_items` | 歌单与条目（阶段 2 新增）：条目含歌曲快照字段 + `sort_order`；播放时按 `(source_key, song_ref)` 重新解析 |
| `app_settings` | 客户端设置（阶段 2 新增）：键值表，`cache_max_bytes / cache_song_limit / auto_cache_favorites` 等 |
| `song_lyrics` | 歌词（迭代新增）：`(source_key, song_ref)` 主键 + `content`（LRC 文本）+ `updated_at`；三态收录（内嵌歌词 / 同名 `.lrc` / 标记缺失），避免每次播放重复读文件 |
| `play_state` | 断点（阶段 2 新增）：单行（`id=1`），`queue_json + index + position_ms` |

要点：

- `song_key` 统一为 `(来源标识, source_ref)` 复合键；同一首歌在不同模式下可解析到不同 Source 实现
- 收藏状态**统一收口** `play_meta.is_favorite`（直连 + 服务器一致）：迁移时从 `idx_songs.is_favorite=1` 回填一次，
  此后所有读取（搜索 / 收藏列表 / 歌单解析 / 断点恢复）统一 `LEFT JOIN play_meta`
- 凭据加密：WebDAV/SMB 密码经 `flutter_secure_storage` 存放，SQLite 只存引用键
- 离线优先：所有播放决策只查本地表；网络层的角色是把远端变更搬进本地
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

### 4.2 曲库浏览与搜索（服务器模式）

| 方法 | 路径 | 说明 |
|------|------|------|
| ✅ GET | `/library/songs` | 过滤：`q/artist/album/source/favorite/hidden` |
| ✅ GET | `/library/songs/{id}` | 详情（含权重） |
| ✅ GET | `/library/albums` · `/library/albums/{id}` | 专辑列表/详情 |
| ⏳ GET | `/library/artists` | 歌手聚合 |
| ⏳ GET | `/library/folders` | 目录浏览 `?source=&path=` |
| ✅ GET | `/library/favorites` | 收藏快捷端点 |

### 4.3 流媒体（服务器模式）

| 方法 | 路径 | 说明 |
|------|------|------|
| ✅ GET | `/stream/{id}?br=&format=` | Range 流式代理（`Accept-Ranges`/`206` 透传）；**转码参数 `br`/`format` 为规划态（阶段 6），当前全原码透传** |
| ⏳ HEAD | `/stream/{id}` | 探测长度/时长 |
| ⏳ DELETE | `/stream/{id}` | 显式停止（关闭 ffmpeg 子进程） |

### 4.4 状态同步（服务器模式）—— ✅ 已实现（阶段 5）

| 方法 | 路径 | 说明 |
|------|------|------|
| ✅ GET | `/api/v1/sync/pull?since_cursor=` | 增量拉取（歌单+权重+断点快照），返回新 cursor；`since=0` 为启动全量校准；超 2000 事件分页（`has_more`） |
| ✅ POST | `/api/v1/sync/push` | 批量上推事件流水；幂等按 `event_uuid` 去重；LWW 判输回 correction 快照；`device_client_id` 须与认证身份一致 |
| ✅ CRUD | `/api/v1/playlists` 系列（含 `{id}/items` 增删改） | 直接 REST 变更同样走事件管线（服务端代写事件），其它设备经 pull 可见 |
| ✅ PUT | `/api/v1/playstates/{playlistId}` | `{song_id, position_ms}`；行级 LWW，判输回服务端快照 |
| ✅ POST | `/api/v1/songs/{id}/weight` | `{event: liked\|...}` 单权重事件直调（走同一管线，`song_id` 强制为路径 id） |

### 4.5 管理

| 方法 | 路径 | 说明 |
|------|------|------|
| ✅ GET | `/admin/config` | 当前配置建议值概览（缓存双来源用） |
| ✅ GET | `/admin/pairing-token` | 主配对令牌明文（`设置→服务端→配对服务器` 展示用；密钥源自 env 镜像） |
| ✅ GET | `/admin/devices` · PUT/DELETE `/admin/devices/{id}` | 设备列表 / 改名 / 吊销 |
| ❌ ~~POST~~ `/scan` · ~~GET~~ `/scan` | 已移除（服务端不再扫描入库；歌曲只由 APP 在播放源处扫描，见 §6.4；历史库 `scan_tasks` 表残留无害） |
| ⏳ POST | `/admin/upload/init` → `/part/{n}` → `/commit` | 分片上传（16MB/片），阶段 6 |
| ⏳ DELETE | `/library/songs/{id}?hard=` | 移出索引；`hard=true` 删源文件（仅 local 源允许），阶段 6 |
| ⏳ PUT | `/admin/settings` | 设置读写（已实现 GET `/admin/config`，写接口仍规划） |

---

## 5. 后端模块与选型

### 5.1 包结构（`com.selfmusic.backend`，现状以代码为准）

```
auth/         AuthController(pair/refresh/unpair) + DeviceAdminController + SecurityConfig + TokenFilter
admin/        AdminSettingsController(config/pairing-token)
controller/   HealthController
library/      LibraryController(songs/albums/favorites) + SongController（调权直调，阶段5）
stream/       StreamController(Range 代理) + MusicSourceProxy(local/webdav 源解析)
common/       ApiResponse, BizException, GlobalExceptionHandler, MusicSource 枚举
config/       FirstBootInitializer, WebConfig(CORS)
domain/       JPA 实体 + Repository + service
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

### 6.1 目录规划（已落地的可换主题自适应结构）

```
lib/
├── main.dart              入口 + Provider 装配（Theme/Auth/Library/Player/Navigation）
├── theme/                 ★ 可配置主题核心
│   ├── app_theme.dart      语义化颜色 token + AppTheme.build()（亮/暗、自定义强调色/背景色）
│   └── theme_provider.dart 主题状态：运行时切换 + secure_storage 持久化
├── layout/                ★ 自适应模块化布局框架
│   ├── app_shell.dart      顶层壳：桌面[侧边栏|内容|队列面板]，窄屏抽屉
│   ├── sidebar.dart        侧边栏：设置分区(备份/播放/界面/服务端/歌曲/通知)+底部(明暗/退出)
│   ├── top_bar.dart        顶栏：上层汉堡+搜索（键入保持焦点），下层导航(播放列表/喜欢/播放源/歌曲/专辑/歌手，支持左右滑动切组)
│   ├── queue_panel.dart    播放队列面板：窄屏底部 0.7 高弹层 / 宽屏右侧常驻；打开自动定位当前曲并强调色
│   └── mini_player_bar.dart 底部"正在播放"条：播放控制 + 播放队列入口 + 上滑/点按进播放页
├── providers/            ★ 状态
│   ├── navigation_provider.dart  分区/设置/播放页视图切换（层级返回）+ 源内文件夹导航(browsingSourceKey) + 歌单详情导航(browsingPlaylistId)
│   ├── player_provider.dart      全局播放(AudioPlayer+队列) + 睡眠定时 + 歌词加载 + 预载下一首 + 按 sourceKey 解析源 + 四种播放模式 + 断点续播
│   ├── library_provider.dart     合并库（服务器+直连）+ 专辑/歌手分组 + sourceFor 解析
│   ├── direct_source_manager.dart 直连源管理（全部激活，无单一激活态）+ 本地歌单/收藏/播放元数据 + 后台元数据补读 + 预载
│   ├── playlists_provider.dart   歌单列表/详情状态
│   └── auth_provider.dart        配对 + 会话过期态
├── services/             ApiClient(含懒刷新拦截器)、AuthService、ServerSettings(代理后端地址)
├── data/
│   ├── sources/          ★ Source 抽象层 (ServerProxy / WebdavDirect / SmbDirect) + DirectAudioSource
│   └── local/            纯 Dart 头部解析(audio_metadata) + SQLite(local_index) +
│                         stage2 封装：SongWeightStore / PlaylistStore / CacheManager / AppSettings
├── models/               Song(含 toJson/fromJson 断点快照) / Album(含 coverPath) / Artist
├── utils/                纯工具：duration_format（mm:ss/h:mm:ss）、song_title_format（标题显示格式）、lrc_parser（LRC 解析/二分定位）
├── widgets/              共享组件（SongTile 可收藏/⋮ / CoverThumb / PlayModeSelector / add_to_playlist（加入·编辑歌单）/
│                         lyrics_view（歌词页） / view_mode_toggle（列表·卡片切换） / player_sheet_anim · marquee_text · section_swipe 等）
└── screens/              library(内容区 AppContent：分区/歌单详情/喜欢列表，六组跟手滑动) / playlists_view(歌单列表+详情原地子视图，自动定位当前曲)/
                          sources(源卡片·列表行+三点菜单) / source_browse_view(源内文件夹浏览) / settings / player(封面更多→歌曲信息·修改元数据) / pairing
```

> **平台收口层**（`capabilities`，见下方「为什么要有 platform/ 层」）与 **drift** 均未落地，属后续阶段：
> 本地库已用 `sqlite3` 轻量版 + 阶段 2 各表落地（见 §6.4 / §3.2），无需 drift。

> **为什么要有 `platform/` 层**：鸿蒙走的是三方 Flutter 分支而非官方 target，`Platform.isXxx` 行为、原生插件实现均可能与官方平台不一致。业务代码禁止直接写 `Platform.isAndroid` 之类判断，一律询问 `capabilities`；鸿蒙加入时只需在 `platform/harmonyos/` 提供一套实现，不动上层。

### 6.2 Source 抽象层（双模式的基石）

```dart
abstract class MusicSource {
  String get key;                       // 稳定标识: 'server'/'smb:nas1'/'webdav:xx'/'local:xx'
  SourceKind get kind;
  Future<ScanResult> scan();            // 建本地索引（增量）
  Future<SongMeta> probe(String ref);   // 头部元数据（Range 读头部）
  Stream<List<int>> open(String ref, {IntRange? range}); // 音频流
  Future<void> close();
}
```

- 播放器只认 `MusicSource`，不感知模式
- `ServerProxySource.open()` 即 GET `/stream/{id}`；直连实现各自对接协议
- 直连播放优先级：离线缓存文件 → `directStream()`（原生 URL，ExoPlayer/native Range seek 更稳，WebDAV 用）→ 自建 `StreamAudioSource`（`open()`）回落
- WebDAV `ref` 存**解码后**路径（标题/去重友好），请求时按路径段重新编码；扫描头部元数据解析对大内嵌封面做了边界保护（超采样长度即停止解析，不抛 `RangeError`，随后按提示补读）
- 模式判定 = `sources` 表里有哪些启用的源；配置了 `server` 源即解锁同步/转码等增强功能

### 6.3 SMB 直连平台策略（全平台目标）

| 平台 | 方案 | 工作量 |
|------|------|--------|
| Windows | 系统挂载（UNC `\\host\share\path`），`dart:io` 直接读 | 小 |
| Android | 平台通道嵌入 JVM **smbj**：Dart 侧请求 `open(ref)` 得 `sessionId`，循环 `read(sessionId, offset, len)` 取字节流喂 `StreamAudioSource` | **大（R1）** |
| 鸿蒙 | 复用 Android 通道方案；若三方 Flutter 分支通道兼容有问题 → 该端降级"直连仅 WebDAV" | 中（待验证） |

- 传输细节：smbj `InputStream` + 共享池；单次读 256KB；连接复用（每源一个 Session）
- 断点续播：`StreamAudioSource` 支持 Range 起播，seek 时重建流

### 6.4 直连模式本地轻量索引

直连源在客户端建本地索引（SQLite `idx_songs`，表结构见 §3.2），实现约定分四组说明。

**扫描流程（首次）**

- 列目录：WebDAV `PROPFIND Depth:1` 递归 + `_mapConcurrent` 并发（并发 6）；本地文件夹 `Directory.list(recursive:true)`
- 逐文件 Range 取头部（`head_bytes`≈64KB，可配 `scan_head_bytes`）→ `audio_metadata`（纯 Dart 解析 mp3(ID3v2) / flac / m4a(mp4) / ogg·opus / wav / aac(ADTS)）得标题/歌手/专辑
- 单事务批量 `upsertSongs` 落库 → `persistCover`（封面落 `covers/<hash>.jpg`，SQLite 存路径）→ `markMissingExcept`/`clearMissing` 标记消失项（保留缓存歌可播性）
- 大目录保护：单源上限 20k 首，超出提示分目录添加

**增量与扫描模式**

- 增量指纹 `(ref, size, mtime, etag)`：WebDAV 从 PROPFIND 解析 `getlastmodified`/`getetag`/`getcontentlength`；本地扫描 `stat` 取 size/mtime；**四元组未变直接跳过读头 → 二次扫描零音频下载**
- `scan_mode` 三档：`fast` 仅文件名建索引（零读头，**默认**）/ `minimal` 只解析标题·歌手·专辑（最快补充）/ `full` 解析全部元数据 + 封面（时长/曲目/年份/流派）。六类格式 mp3/flac/m4a/ogg·opus/wav/aac 均支持；解析无果时按「同目录图片 → 文件名」回退
- 播放时懒补全：`minimal` 入库的歌缺 时长/流派/年份/封面 → `PlayerProvider` 播放后后台 `open` 读头解析并 `enrichSong` 回填，失败不影响播放
- **播放时必然重读**：`_enrichLazily` 不依赖索引缓存，任何歌开始播放都再次读头解析并回填（兼修正断点/歌单旧快照），保证切歌即时刷新
- **大内嵌封面两段读**：首段采样（256KB）解析缺少封面时，`coverReadHint` 按 ID3 标签声明长度 / FLAC 块头 / ogg comment 包完成度算出「读到封面块尾」所需字节数，补读一次（上限 `kCoverReadCapBytes` 8MB）再解析——高清扫图常见 1~3MB，一段读会整块丢失；**moov-at-end 的 m4a、ogg/opus 时长、无 ID3v2 的 mp3 ID3v1** 走 `tailReadHint` 尾部补读（m4a 按 256KB→1MB→4MB→8MB 逐级增大，ogg 取末页 granule，mp3 取尾 128B）；扫描 `full`+提取封面同样走 `readAudioMeta` 统一读序。旧版已标已读但无封面的 mp3/flac 行由一次性迁移（`kCoverReenrichV1Done`，设备本地标记）重置为未读，交给后台补读重取。**歌词（USLT / LYRICS）与长文本帧同在整段标签内，随两段读一并补全**
- **同目录图片回退**：解析后仍无封面 → 按「同名图片（`.png/.jpg/.jpeg/.webp`）→ `cover.*`/`folder.*`/`front.*`/`album.*`」顺序取同目录图片（播放补读按会话缓存，扫描按目录清单/下载缓存去重），经图片签名校验后落盘。同名 `.lrc` 歌词回退早已在同目录读取路径（§3.2 song_lyrics / 播放歌词加载）
- **全局后台补读**：任一首开始播放后，后台逐个补读各直连源「尚未读取过元数据」的歌曲（`DirectSourceManager` 分批循环读头回填），专辑/歌手/封面在扫描未覆盖时也能逐步补齐并在 UI 就地刷新（`LibraryProvider` 监听元数据版本号）
- **修改歌曲元数据（全源）**：播放页封面「更多 → 修改歌曲元数据」，标题/歌手/专辑可编辑；直连歌曲落 `user_edited=1` 扫描不再覆盖，服务器歌曲本地覆盖展示（`LocalIndex.setUserMeta` / `DirectSourceManager.updateSongMeta`）

**进程隔离与进度**

- 扫描在独立 Isolate（`scan_worker.dart` `runScan`：Isolate.spawn + 握手 `__cancel__` 通道 + 进度 `ScanProgress` 回调，listing/探测两阶段）
- 进度事件经 `DirectSourceManager.scanProgressStream` 广播，UI（`SourceBrowseView`）节流渲染进度条并支持取消；`_inFlightScan` 全局互斥防重复扫描
- 探测并发池：WebDAV 6、本地 4；参数只传可序列化原始值（HTTP 客户端 / DB 句柄 / `LocalIndex` 不得跨 isolate）

**本地文件夹源与自动扫描**

- `LocalDirectSource`（全平台）：`key='local:<name>'`、`kind=local`；文件本体即缓存，`cachedFilePath` 直接返回绝对路径走 `setFilePath`；Android 读共享存储需运行时 `READ_MEDIA_AUDIO`(13+)/`READ_EXTERNAL_STORAGE`(≤12) 权限，扫描前申请
- 自动扫描：本地 `Directory.watch(recursive)` 变化去抖 2s 触发增量；`scan_auto_interval_min` 周期增量（WebDAV 协议无推送，靠周期低流量快扫兜底）

**防护与编码**

- 头部越界保护：元数据块声明长度超出头部采样即停止解析，不抛 `RangeError`（大内嵌封面场景）
- 时长探测：mp3 估算法（文件大小÷码率）或解析 Xing/VBRI 头；flac 读 STREAMINFO
- 文字编码：mp3 ID3v2 按帧 encoding 选解码（enc==3 → UTF-8；enc==0 → 尝试 UTF-8 再回退 Latin-1）；flac/ogg VORBIS_COMMENT 按规范 UTF-8（失败回退 Latin-1）；m4a 文本原子 UTF-8；无内嵌标签时走文件名/同目录回退
- 旧索引乱码修复：`idx_songs` 行经 `upsert` 无条件覆写，重新扫描即自动更新，无需手动清库

> **重要**：修复 FLAC VORBIS_COMMENT 乱码（`String.fromCharCodes` → `utf8.decode`）后，需对已有播放源重新执行一次「扫描」以覆写旧乱码行；`upsert` 的 `ON CONFLICT` 会无条件更新 title/artist/album，无需手动删除或重建索引。

### 6.5 源内文件夹式浏览与全局歌曲合并

- 所有播放源默认激活（移除旧「单一激活源」概念），`direct_source_manager.dart` 仅维护源列表与本地索引，不再持有 `_activeKey`
- 点击源卡片 → `NavigationProvider.enterSource(key)` 将 `browsingSourceKey` 置为该源 key → `AppContent` 检测到 `sources + browsingSourceKey` → 内容区原地切换为 `SourceBrowseView`（不走 `Navigator.push`）
- `SourceBrowseView`：顶部返回按钮调用 `exitSource()`、显示源名、扫描/刷新按钮、搜索框、歌曲计数；扫描完成后自动调用 `LibraryProvider.loadSongs()` 刷新全局合并库
- 源列表页（`SourcesScreen`）支持**列表 / 卡片**两种展示（右上角切换，持久化 `view_mode_sources`，见 §6.7）；列表行复用卡片组件（`plain` 参数）
- 源卡片右侧 `PopupMenuButton` 三点菜单：切换为直连/切换为服务端代理、编辑、删除源（二次确认弹窗）；移除旧「服务器源」独立卡片（服务端代理归属直连源的模式之一）
- 新增/编辑源弹窗统一为 `_SourceDialog`：添加态用 `SegmentedButton` 选 WebDAV/本地文件夹（本地态提供「选择目录」走 `file_selector.getDirectoryPath`）；编辑态按 key 从 `LocalIndex` 原始配置预填（代理模式下内存对象不持底层凭据），改名会派生新 key 并同步迁移 `sources/idx_songs/play_meta/playlist_items`（`LocalIndex.renameSource`）
- 全局歌曲/专辑/歌手合并：`LibraryProvider.loadSongs()` 合并 `ServerProxySource.fetchSongs()` 与 `DirectSourceManager.allSongs()`（按 `title|artist|albumName` 去重），服务器源返回的歌曲 `sourceKey = 'server'`；专辑和歌手按合并后的歌曲列表客户端聚合（`Album.fromSongs` / `Artist.fromSongs`），切换到对应栏目时自动拉取
- 播放路由：`PlayerProvider.attachSourceResolver` 注册解析函数，按歌曲 `sourceKey` 逐首解析源实现（'server' → `ServerProxySource`；其余 → `DirectSourceManager.sourceByKey`），混播队列中直连歌曲与服务器歌曲均可正常播放

### 6.6 网络与离线

- `dio`：API 超时 5s、指数退避重试 3 次；流式请求超时 ∞
- **懒刷新拦截器（ApiClient）**：`onRequest` 自动带 `Bearer access`；`onError` 命中 `401 + X-Token-Expired` 时用 `refresh_token` **单飞（single-flight）**换发新 token 并对原请求重放一次；刷新失败清空令牌并触发 `onSessionExpired` → "会话过期"弹窗重新配对。
- 断网判定：连续失败 → 进"离线模式"，UI 顶栏提示；播放范围收缩为 `cache` 命中项
- 恢复网络：SyncEngine 自动恢复，先推 outbox 再拉增量

### 6.7 客户端用户设置（✅ 已实现）

> 以下设置项已提供「设置」入口供用户自定义，键名对应直连模式 `app_settings` 表的 key，
> 完整清单见 `settings.md`。6 个分区面板已全部落地（含此前暂缓项）：
> 备份（设置/歌单导出导入）、播放（默认播放模式/断点续播/淡入淡出/均衡器/播放页手势/睡眠定时默认播完）、
> 服务端（后端地址/配对服务器[含同一份配对密钥]/预载/缓存配置双来源）、
> 歌曲（收藏自动缓存/扫描模式与头部·封面/忽略音频过滤/仅 Wi-Fi 扫描/标题显示格式/集合页展示形式）、界面、通知。

| 设置项 | 键 | 说明 | 默认 | 入口 |
|--------|----|------|------|------|
| 默认播放模式 | `play_mode_default` | `sequence / loopList / loopOne / weighted` 四选一，决定启动后的播放模式 | `sequence` | `设置 → 播放` |
| 播放页权重信息显示 | `player_show_weight` | 是否在播放页展示当前歌曲 liked / factor 状态 | 显示 | `设置 → 播放` |
| 断点续播自动恢复 | `resume_on_startup` | 启动时是否自动恢复上次队列与播放位置（恢复为暂停态，不自动播放） | 开 | `设置 → 播放` |
| 播放页滑动手势 | `player_gesture_swipe` | 播放/歌词页横滑互切、下滑返回、迷你条上滑跟手进播放页 | 开 | `设置 → 播放` |
| 睡眠定时默认播完最后曲目 | `sleep_play_through_default` | 睡眠弹窗「播放完最后的曲目」默认值；弹窗内可选 指定时间/指定时长/指定曲数/列表结尾 | 开 | `设置 → 播放` |
| 预载下一首 | `preload_next` | 播放时按播放顺序算法确定下一首并后台缓存（与预载开关无关，算法照常确定） | 开 | `设置 → 服务端` |
| 淡入淡出 | `fade_enabled` + `fade_duration_ms` | 播放/暂停音量软件渐变（just_audio `setVolume` ramp，全平台，不依赖后端 crossfade） | 开 / 1000 ms（1~3 s） | `设置 → 播放` |
| 均衡器 | `equalizer_enabled` + `eq_bands` | 5 频段增益（60/230/910/3600/14000 Hz，±12 dB）；**仅 Android**（`AndroidEqualizer` 注入 `AudioPipeline`），Linux/macOS 不生效 | 关 | `设置 → 播放` |
| 缓存来源模式 | `cache_config_mode` | `custom`=本地自定义值；`follow_server`=服务端建议值（`GET /api/v1/admin/config`） | `custom` | `设置 → 服务端` |
| 标题显示格式 | `song_title_format` | `fileName / titleOnly / artistTitle / titleArtist`；默认 歌手-歌名，显示层转换不修改存储 | `artistTitle` | `设置 → 歌曲` |
| 集合页展示形式 | `view_mode_playlists/sources/albums/artists` | 四集合页 列表/卡片 切换的持久化取值（播放列表=`list`，其余=`card`） | 见左 | 对应页面右上角 |
| 通知栏播放控制 / 后台播放 | `notification_controls` | audio_service 媒体通知 + 前台服务；**启动时门控注册**，改动重启生效；返回桌面续播，停止才真正停 | 开 | `设置 → 通知` |
| 自动暂停/恢复（音频焦点） | `audio_focus_enabled` | 来电 / 其他 App 抢占的暂停-恢复（just_audio `handleInterruptions`，重建播放器即时生效） | 开 | `设置 → 通知` |
| 允许不安全 HTTP | `allow_insecure_http` | 关时显式 `http://` 地址被拒并提示；缺 scheme 恒默认补 `https://`；约束后端 / WebDAV / 配对地址 | 关 | `设置 → 服务端` |
| 信任自签名证书 | `allow_self_signed` | dio API 与直连 WebDAV（dart:io `badCertificateCallback`）接受自签名/自建 TLS；播放器层（ExoPlayer/mpv）不受影响 | 关 | `设置 → 服务端` |

来源：§7.1（播放模式与调权）；设置项汇总见 `settings.md §3`。

### 6.8 歌词与后台播放

- **歌词三通道**：内嵌标签（mp3 `USLT` / FLAC `LYRICS`·`UNSYNCEDLYRICS`）→ 同目录同名 `.lrc`（local/WebDAV 通用，UTF-8/UTF-16 BOM 兼容）→ 服务端代理源（后端暂无歌词接口，留空）；解析为 LRC 文本入库 `song_lyrics`（`(source_key,song_ref)` 主键，三态：内容 / 显式标记缺失 / 未读取），缺失标记避免每次播放重复读文件
- **歌词页**：与播放进度同步滚动 + 居中高亮当前行 + 点击任意行 seek；手动拖动暂停跟随，切歌归位；`lrc_parser.dart` 支持多标签 / `offset` / 毫秒位数 / 纯文本退化 / 二分定位
- **后台播放**：Android 走 `audio_service` 自定义处理器（`SelfMusicAudioHandler`，通知按钮转发 `PlayerProvider`）；返回桌面/切后台**继续播放**（`androidStopForegroundOnPause=false` 暂停不撤前台服务，与 `androidNotificationOngoing` 互斥故弃用 ongoing）；通知栏「停止」/ 划掉任务（`onTaskRemoved`）/ 侧边栏「退出」（先 `shutdown()` 再 `exit(0)`）才真正停止并置空闲；`notification_controls=false` 时不注册前台服务、后台保活不成立

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

事件规则（阶段 2 为**纯客户端本地**落地，后端逻辑与服务端一致、以服务端为准，阶段 5 再接同步上推）：

| 事件 | 触发 | 效果 |
|------|------|------|
| complete | 自然结束且播放比例 ≥70% | like_streak++，dislike_streak=0；非锁定态 like_streak≥3 → factor=min(1.5, factor+0.1)、streak 清零；不喜欢锁定态只记 streak 不调权 |
| skip | 被 next/prev/换歌打断且比例 <70% | dislike_streak++，like_streak=0；非锁定态 dislike_streak≥3 → factor=max(0.5, factor−0.1)、streak 清零；不喜欢锁定态只记 streak 不调权 |
| liked | 手动喜欢 / 收藏 | favorite=true，factor=1.5，解除「不喜欢」锁定（frozen=false） |
| unfavorite | 取消喜欢 / 收藏 | favorite=false；非锁定态 factor 回 1.0；不喜欢锁定态保持最低权重 |
| disliked | 手动不喜欢（开关式） | favorite 不变；开 → factor=0.5 且 **frozen=true（权重锁定最低、跳过自动调权）**；关 → 解锁回 1.0 |
| reset | 手动重置 | 双 streak 清零，factor 回 1.0，解除「不喜欢」锁定 |

播放模式：`sequence`（当前顺序播放，播完即停）/ `loopList`（列表循环）/ `loopOne`（单曲循环）/
`weighted`（加权随机），切换入口播放页 + 队列面板；`next()` 与自动下一首按当前模式路由。

### 7.2 同步协议（仅服务器模式）

- **方向**：客户端本地 SQLite 是运行时事实源；后端是多设备汇聚点
- **Pull**：启动全量校准 + 每 30s `GET /api/v1/sync/pull?since_cursor=`；cursor 为服务端 `sync_events.seq` 单调递增变更号
- **Push**：本地产生权重事件/断点/歌单改动 → 写 `weight_outbox`（带 event_uuid）→ 2s 防抖批量上推；服务端按 uuid 幂等去重
- **冲突（字段级合并，阶段 5 落地）**：权重走**事件重算**而非绝对值覆盖（两设备并发点赞按到达序重放，不互抹）；收藏/歌单元数据/删除墓碑/断点走**行级 LWW**（事件 `occurred_at` vs 行 `last_event_at`，输方收 correction 回执自纠；仲裁时钟为服务端 `arrived_at`）；歌单条目按 seq 到达序重放（后到达胜出）；直接 REST 变更（歌单 CRUD/断点 PUT/调权 POST）同样先记事件再生效，保证 pull 可见
- **歌曲身份**：数字 `song_id` 优先，否则按 `(source, source_ref)` 唯一键解析；legacy 空 source 按 `source_ref` 兜底
- **直连歌曲同样同步（连着服务器时）**：客户端放行一切有身份（source/sourceRef 非空、可解析）的事件，不再限服务器模式；服务端按 `(source, source_ref)` 建**影子行**承载权重/收藏/断点（标题取歌单条目载荷或 ref 末段兜底，pull 回执只带权重字段、不覆盖客户端本地标题）；歌单条目 add/move 无 `song_id` 时同样按身份解析（缺行建影子行），remove 按身份解析、未知即 no-op；pull 身份收集恒不建行（已删歌曲不复活）。未配对（无后端地址）时直连事件不进队，避免 outbox 无限积压；`sync_enabled` 关闭同样全跳
- 直连模式（无服务器）：上述全部跳过，数据只在本机

---

## 8. 分阶段路线图

> 每阶段独立可交付；估时按单人业余投入。
>
> **平台开发原则（约定）**：**Linux 桌面与 Android 同步开发，双平台进度对齐**。
> `lib/` 下的 UI/主题/播放器/鉴权/状态层均为跨平台 Dart 代码，演进时不另起分支；
> 任何特性在落地时必须有 Linux + Android 双平台的平台层配套（音频后端/权限/生命周期差异分别用条件导入或平台插件收口），
> 以"两个平台都能跑通验收项"作为阶段完成的判定标准，避免出现平台壳长期空缺、进度脱节。

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

> **状态：已完成✅** —— 认证（access/refresh 轮换 + 过期懒刷新）、可换主题的自适应 UI 框架、全局播放器、配对页均已落地；后端 local/webdav 出流直取（`MusicSourceProxy` + `/library/**` + `/stream/**`）已端到端可用（服务端不再扫描入库）；镜像内置 ffmpeg。前端 Source 层四实现骨架已就位（ServerProxy 完整可用，Webdav/Smb/Local 为骨架，完整实现在阶段 3/4）。前端**直连源与本地索引**不属阶段 1 范围，已在阶段 3（WebDAV）/ 4（SMB）承接。

- 后端：SecurityConfig+TokenFilter(**含过期校验/X-Token-Expired**) + devices/auth API(**pair + refresh 轮换**)；MusicSource 抽象+Smb/Webdav/Local 实现(**ServerProxy 完整可用**)；扫描入库（local/webdav，SMB 直连归阶段 4）；`/library/**`、`/stream/**`；镜像加 ffmpeg
- App：Source 层四实现骨架（ServerProxy 完整可用）、**可换主题自适应 UI 框架（theme/layout/providers)**、基础播放器（顺序播放）、配对页
- 验收：配对一台真机 → 浏览服务器曲库 → 任选一首流式播放；未带 token 的请求被拒

### 阶段 2：加权播放 + 歌单 + 喜欢歌缓存（~1 周，蓝图核心）

> **状态：客户端本地闭环 + 歌单/喜欢列表 UI 已完成✅**。本轮整体按「**纯客户端本地**」落地：
> 后端不新增 API；服务器模式歌曲的权重 / 收藏 / 断点同样落本地，阶段 5 再接同步上推。
> `flutter analyze` 0 问题，`flutter build linux --debug` 与 `flutter build apk --debug` 均通过。

- ✅ 播放模式 ×4：顺序（默认）/ 列表循环 / 单曲循环 / 加权随机；切换入口播放页 + 队列面板
- ✅ 加权随机：factor 连续 0.5~1.5 步长 0.1；每步全量排除上一首采样（非无放回）；complete/skip 事件自动调权（详见 §7.1）
- ✅ 喜欢 / 不喜欢 UI（播放页 ❤️/👎 + 权重芯片；SongTile 收藏通用化，服务器歌曲也可喜欢）
- ✅ 收藏统一收口 `play_meta.is_favorite`（直连 + 服务器单一数据源）；旧 `idx_songs.is_favorite` 一次性回填迁移
- ✅ 喜欢列表：内容区「喜欢」分栏目走 `direct.favoriteSongs()`（同 play_meta 统一数据源）
- ✅ 歌单：`PlaylistStore` + `PlaylistsProvider`；`playlists_view.dart` 列表/详情原地子视图（新建/重命名/删除/播放全部/上移/下移/移除）+ SongTile ⋮「加入歌单」弹层
- ✅ 断点续播：`Song.toJson/fromJson` + `play_state` 单行（2s 节流），启动恢复为**暂停态**不自动播放
- ✅ 喜欢歌自动缓存 + LRU（`cached_at/last_accessed_at`，跳过正在播放）；收藏自动缓存开关在 `设置 → 歌曲`，缓存上限已迁至 `设置 → 服务端`（双来源，见 settings.md §3.3）
- ✅ 规划设置项见 §6.7（`play_mode_default` / `player_show_weight` / `resume_on_startup` / 淡入淡出 / 均衡器 / 缓存双来源 / 通知控制）与 settings.md §3 全套面板（含忽略音频过滤 / 仅 Wi-Fi 扫描 / 缓存双来源 / 导入导出）
- 验收（蓝图 §三 核心行为）：加权随机按概率选歌、同首不连续播放、喜欢可一轮多次 / 不喜欢可能多轮一次；连续 3 次完整播放 factor 提高（反之降低）；杀 App 重开断点续播；四种模式切换正确

### 阶段 3：直连 WebDAV + 本地索引（~1 周）

> **状态：已完成✅（含后续扫描优化迭代）** —— 直连 WebDAV/本地源 + 本地索引全链路落地（§6.4 / §6.5），
> 增量指纹（size/mtime/etag）、`minimal/fast/full` 扫描模式、播放时懒补全、进度/取消、本地变化自动扫描均已落地（均为 APP 侧扫描；服务端不再扫描入库）。
> 双端构建通过、`webdav_scan_test` 3 条 + `audio_metadata_test` 8 条全部通过。
> 早期附加 mp3/flac 乱码修复：需对已有源重新扫描一次覆写旧索引行（`upsert` 无条件覆盖）。

- ✅ `WebdavDirectSource`：dart:io `PROPFIND Depth:1` 并发递归（`package:xml`）+ `Range` 流式（seek/断点）+ 纯 Dart 头部元数据解析（mp3 ID3v2 / flac STREAMINFO+VORBIS_COMMENT），头部越界保护
- ✅ 本地轻量索引（§6.4）：`LocalIndex`（sources/idx_songs/cache）、Isolate 扫描器（`scan_worker.dart`）、`(ref,size,mtime,etag)` 增量与 missing 标记、封面落 `covers/<hash>.jpg`
- ✅ 扫描优化：三档模式 + `head_bytes` 配置、批量 `upsertSongs`、进度/取消、并发池、自动扫描（本地 watcher + 周期快扫）、播放时 `enrichSong` 懒补全（§6.4）
- ~~✅ 后端扫描增量：`MusicScanner` 指纹跳过 + `getlastmodified` 解析 + 并发探测 + album 缓存 + `@Scheduled` 定时（§4.5 / settings.md §5.1）~~ 已移除（服务端不再扫描；歌曲只由 APP 在播放源处扫描）
- ✅ 直连浏览：`SourcesScreen` 卡片三点菜单 + `SourceBrowseView` 文件夹式内页（扫描/进度/取消 → 搜索 → 播放 → 收藏 → 缓存全链路）；离线缓存（§6.6）
- ✅ 全局库合并（§6.5）：`LibraryProvider` 合并 ServerProxy + 直连源（去重），专辑/歌手客户端聚合；按 `sourceKey` 逐首解析源实现
- ✅ 三平台源骨架：ServerProxy / Webdav / Local 完整，SMB（阶段 4）
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
| R2 | 鸿蒙三方 Flutter 分支的平台通道兼容性，以及 **pub 插件生态缺口**（path_provider/file_picker/audio_session 等常用包在鸿蒙分支可能无实现） | 鸿蒙直连受限、依赖选型受约束 | 阶段 4 明确验证节点：逐个核对核心依赖的鸿蒙实现，无实现则找替代或自行补通道；选型期优先纯 Dart 包；降级路径清晰（仅 WebDAV） |
| R3 | WebDAV 服务端差异（PROPFIND 深度/鉴权/限流） | 个别云盘不可用 | 连接测试按钮 + 超时重试封装；适配名单维护在文档 |
| R4 | 直连扫描耗流量/电量 | 用户感知差 | 仅 Wi-Fi 扫描开关；增量指纹（size/mtime/etag）跳过未变文件；`minimal`/`fast` 减流量；头部严格 Range（`head_bytes` 可配）；单源上限 |
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
