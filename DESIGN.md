# SelfMusic 整体设计文档

> 状态：设计稿 **v2**（阶段 1 骨架 + 阶段 1 认证已落地，其余待实施）
> 定位：**去中心化的个人音乐服务器 + 双模式客户端**
> 上游约束：`开发思路.txt`（无中心账号 / 本地+SMB+WebDAV 曲库 / 加权播放 / 喜欢歌自动缓存）

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
| 后台增量扫描 | ❌ 手动/进入时刷新 | ✅ 定时+手动 | |
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
  · 服务器首次启动自动生成，settings 表持久化，管理页可见可重置
  · 仅用于 /auth/pair 配对一次，不用于日常请求
  · 以明文存储（需要展示成二维码），泄露可随时重置

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
| `pairing_token` | 随机生成 | 主配对令牌 |
| `cache_max_bytes` | 1073741824 (1GB) | 全局建议值，App 可下发 |
| `cache_song_limit` | 500 | |
| `scan_interval_min` | 0（关） | 定时扫描间隔 |
| `transcode_max_concurrency` | 2 | 全局 ffmpeg 并发上限 |
| `upload_dir` | `{LOCAL_ROOT}/Uploads` | 上传落点 |

`songs` 权重相关字段与触发规则见 §7.1。

### 3.2 客户端（SQLite，drift 管理）

| 表 | 说明 |
|----|------|
| `sources` | 源配置：`type(local/smb/webdav/server)`、名称、加密的凭据 JSON、enabled、last_scan_at |
| `idx_songs` | 直连模式本地索引：`source_id, source_ref, title, artist, album, track_no, duration, file_mtime, file_size, format, cover_path` |
| `playlists_local` / `playlist_items_local` | 歌单镜像（含 `pending_sync` 标记，服务器模式下推送） |
| `weight_outbox` | 待上推的权重事件流水：`event_uuid, song_key, event, created_at` |
| `play_state_local` | 断点：`(list_key, song_key, position_ms)` |
| `cache_meta` | 已缓存歌曲：`cache_key, local_path, size_bytes, cached_at, bitrate` |

要点：

- `song_key` 统一为 `(来源标识, source_ref)` 复合键；同一首歌在不同模式下可解析到不同 Source 实现
- 凭据加密：WebDAV/SMB 密码经 `flutter_secure_storage` 存放，SQLite 只存引用键
- 离线优先：所有播放决策只查本地表；网络层的角色是把远端变更搬进本地

---

## 4. API 设计

统一约定：

- 前缀 `/api/v1`
- 响应包：`{ "code": 0, "message": "ok", "data": ... }`
- **认证**：除 `/health`、`/auth/pair`、`/auth/refresh`（匿名）外全部要求 `Authorization: Bearer <access_token>`；无效/吊销返回 `code=40101`；**access 过期返回 `HTTP 401` + 响应头 `X-Token-Expired: true`**
- 设备识别头 `X-Client-Id` 必带（与 devices.client_id 对应）
- 分页：`page`（1 起）、`size`（默认 50，≤500）；响应含 `total`

### 4.1 认证与设备

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/health` | 免认证存活检查 |
| POST | `/auth/pair` | `{pairing_token, device_name, platform}` → `{client_id, access_token, refresh_token, expires_in=86400, refresh_expires_in=2592000}`；主令牌错误返回 `code=40100` |
| POST | `/auth/refresh` | 匿名白名单；`{refresh_token}` → 轮换式换发新 `{access_token, refresh_token, ...}`；无效/过期返回 `code=40102` |
| POST | `/auth/unpair` | 自我注销（吊销当前设备） |
| GET | `/meta/server` | 版本、ffmpeg 可用性、源概况（需认证） |

### 4.2 曲库浏览与搜索（服务器模式）

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/library/songs` | 过滤：`q/artist/album/source/favorite/hidden` |
| GET | `/library/songs/{id}` | 详情（含权重） |
| GET | `/library/albums` · `/library/albums/{id}` | 专辑列表/详情 |
| GET | `/library/artists` | 歌手聚合 |
| GET | `/library/folders` | 目录浏览 `?source=&path=` |
| GET | `/library/favorites` | 收藏快捷端点 |

### 4.3 流媒体（服务器模式）

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/stream/{id}?br=&format=` | Range 流式；缺省原码率透传 |
| HEAD | `/stream/{id}` | 探测长度/时长 |
| DELETE | `/stream/{id}` | 显式停止（关闭 ffmpeg 子进程） |

### 4.4 状态同步（服务器模式）

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/sync/pull?since_cursor=` | 增量拉取（歌单+权重+断点），返回新 cursor |
| POST | `/sync/push` | 批量上推权重事件流水/断点/歌单差异；幂等按 `event_uuid` 去重 |
| CRUD | `/playlists` 系列 | 见 v1 §3.4，不变 |
| PUT | `/playstates/{playlistId}` | `{song_id, position_ms}` |
| POST | `/songs/{id}/weight` | `{event: liked\|disliked\|reset\|favorite\|unfavorite}`，服务端重算权重 |

### 4.5 管理（App 管理模块）

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/admin/config` | 当前配置概览 + 主配对二维码内容（`selfmusic://pair?...`） |
| POST | `/admin/pairing-token/reset` | 重置主令牌 |
| GET/PUT/DELETE | `/admin/devices[...]` | 设备列表 / 改名 / 吊销 |
| POST | `/admin/scans` · GET `/admin/scans[/id]` | 触发/查询扫描任务 |
| POST | `/admin/upload/init` → `/part/{n}` → `/commit` | 分片上传（16MB/片） |
| DELETE | `/library/songs/{id}?hard=` | 移出索引；`hard=true` 删源文件（仅 local 源允许） |
| GET/PUT | `/admin/settings` | 设置读写 |

---

## 5. 后端模块与选型

### 5.1 包结构（`com.selfmusic.backend`）

```
config/       SourceProperties / SecurityConfig(Bearer过滤器) / WebConfig(CORS)
auth/         PairingService, DeviceService, TokenFilter
scanner/      ScanService, IncrementalScanWorker, TagReader(jaudiotagger)
              MusicSource 接口 + SmbSource / WebdavSource / LocalSource
library/      SongController, AlbumController, CoverController
stream/       StreamController, FfmpegTranscoder, TransparentProxy
sync/         SyncService, PlayStateService, WeightService
admin/        DeviceAdminController, ScanTaskController, UploadController, SettingController
domain/       JPA 实体与 Repository
common/       ApiResponse, GlobalExceptionHandler, PageResult
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
| prod | `eclipse-temurin:21-jre` | apt 加 `ffmpeg`；non-root 用户 |
| dev | `maven:3.9-eclipse-temurin-21` | 同上加 `ffmpeg`（保持与 prod 行为一致） |

环境变量：`PAIRING_TOKEN_INIT`（可选，首次启动注入固定令牌便于自动化）、其余同 v1。

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
│   ├── sidebar.dart        侧边栏：设置分区(常规/播放/界面/歌曲/通知)+底部(明暗/退出)
│   ├── top_bar.dart        顶栏：上层汉堡+搜索，下层导航(播放列表/喜欢/播放源/歌曲/专辑/歌手)
│   ├── queue_panel.dart    右侧播放队列面板
│   └── mini_player_bar.dart 底部"正在播放"条
├── providers/            ★ 状态
│   ├── navigation_provider.dart  分区/设置/播放页视图切换
│   ├── player_provider.dart      全局播放(AudioPlayer+队列)，播放页/队列/迷你条共享
│   ├── library_provider.dart     曲库
│   └── auth_provider.dart        配对 + 会话过期态
├── services/             dio 封装(ApiClient 含懒刷新拦截器)、AuthService
├── data/sources/         ★ Source 抽象层 (ServerProxy / Local / Webdav / Smb)
├── models/               Song / Album ...
└── screens/              AppContent(内容区) / settings(界面主题设置) / player / pairing
```

> **platform 收口层**（§6.3 的 `capabilities`）与 **drift 本地库** 尚未落地，属路线图后续阶段。

> **为什么要有 `platform/` 层**：鸿蒙走的是三方 Flutter 分支而非官方 target，`Platform.isXxx` 行为、原生插件实现均可能与官方平台不一致。业务代码禁止直接写 `Platform.isAndroid` 之类判断，一律询问 `capabilities`；鸿蒙加入时只需在 `platform/harmonyos/` 提供一套实现，不动上层。

### 6.2 Source 抽象层（双模式的基石）

```dart
abstract class MusicSource {
  String get key;                       // 稳定标识: 'server'/'smb:nas1'/'webdav:xx'
  SourceKind get kind;
  Future<ScanResult> scan();            // 建本地索引（增量）
  Future<SongMeta> probe(String ref);   // 头部元数据（Range 读头部）
  Stream<List<int>> open(String ref, {IntRange? range}); // 音频流
  Future<void> close();
}
```

- 播放器只认 `MusicSource`，不感知模式
- `ServerProxySource.open()` 即 GET `/stream/{id}`；直连实现各自对接协议
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

- 首次添加源 → 后台 Isolate 扫描：列目录（WebDAV PROPFIND Depth:infinity 或逐级；SMB 递归枚举）→ 对每个音频文件 Range 取头部 → `audio_metadata_reader`（纯 Dart，mp3/flac/m4a）解析标题/歌手/专辑/封面 → 写入 `idx_songs`
- 时长探测：mp3 估算法（文件大小÷码率）或解析 Xing/VBRI 头；flac 读 STREAMINFO
- 增量：以 `(ref, mtime, size)` 三元组比对；消失项标记 `missing`（保留缓存歌的可播性）
- 封面：提取嵌入图存应用目录 `covers/<hash>.jpg`，SQLite 存路径
- 大目录保护：单源上限 20k 首，超出提示分目录添加

### 6.5 网络与离线

- `dio`：API 超时 5s、指数退避重试 3 次；流式请求超时 ∞
- **懒刷新拦截器（ApiClient）**：`onRequest` 自动带 `Bearer access`；`onError` 命中 `401 + X-Token-Expired` 时用 `refresh_token` **单飞（single-flight）**换发新 token 并对原请求重放一次；刷新失败清空令牌并触发 `onSessionExpired` → "会话过期"弹窗重新配对。
- 断网判定：连续失败 → 进"离线模式"，UI 顶栏提示；播放范围收缩为 `cache_meta` 命中项
- 恢复网络：SyncEngine 自动恢复，先推 outbox 再拉增量

---

## 7. 播放算法与同步协议

### 7.1 加权播放（蓝图 §三.2 的落地）

设列表 n 首（n≥2）：

```
基础权重 w₀ = 1/n
weight = w₀ × factor
factor ∈ [0.5, 1.5]：
  is_favorite 或 like_streak≥1 连发达标   → factor 升至 1.5
  dislike_streak≥1 连发达标               → factor 降至 0.5
frozen=true                              → factor 恒为 1.0
选择时排除上一首（n>1），对剩余集合归一化使 Σp=1
```

事件规则（服务端与客户端逻辑一致，服务端为准）：

| 事件 | 判定 | 效果 |
|------|------|------|
| complete_play | 播放 ≥70% 时长自然结束 | like_streak++，dislike_streak=0；streak 达 3 → factor→1.5 并清零 streak |
| skip | 中途跳出（<70%） | dislike_streak++，like_streak=0；达 3 → factor→0.5 并清零 |
| liked / unfavor | 手动点击 | 直接置 favorite / factor 立即生效 |
| reset | 手动重置 | 两 streak 清零，factor 回 1.0 |

### 7.2 同步协议（仅服务器模式）

- **方向**：客户端本地 SQLite 是运行时事实源；后端是多设备汇聚点
- **Pull**：启动全量校准 + 每 30s `GET /sync/pull?since_cursor=`；cursor 为服务端单调递增变更号
- **Push**：本地产生权重事件/断点/歌单改动 → 写 `weight_outbox`（带 event_uuid）→ 2s 防抖批量上推；服务端按 uuid 幂等去重
- **冲突**：last-write-wins；权重走**事件重算**而非绝对值覆盖（两设备并发点赞不会互相抹掉）；歌单条目用 `sync_ver` 乐观锁，失败则重拉重放
- 直连模式：上述全部跳过，数据只在本机

---

## 8. 分阶段路线图

> 每阶段独立可交付；估时按单人业余投入。

### 阶段 1：双模式骨架 + 服务器核心（~1.5 周）

> **状态：主体已完成✅** —— 认证（access/refresh 轮换 + 过期懒刷新）、可换主题的自适应 UI 框架、全局播放器（mpv 后端）均已落地；SMB/WebDAV 直连源、本地索引与后台扫描仍待实施。

- 后端：SecurityConfig+TokenFilter(**含过期校验/X-Token-Expired**) + devices/auth API(**pair + refresh 轮换**)；MusicSource 抽象+Smb/Webdav/Local 实现(**ServerProxy 完整可用**)；扫描入库；`/library/**`、`/stream/**`；镜像加 ffmpeg
- App：Source 层四实现骨架（ServerProxy 完整可用）、**可换主题自适应 UI 框架（theme/layout/providers)**、基础播放器（顺序播放）、配对页
- 验收：配对一台真机 → 浏览三源曲目 → 任选一首流式播放；未带 token 的请求被拒

### 阶段 2：加权播放 + 歌单 + 喜欢歌缓存（~1 周，蓝图核心）

- 加权队列、complete/skip 事件采集、喜欢/不喜欢 UI
- 歌单增删改排序；喜欢歌自动缓存 + LRU + 上限设置
- 验收：蓝图 §三 全部行为可演示；杀 App 重开断点续播

### 阶段 3：直连 WebDAV + 本地索引（~1 周）

- WebdavDirectSource 完整实现；本地索引扫描器（Isolate）；直连模式的浏览/搜索页
- 验收：**卸载后端场景**——只配 WebDAV 源，完成扫描→搜索→播放→收藏→断网播缓存 全链路

### 阶段 4：全平台 SMB 直连（~1–2 周，风险最高）

- Windows UNC 通路（先行，半天）；Android smbj 平台通道 PoC（1 天硬门槛）→ 正式实现；鸿蒙验证（三方分支 + 核心依赖 just_audio/path_provider/drift 的鸿蒙可用性逐项核查，同时此阶段才搭建 DevEco 环境）
- 验收：Android 真机直连 NAS 播放 SMB 歌曲，seek/断点正常；鸿蒙给出可行/降级结论

### 阶段 5：多设备状态同步（~1 周）

- `/sync/*` 全套；SyncEngine；设备管理页
- 验收：两台设备 30s 内状态收敛；断网操作恢复网络后正确合并

### 阶段 6：转码 + 管理闭环（~1 周）

- ffmpeg 按需转码管线与并发上限；分片上传；删除/隐藏；设置页
- 验收：FLAC 源按 128k 出流实测流量达标；上传 50MB 文件入库可播

---

## 9. 风险与开放问题

| # | 风险 | 影响 | 缓解 |
|---|------|------|------|
| R1 | smbj×Android 平台通道（性能/稳定性未知） | 阶段 4 可能返工 | PoC 硬门槛前置；备选 jSMB/系统 smbclient 子进程；最坏降级"移动端直连仅 WebDAV" |
| R2 | 鸿蒙三方 Flutter 分支的平台通道兼容性，以及 **pub 插件生态缺口**（path_provider/file_picker/audio_session 等常用包在鸿蒙分支可能无实现） | 鸿蒙直连受限、依赖选型受约束 | 阶段 4 明确验证节点：逐个核对核心依赖的鸿蒙实现，无实现则找替代或自行补通道；选型期优先纯 Dart 包；降级路径清晰（仅 WebDAV） |
| R3 | WebDAV 服务端差异（PROPFIND 深度/鉴权/限流） | 个别云盘不可用 | 连接测试按钮 + 超时重试封装；适配名单维护在文档 |
| R4 | 直连扫描耗流量/电量 | 用户感知差 | 仅 Wi-Fi 扫描开关；头部探测严格 Range；单源上限 |
| R5 | ffmpeg 容器 CPU 占用 | 多设备并发卡顿 | 全局并发上限默认 2；超限降级透传 |
| R6 | 大曲库查询性能 | 列表慢 | 索引齐备；`q` 前缀匹配；预留 FTS 开关 |
| R7 | 公网暴露 | 曲库/上传被滥用 | Bearer 认证已是第一道门；文档仍建议叠加 IP 白名单 |
| R8 | 转码流 position 精度 | VBR 断点 ±2s | 文档注明；CBR 精确 |

### 待拍板（沿用 v1，默认按文中执行）

1. 上传落点 `Uploads/` 可配 —— 默认如此
2. 定时扫描默认关闭 —— 默认如此
3. 封面 128/512 两档 —— 默认如此
4. `hard=true` 仅限 local 源 —— 默认如此
5. `frozen` 是否暴露 UI —— 默认隐藏，仅数据库字段就位
