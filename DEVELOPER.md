# SelfMusic 开发者文档

本文档面向项目开发者，是**开发落地的主文档**：环境搭建、构建矩阵、日常流程、常用命令、客户端实现要点（SQLite 写隔离 / 扫描 / 同步）、调试排查。

文档分工：

| 想知道 | 看哪 |
|--------|------|
| 快速跑起来、服务与端口 | [README.md](README.md) |
| **怎么开发、代码怎么写、改完怎么验证**；整体架构 / 数据模型 / API 契约 / 播放算法 / 同步协议 / 风险 | **本文** |
| 设置项键名、默认值、入口、生效范围 | [settings.md](settings.md) |

原则：**机制与取舍、写代码时必守的规则与命令都在本文**，同一段实现细节只写一处。

---

## 目录

- [环境要求](#环境要求)
- [项目结构](#项目结构)
- [总体架构](#总体架构)
- [身份与设备配对](#身份与设备配对)
- [数据模型](#数据模型)
- [API 设计](#api-设计)
- [后端开发](#后端开发)
  - [后端模块与选型](#后端模块与选型)
- [前端开发](#前端开发)
  - [平台收口层](#平台收口层libplatform)
  - [客户端播放源（Source 抽象层）](#客户端播放源source-抽象层)
  - [客户端播放要点（装载/切歌/返回）](#客户端播放要点装载切歌返回)
  - [客户端本地数据层（SQLite 写隔离）](#客户端本地数据层sqlite-写隔离)
  - [客户端扫描与元数据](#客户端扫描与元数据实现要点)
  - [客户端同步与缓存批处理](#客户端同步与缓存批处理)
  - [歌词与后台播放](#歌词与后台播放)
  - [列表 / 卡片 / 多选](#列表-卡片-多选)
  - [鸿蒙适配](#鸿蒙适配)
- [播放算法与同步协议](#播放算法与同步协议)
- [配置说明](#配置说明)
- [常见问题排查](#常见问题排查)
- [风险与开放问题](#风险与开放问题)
- [Git 约定](#git-约定)

---

## 环境要求

| 依赖 | 版本 | 用途 |
|------|------|------|
| JDK | 21 | 后端编译运行（宿主机与容器保持一致） |
| Maven | 3.9+ | 后端构建 |
| Docker + Compose | 任意近期版本 | 后端容器化运行 |
| MySQL | 8.0 | 宿主机已有实例 |
| Flutter SDK | stable（Dart ≥3.4，pubspec `sdk: ^3.4.0` 下限对齐鸿蒙 ohos 分支） | 前端开发。直接使用系统 `flutter`（FVM 可选，见「版本管理」） |
| FVM（可选） | 最新稳定版 | 团队协作时锁定 Flutter 版本，防版本漂移 |
| Android SDK / Android Studio | 最新稳定版 | Android 构建调试 |
| Visual Studio 2022 | 含"使用 C++ 的桌面开发"负载 | Windows 桌面构建（在 Windows 机器上） |

> 注意区分：**Visual Studio 2022**（Windows 原生编译工具链，MSVC + Windows SDK + CMake/Ninja）≠ **VS Code**（日常写 Dart/Java 的编辑器）。Flutter 官方 Windows Desktop 构建依赖前者。
>
> 鸿蒙（HarmonyOS NEXT）：Flutter 官方不支持，经三方分支 `CPF-Flutter/flutter_flutter`（`oh-3.41.9-release`）适配；**PoC 验收已通过、真机日常使用中**，详见「鸿蒙适配」一节。

### 多平台构建矩阵

不同平台的最终产物必须在对应操作系统上构建，一台 Ubuntu 无法完成全部：

> **平台开发原则**：Linux / Android / Windows / HarmonyOS 四平台同步开发、进度对齐（详见「[总体架构](#总体架构)」平台开发原则）——本矩阵只给结论，原因与验收口径在「总体架构」里。

| 目标平台 | 构建环境 | 状态 |
|---------|---------|------|
| Android | Ubuntu（Android Studio + SDK） | ✅ 可用；壳工程已重建（`android/app` + Gradle 配置齐全），`flutter build apk` 可出包 |
| Linux Desktop | Ubuntu（clang + GTK + cmake + ninja） | ✅ 可用：开发平台 |
| Web | 不做 | ❌ 明确排除 |
| Windows Desktop | Win10 开发机：Flutter stable + VS2022 Build Tools（C++ 桌面负载 + ATL） | ✅ 可用：`flutter build windows` 可出包；音频后端 media_kit；日常联调用根目录 `run-windows.bat` |
| HarmonyOS | Win10 开发机：DevEco Studio + HarmonyOS SDK + 真机 + 三方 Flutter 分支（`oh-3.41.9-release`） | ✅ PoC 验收通过（2026-09-30）；详见「鸿蒙适配」 |

### 环境搭建顺序

**现在：**
1. Flutter（系统安装即可；FVM 可选）+ Linux toolchain
2. Android Studio + Android SDK + 接受 license
3. VS Code + Flutter/Dart 扩展
4. Git（项目已纳入 git 管理）
5. （可选）FVM：`fvm use stable` 生成 `.fvmrc` 入库

**暂时不需要：**
- Chrome / Web SDK（不做 Web）

**平台扩展：**
- Windows 出包 → ✅ 已就绪（Win10 机器，VS2022 Build Tools + ATL 补装）
- 鸿蒙 → ✅ PoC 验收通过、真机日常使用中（DevEco Studio + SDK + 真机，Win10 机器）；Ubuntu 上**不要**装鸿蒙 SDK

**Windows 构建网络常见问题（新机器必读）：**
- `media_kit_libs_windows_audio` 在 CMake configure 阶段从 GitHub release 下载 `mpv-dev-*.7z`（约 5MB）并做 MD5 校验，弱网下会留下 0 字节残片并反复报 `Integrity check failed`——删除 `build/windows/x64/mpv-dev-*.7z` 后手动下载放回原位即可（期望 MD5 见该插件 `windows/CMakeLists.txt`）
- `permission_handler_windows` 用 `find_program` 在 PATH 里找 `nuget.exe`（拉 CppWinRT 头用），找不到就退回 CMake 内置下载器（无超时，弱网下挂死）——把 `nuget.exe` 放在 flutter wrapper 同目录即可，`run-windows.bat` 已做 PATH 注入与 `NUGET_HTTP_CACHE_PATH` 重定向（缓存落 D 盘）
- configure 中途失败（如上两条）会留下脏 `CMakeCache.txt`：`CMAKE_INSTALL_PREFIX` 停在 `C:/Program Files/selfmusic`，重试构建报 `file cannot create directory ... Maybe need administrative privileges`——把 cache 中该值改回 `build/windows/x64/runner/Debug`，或删整个 `build/windows` 重建

---

## 项目结构

```
selfmusic/
├── backend/                          # Spring Boot 后端
│   ├── Dockerfile                    # 生产镜像：多阶段构建 → temurin-21-jre 运行
│   ├── Dockerfile.dev                # Dev 镜像：JDK 21 + Maven（容器内跑 spring-boot:run）
│   ├── pom.xml
│   └── src/main/
│       ├── java/com/selfmusic/backend/
│       │   ├── SelfMusicApplication.java
│       │   ├── common/               # ApiResponse / BizException / MusicSource 枚举 / 全局异常
│       │   ├── config/               # FirstBootInitializer 等启动配置
│       │   ├── auth/                 # SecurityConfig / TokenFilter / 配对与设备管理 API
│       │   ├── playlist/             # 歌单 CRUD + 断点 PUT（阶段5，走 SyncService 事件管线）
│       │   ├── sync/                 # 同步引擎服务端：SyncController pull/push + SyncService（去重/重算/LWW/cursor）
│       │   └── domain/
│       │       ├── entity/           # JPA 实体（纯手写 getter/setter，不用 Lombok）
│       │       └── repository/       # Spring Data JPA 接口
│       └── resources/
│           ├── application.yml
│           └── db/migration/        # ★ Flyway V1/V2/V3（服务端 schema 唯一事实源）
├── frontend/                         # Flutter 前端
│   ├── lib/
│   │   ├── main.dart                 # 入口 + Provider 装配 / Root
│   │   ├── platform/                 # ★ 平台收口层（平台差异收敛，bootstrap 装配），当前只有 harmonyos/
│   │   ├── theme/                    # 可配置主题（app_theme / theme_provider）
│   │   ├── layout/                   # 自适应布局（app_shell / sidebar / top_bar / queue_panel / mini_player_bar）
│   │   ├── providers/                # 状态（auth / library / player / navigation / playlists / direct_source_manager）
│   │   ├── services/                 # dio+懒刷新拦截器(ApiClient)、AuthService、ServerSettings、SyncEngine（阶段5 推拉/cursor/退避）
│   │   ├── data/sources/             # MusicSource 抽象 + WebdavDirect + LocalDirect + SmbDirect + sibling_cover（同目录图片回退）
│   │   ├── providers/direct_task_queue.dart  # 直连补读的串行优先级队列（当前曲 → 下一首 → 全库）
│   │   ├── data/deep_list.dart       # 深层列表：锚定列表的「仅可改末尾」有界历史栈（见「播放算法与同步协议」）
│   │   ├── data/local/               # ★ 本地数据层：schema（建表迁移唯一事实源）+ db_writer（后台写隔离）
│   │   │                            #   + local_index（主连接只读/写 API 转发/flushWrites）
│   │   │                            #   + audio_metadata（mp3/flac/m4a/ogg·opus/wav/aac 头部解析 + 两段/尾读）
│   │   │                            #   + song_weight_store / playlist_store / cache_manager / app_settings / backup_service
│   │   │                            #   + 阶段5：sync_event_types / weight_outbox / breakpoint_mirror
│   │   ├── models/                   # Song / Album / Artist
│   │   ├── utils/                    # duration_format / song_title_format / lrc_parser
│   │   ├── widgets/                  # 共享组件（SongTile / CoverThumb / lyrics_view / add_to_playlist / view_mode_toggle 等）
│   │   └── screens/                  # library / playlists_view / sources / source_browse_view / settings / player / pairing / devices（阶段5 设备管理）
│   ├── android/ linux/ windows/ ohos/   # 各平台壳工程（ohos 的 build-profile.json5 含本机签名材料不入库，模板 build-profile.json5.example）
│   ├── third_party/               # vendored fork：audio_service（通知栏 5 键自定义按钮）、dart_smb2、smb_connect
│   └── pubspec.yaml
├── nginx/selfmusic.conf              # Nginx 反代模板（部署到宿主机）
├── docker-compose.yml                # backend（18088）+ backend-dev（18089，profile: dev）
├── run-linux.sh                      # Linux 快速运行：cd frontend && flutter run -d linux
├── run-android.sh                    # Android 快速运行：flutter run -d <设备id> --dart-define=API_BASE_URL=<后端>
└── .env                              # 数据库连接等敏感配置（不入库）
```

**分层约定**：`Controller → Service → Repository`，Controller 只做参数校验和响应封装，业务逻辑放 Service。

---

## 总体架构

**定位**：去中心化的个人音乐服务器 + 双模式客户端。App 在**无后端**时靠本地 / WebDAV / SMB / SFTP 直连完整可用（扫描、播放、歌单、收藏、歌词、断点），后端是**增强层**（认证配对、多设备状态同步、无状态转码代理）。

```
                        ┌─────────────────────────────────┐
                        │           Flutter App            │
                        │  播放引擎（加权算法）             │
                        │  本地 SQLite（状态事实源）        │
                        │  缓存管理（LRU、喜欢歌）          │
                        │  歌手身份聚合（MusicBrainz）      │
                        │  ───────────────────────────     │
                        │  Source 抽象层                   │
                        │   LocalDirect / WebdavDirect     │
                        │   SmbDirect（双后端）            │
                        │   SftpDirect                     │
                        └───────────────┬─────────────────┘
                                        │ 协议直连（App 内扫描 / 播放）
                                        ▼
                           ┌──────────────────────┐
                           │  音乐源（协议直连）    │
                           │  · NAS(SMB)          │
                           │  · WebDAV 服务        │
                           │  · SFTP 服务器        │
                           └──────────────────────┘
                                        ▲ 状态同步（权重/收藏/歌单/断点/播放源）
                                        │ 配对与设备管理（无曲库 / 无流媒体）
                                        │ SSH/SMB 回源取流（仅代理转码）
                           ┌──────────────────────┐
                           │ Spring Boot 后端      │
                           │ （个人单用户同步服务）  │
                           └──────────────────────┘
```

**功能矩阵**（现状）

| 功能 | 现状 | 说明 |
|------|:---:|------|
| 本地文件 / WebDAV / SMB / SFTP 浏览与播放 | ✅ | 全部直连实现，不依赖后端 |
| 歌单 / 加权算法 / 喜欢·不喜欢 / 喜欢歌自动缓存 | ✅ | 本地 SQLite |
| 曲库浏览 / 跨源搜索 / 歌词 / 后台播放 / 通知栏 5 键 | ✅ | 本地能力（通知键 Android；鸿蒙走 AVSession） |
| 歌手身份聚合（MusicBrainz 后台解析） | ✅ | 纯客户端本地，不参与同步 |
| 多设备状态同步（权重 / 收藏 / 歌单 / 断点 / 播放源） | ✅ | 需要后端 |
| 转码（按需 ffmpeg）/ 上传·删除源文件 | ✅ | 服务端无状态代理；上传删除走客户端源直写 |

**平台开发原则（约定）**：**Linux / Android / Windows / HarmonyOS NEXT 四平台同步开发、进度对齐**。`lib/` 下的 UI / 主题 / 播放器 / 鉴权 / 状态层均为跨平台 Dart 代码，演进时不另起分支；任何特性落地须在四平台配套走通（音频后端 / 权限 / 生命周期差异用条件导入或「[平台收口层](#平台收口层libplatform)」收口），以「四个平台都能跑通验收项」作为阶段完成判定。鸿蒙的平台差异统一收敛在「[鸿蒙适配](#鸿蒙适配)」一节。各平台构建环境见「[多平台构建矩阵](#多平台构建矩阵)」。

---

## 身份与设备配对

- 语义：**一台服务器 = 一个主人**（自建自用），无注册 / 登录体系；去中心化，App 可保存多个服务器配置。
- 令牌模型（OAuth2 风格 access + refresh）：

```
主配对令牌 (pairing_token)
  · 权威来源 = 环境变量 PAIRING_TOKEN；每次启动覆盖写入 settings 表（DB 仅为镜像）
  · 未提供 PAIRING_TOKEN 时沿用库中旧值；首次初始化（库中无）才随机生成
  · 仅用于 /auth/pair 配对一次，不用于日常请求；明文存储（需展示成二维码）
  · 改 .env 重启即生效，仅影响新设备，已配对设备不受影响

访问令牌 (access_token / device_token)
  · pair 成功后签发，TTL 24h（expires_in=86400），仅存哈希 token_hash
  · 日常请求携带 Authorization: Bearer <access_token>
  · 过期 → 拒绝（HTTP 401 + 响应头 X-Token-Expired: true）

刷新令牌 (refresh_token)
  · TTL 30d（refresh_expires_in=2592000），仅存哈希 refresh_token_hash
  · 仅用于 POST /auth/refresh 换发新的一套 access+refresh
  · 轮换式：用过的 refresh_token 立即作废，同一套只能换一次
```

- 二维码内容：`selfmusic://pair?host=xxx&port=18089&token=xxxx`
  > 端口说明：后端应用本身监听 **8080**（`application.yml`），`18089` / `18088` 是 docker-compose 的主机侧映射（dev / prod）。App 填的端口须与实际可达入口一致。
- **懒刷新（lazy refresh）**：不做定时器；仅当某请求命中 `401 + X-Token-Expired` 时，客户端才用 refresh_token 换发新 token 并对原请求重放一次（并发请求以「单飞 single-flight」共享一次刷新，避免重复轮换）。
- 刷新失败（refresh 失效 / 过期）→ 客户端清空令牌，进入「会话过期」弹窗引导重新配对。
- 单台吊销不影响其他设备；重置主令牌只影响新设备（已配对设备不受影响）。

---

## 数据模型

### 服务端（MySQL 8）

> 服务端表结构唯一事实源 = `backend/src/main/resources/db/migration/V*.sql`。后端启动时 Flyway 自动执行版本化 SQL 并记录 `flyway_schema_history`；随后 JPA `ddl-auto: validate` 只校验实体与最终表结构是否一致。全新库只需建库建账号；存量库没有迁移历史时自动 baseline 到 V1，再补 V2/V3/V4（V2 为幂等 MODIFY，V3/V4 按列/索引存在性判断，已手工执行过旧 migration 的库重复执行也安全）。
>
> - `V1__baseline.sql`：1e247ab 时的完整基线（含 migration_002…009 的结果）
> - `V2__sync_payload_mediumtext.sql`：TEXT → MEDIUMTEXT（幂等，兼容尚未执行 009 的存量库）
> - `V3__breakpoint_head_v2.sql`：断点协议 v2 字段 + 旧行回填 + epoch 初始化
> - `V4__song_progress_hist.sql`：`song_states.progress_hist` 播放进度直方图（101 桶 JSON，幂等）
> - **发布过的 V 文件不要修改**（Flyway 校验 checksum）；后续变更新增 `V5__xxx.sql`。

| 表 | 说明 |
|----|------|
| `song_states` | 直连歌权重 / 收藏状态（`source_id`+`source_ref` 唯一，无曲库字段；含 `play_sec`、`progress_hist`） |
| `sync_sources` | 播放源同步（`client_uuid` 唯一；`kind+address` 去重；config 不含密码） |
| `playlists` / `playlist_items` | 歌单与条目（条目自持 `source_id/source_ref` + 标题/歌手/专辑/时长快照） |
| `play_states` | 每列表断点（自持歌曲身份 + `device_client_id`；`deep_list_json` MEDIUMTEXT；v2 另有 `head_rev/head_clock/head_device/head_op_id/head_session/head_playing/head_updated_at` 与 `history_rev`，head/history 分离仲裁） |
| `sync_events` | 同步事件流水（`seq` 单调 cursor；`entity_key` 锚点供压缩；`payload` 为 MEDIUMTEXT，容纳断点 deep_list） |
| `settings` | 全局设置（含 `pairing_token`） |
| `devices` | 已配对设备（`client_id` / `token_hash` / `refresh_token_hash` / 过期时间 / `revoked` / `last_pull_cursor`） |

> 原 `albums/songs/covers/scan_tasks` 已随服务端曲库移除（`migration_004`）。

`settings` 实际存量为四键：`pairing_token`（env 镜像）、`cache_max_bytes`（默认 5 GiB）、`cache_song_limit`（默认 200）、`sync.server_epoch`（断点协议 v2 的服务端数据代次，首次使用自动生成，DB 重建后自动换新；客户端据此清空本地 revision）。缓存两键权威来源 = V1 迁移预置 + 每次启动被 `CACHE_MAX_MIB` / `CACHE_SONG_LIMIT` env 覆盖写入。

服务器端开发规范：

- 表结构变更：**新增 `backend/src/main/resources/db/migration/Vn__xxx.sql`**（不要修改已发布版本），同时更新对应 JPA 实体；`ddl-auto: validate` 不一致启动即报错
- 字符集统一 `utf8mb4`；所有表带 `id BIGINT AUTO_INCREMENT PRIMARY KEY`、`created_at`、`updated_at`
- 库/账号由管理员一次性创建，应用账号只需 `selfmusic.*` 权限，不需要 `CREATE DATABASE`

### 客户端（SQLite）

> 表结构权威定义在 `frontend/lib/data/local/schema.dart`（`applySchema()`，主读连接与写隔离共用、幂等）；写代码规则见「[客户端本地数据层](#客户端本地数据层sqlite-写隔离)」。

| 表 | 说明 |
|----|------|
| `sources` | 源配置：`key`（唯一）、`kind(local/webdav/smb/sftp)`、名称、凭据引用键、enabled、`last_scan_at`、`client_uuid`；SFTP 另含 host/port/user/认证方式/根路径（密码与私钥只存 SecretStore） |
| `ssh_known_hosts` | SFTP 主机密钥 TOFU 钉：`(host_port PK, fingerprint, updated_at)`；**不参与跨设备同步** |
| `idx_songs` | 直连模式本地索引（增量指纹含 `mtime,size,etag`）；ALTER 列 `album_artist / url / user_edited / meta_read` |
| `cache` | 缓存/预载文件：`cache_key` PK、`path,size` + `cached_at,last_accessed_at`（LRU 用）+ `source_key/song_ref`（按歌曲统计淘汰）+ `kind`（user/preload_origin/preload_variant/legacy）+ `variant_of`（变体对应原 key） |
| `play_meta` | 播放元数据：`(source_key,song_ref)` PK + `like_streak/dislike_streak/factor/frozen/is_favorite`（收藏统一收口）+ `play_sec` + `progress_hist` + `song_json` |
| `playlists` / `playlist_items` | 歌单与条目（含快照字段 + `sort_order`、`source`、`client_uuid`、`deleted` 墓碑） |
| `app_settings` | 客户端设置键值表（缓存配置 + 7 个排序持久化键等） |
| `song_lyrics` | 歌词：`(source_key,ref)` PK + `content`（LRC）+ 三态收录 |
| `play_state` | 断点：单行 `id=1`（`queue_json + idx + position_ms + updated_at` + `playlist_uuid` + `anchor_key` + `session_id`） |
| `weight_outbox` / `breakpoint_mirror` | 同步流水与跨设备断点镜像（镜像含 `deep_list_json` + v2 `head_rev/history_rev/head_clock/head_op_id/head_session/head_playing/head_updated_at`） |
| `breakpoint_sync_base` | 每个歌单本机已采用且与服务端确认过的深层列表（纯追加后缀 / 三向合并 base；带 `history_rev`；不随镜像盲进） |
| `breakpoint_sync_state` | 每个歌单的 v2 同步状态：`applied_head_rev / applied_history_rev / pending_head_op_id / session_id / server_epoch` |
| `deep_lists` | 深层列表：`playlist_uuid` PK + 有界历史栈 `entries_json` |
| `artists` / `artist_canon` / `artist_song_map` / `artist_member` | 歌手身份聚合（纯本地，不参与同步；见「[歌手身份聚合](#歌手身份聚合musicbrainz-后台解析)」） |

客户端建表规范：

- 表清单与字段以 `schema.dart` 的 `applySchema()` 为准：**改表只改这里**，主读连接与写隔离各跑一遍，幂等（`ALTER TABLE` 先 `PRAGMA table_info` 探测）
- `song_key` 统一为 `(来源标识, source_ref)` 复合键；收藏状态只认 `play_meta.is_favorite`（旧 `idx_songs.is_favorite` 仅一次性回填）
- 凭据加密：WebDAV/SMB 密码、SFTP 密钥经 `flutter_secure_storage` 存放，SQLite 只存引用键
- 无 `created_at/updated_at` 统一约定；时间列按需命名（`last_scan_at` / `cached_at` / `updated_at`）
- 写必须走写隔离，不要在主 isolate 直接 `db.execute` 写语句（OHOS 仅当写隔离启动失败/超时，`DbWriter` 才回退内联兜底；见「[鸿蒙适配](#鸿蒙适配)」与 `db_writer.dart`）

---

## API 设计

统一约定：

- 前缀 `/api/v1`（下文各表省略前缀）；响应包 `{ "code": 0, "message": "ok", "data": ... }`。
- **认证**：除 `/health`、`/auth/pair`、`/auth/refresh`（匿名）外全部要求 `Authorization: Bearer <access_token>`；无效 / 吊销返回 `code=40101`；**access 过期返回 `HTTP 401` + 响应头 `X-Token-Expired: true`**（客户端懒刷新）。
- 设备识别头 `X-Client-Id` 必带（与 `devices.client_id` 对应）。
- 分页 `page`（1 起）、`size`（默认 50，≤500）；响应含 `total`。

### 认证与设备

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/health` | 免认证存活检查 |
| POST | `/auth/pair` | `{pairing_token, device_name, platform}` → `{client_id, access_token, refresh_token, expires_in=86400, refresh_expires_in=2592000}`；主令牌错误 `code=40100` |
| POST | `/auth/refresh` | 匿名白名单；`{refresh_token}` → 轮换式换发；无效 / 过期 `code=40102` |
| POST | `/auth/unpair` | 自我注销（吊销当前设备） |
| GET | `/meta/server` | 版本、ffmpeg 可用性、转码并发水位、设备数、事件 cursor |

### 无状态转码代理

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/transcode/stream?origin=&bitrate=&loudnorm=` | 回源拉流 → ffmpeg 管道转 MP3 CBR（192/256/320，默认 192）流式回客户端；`loudnorm=off\|8\|10\|14\|16\|23`。鉴权透传：http(s) 源 `X-Origin-Auth: Basic`、SFTP 源 `X-Origin-Ssh: base64url(JSON{u,p?,k?,pp?,hk})`、SMB 源 `X-Origin-Smb: base64url(JSON{u?,p?})`。强校验 origin 落在未删除**同类**源地址之下 + 黑名单主机拒绝。并发只 `TRANSCODE_MAX_CONCURRENCY`（默认 2），超限 429 + `Retry-After`（客户端回落直连）；无 ffmpeg 503；整曲转码不支持 Range |

### 状态同步

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/sync/pull?since_cursor=` | 增量拉取（歌单 + 权重 + 断点快照），返回新 cursor；`since=0` 为启动全量校准；超 2000 事件分页（`has_more`）；回包带 `breakpoint_protocol: 2` + `server_epoch` |
| POST | `/sync/push` | 批量上推事件流水；幂等按 `event_uuid` 去重；LWW 判输回 correction 快照；v2 另回按 `playlist_uuid` 键控的 `breakpoints` 权威 head+history 快照与 `breakpoint_protocol/server_epoch` |
| CRUD | `/playlists` 系列（含 `{id}/items` 增删改） | 直接 REST 变更同样走事件管线（服务端代写事件） |
| PUT | `/playstates/{playlistId}` | `{source_id, source_ref, position_ms}`（可选 `deep_list`）；行级 LWW，判输回服务端快照 |
| GET | `/playstates/latest` | 全局最新断点快照（启动 / 回前台快路径，1 RTT；无行 / 歌单缺失或已删 / 不可同步时 `data=null`）；回包带 `breakpoint_protocol: 2` + `server_epoch`，排序按 `head_updated_at` |

### 管理

| 方法 | 路径 | 说明 |
|------|------|------|
| GET | `/admin/pairing-token` | 主配对令牌明文（`设置→服务端→配对服务器` 展示用；密钥源自 env 镜像） |
| GET | `/admin/config` | 服务端缓存建议值 `{cache_max_bytes, cache_song_limit}`（取值自 settings 表） |
| GET | `/admin/devices` · PUT/DELETE `/admin/devices/{id}` | 设备列表 / 改名 / 吊销 |
| PUT | `/admin/settings` | 管理端改缓存建议值（仅两键；`pairing_token` 为 env 只读拒绝写入） |

> 服务端**不提供曲库索引**：歌曲由 App 在各播放源处扫描、直接从源播放；后端仅提供认证 / 配对、状态同步与无状态转码代理。上传 / 删除走客户端 WebDAV/本地/SFTP/SMB 直写，不经服务端。

---

## 后端开发

### 三种运行方式对比

| 方式 | 改代码后做什么 | 反馈速度 | 适用场景 |
|------|--------------|---------|---------|
| A. 容器 dev 模式 | 容器内执行一条编译命令（见下） | ⚡ 秒级 | **推荐日常**，环境隔离且免维护 |
| B. 本地直跑 | 保存即自动重启（devtools 监听 classpath） | ⚡ 秒级 | 不想用 Docker / 深入调试 JVM |
| C. 生产镜像 | `docker compose up -d --build` | 🐢 1~3 分钟 | 发布前最终验证 |

### 方式 A：Dev 容器（推荐日常开发，默认用这个）

```bash
# 启动（profile: dev，端口 18089）
docker compose --env-file .env up -d backend-dev
docker compose --env-file .env logs -f backend-dev   # 看日志
docker compose --env-file .env stop backend-dev      # 停止

# 改完 Java 代码后触发重编译+热重启（devtools 只监听编译产物 target/classes）
docker compose --env-file .env exec backend-dev \
    mvn -f /home/ubuntu/app/pom.xml -B -o -q compile
# 若容器内识别不了挂载的 ~/.m2，可显式指定本地仓库（常见于此前的离线构建环境）：
docker compose exec backend-dev \
    mvn -q -Dmaven.repo.local=/home/ubuntu/.m2/repository -o compile
```

原理：容器里跑 `mvn spring-boot:run`，`backend/src` 与 `~/.m2` 直接挂载进容器
（UID 1000 一致，读写权限无障碍）。**改完代码不需要重新 build 镜像**；只有换 JDK/Maven 版本或新增依赖才需要
`docker compose --env-file .env build backend-dev` 重建。

### 方式 B：本地直跑

```bash
# 1. 导出数据库连接环境变量（值与 .env 一致）
export DB_HOST=192.168.x.x DB_PORT=3306 DB_NAME=selfmusic \
       DB_USERNAME=<数据库用户名> DB_PASSWORD='<密码>'

# 2. 启动（devtools 已启用热重载，改 Java 代码后自动重启）
mvn spring-boot:run -f backend/pom.xml
```

### 方式 C：生产镜像（验证用）

```bash
docker compose up -d --build
docker compose logs -f backend     # 看日志
docker compose restart backend     # 重启
docker compose down                # 停止并移除
```

### 端口与前端联调

三种运行方式对应的宿主机端口（dev 18089 / 生产 18088 / 本地直跑 8080）汇总见 [README.md「服务与端口」](README.md#服务与端口)。
前端联调时用 `--dart-define=API_BASE_URL` 指向对应端口，见「[API 地址配置](#api-地址配置)」。

### 常用 Maven 命令

```bash
mvn compile -f backend/pom.xml                   # 仅编译
mvn test -f backend/pom.xml                      # 跑测试
mvn clean package -f backend/pom.xml             # 打包 → target/selfmusic-backend.jar
mvn dependency:go-offline -f backend/pom.xml     # 预拉全部依赖
```

### 新增一个接口的标准流程

1. 在 `domain/entity/` 建 JPA 实体（对应 Flyway 迁移中已存在的表；**手写 getter/setter**，equals/hashCode 基于 id）
2. 在 `domain/repository/` 建接口继承 `JpaRepository`
3. 在 `service/` 写业务逻辑
4. 在对应功能包（`auth/`、`sync/`、`playlist/`…）暴露 REST 接口，路径以 `/api/v1/` 开头
5. 写测试到 `src/test/java`

### 后端模块与选型

包结构（`com.selfmusic.backend`，现状以代码为准）：

```
auth/        AuthController(pair/refresh/unpair) + DeviceAdminController + SecurityConfig + TokenFilter
admin/       AdminSettingsController（pairing-token / config / settings / devices）
controller/  HealthController
common/      ApiResponse, BizException, GlobalExceptionHandler
config/      FirstBootInitializer(PAIRING_TOKEN 镜像), WebConfig(CORS)
domain/      JPA 实体（Playlist/PlaylistItem/PlayState/SongState/Device/SyncEvent/SyncSource/Setting）+ Repository + service
playlist/    PlaylistController（歌单 CRUD + 条目增删改）
sync/        SyncController(pull/push) + SyncService(幂等去重/LWW/correction) + PushEvent + SyncEventTypes
transcode/   TranscodeService（并发门控 + ffmpeg 探测）+ TranscodeController + ssh/（sshj SFTP 回源）+ smb/（smbj SMB 回源）
meta/        MetaController（GET /meta/server）
```

技术选型：

| 用途 | 选型 |
|------|------|
| Web 框架 | `spring-boot-starter-web` + `data-jpa` + `security` + `validation`（Java 21 / Spring Boot 3.4） |
| 数据库驱动 | `mysql-connector-j`（MySQL 8）；Flyway 启动迁移 + `ddl-auto: validate` |
| Token 哈希 | JDK `MessageDigest` SHA-256（不引额外依赖） |
| SSH 回源 | `com.hierynomus:sshj`（0.41.x，Apache 2.0；转码代理的 SFTP 回源取流） |
| SMB 回源 | `com.hierynomus:smbj`（0.13.0，Apache 2.0；转码代理的 SMB 回源取流） |
| ffmpeg | 容器内**二进制**（apt 装入镜像，非 Java 库） |

> 说明：`jaudiotagger` 曾出现于早期选型记录，但**后端并未引入、也无任何音频标签代码**——音频元数据标签全部在 Flutter 客户端用 Dart 实现（见「[客户端扫描与元数据](#客户端扫描与元数据实现要点)」），服务端既没有曲库也没有流媒体（阶段 6 起仅有无状态转码代理）；**不用 Lombok**（全量手写 getter/setter/Logger，规避新版 Java 语言服务器注释处理器不兼容）。

Docker 镜像：prod 基座 `eclipse-temurin:21-jre`（复用基镜像自带 `ubuntu` 用户，暴露 8080，含 ffmpeg）；dev 基座 `maven:3.9-eclipse-temurin-21`（含 ffmpeg）。环境变量实际读取：`DB_HOST/DB_PORT/DB_NAME/DB_USERNAME/DB_PASSWORD`、`PAIRING_TOKEN`、`CACHE_MAX_MIB`、`CACHE_SONG_LIMIT`、`TRANSCODE_MAX_CONCURRENCY`（见「[配置说明](#配置说明)」）。

---

## 前端开发

### 版本管理（FVM，可选）

仓库当前**未启用 FVM**，直接用系统 `flutter` 命令即可。若需锁定 Flutter 版本（团队协作防版本漂移）：

```bash
cd frontend && fvm use 3.x.x   # 生成 .fvmrc 并提交入库
# 之后所有 flutter 命令改为 fvm flutter ...（如 fvm flutter run -d linux）
# IDE：VS Code 执行 "FVM: Change SDK"，或把 .fvm/flutter_sdk 加入 dart.sdkPath
```

`.fvm/` 不入库（`.gitignore` 已覆盖），`.fvmrc` 必须入库。

### 快速启动

仓库根目录提供两个快捷脚本（推荐直接使用）：

```bash
bash run-linux.sh      # Linux 桌面：等价于 cd frontend && flutter run -d linux
bash run-android.sh    # Android：flutter run -d <安卓设备id> --dart-define=API_BASE_URL=<后端地址>
```

> `flutter run` 必须用 `-d` 显式指定目标设备：如果同时连着安卓设备又不指定，flutter 会优先选安卓，而不会弹出 Linux 窗口。

### 常用命令

```bash
cd frontend
flutter pub get                 # 安装依赖
flutter run -d linux            # Linux 桌面
flutter run -d <设备id>         # Android 真机/模拟器（flutter devices 查看设备 id）
flutter analyze                 # 静态检查
flutter test                    # 单元测试
flutter build linux --release   # Linux 出包
flutter build apk --release     # Android 出包（壳工程已就绪）
flutter build windows --release # Windows 出包（需 Windows 环境，见"多平台构建矩阵"）
flutter build hap --debug     # 鸿蒙出包（Windows + ohos 分支；release 出包用根目录 build-ohos.ps1）
```

### API 地址配置

`lib/services/api_client.dart` 通过编译期常量 `String.fromEnvironment('API_BASE_URL')` 注入后端地址，**默认值为空字符串**（不指定；实际地址取自配对设备 / `ServerSettings`）。联调时可覆盖：

```bash
# 连接本地直跑的后端（8080）
flutter run --dart-define=API_BASE_URL=http://<宿主机IP>:8080

# 连接 Dev 容器后端（当前局域网后端，18089）
flutter run --dart-define=API_BASE_URL=http://<宿主机IP>:18089

# 连接生产镜像后端（18088）
flutter run --dart-define=API_BASE_URL=http://<宿主机IP>:18088

# Android 真机不能用 localhost，必须写宿主机局域网 IP；run-android.sh 已预置该参数
```

### 技术选型（pubspec.yaml 已引入）

| 包 | 用途 |
|----|------|
| dio | HTTP 客户端（含懒刷新拦截器） |
| provider | 状态管理 |
| just_audio | 音频播放抽象 |
| just_audio_media_kit（vendored，+ media_kit_libs_linux / media_kit_libs_windows_audio） | 桌面音频后端（Linux/Windows 统一 libmpv，库随包分发，`main()` 中 `ensureInitialized()` 注册）；本地 fork 暴露内部 mpv Player 供均衡器 `af` 链使用，见 `third_party/just_audio_media_kit/PATCHES.md` |
| cached_network_image | 图片缓存 |
| flutter_secure_storage | 敏感数据安全存储（token、主题偏好、WebDAV 密码、配对密钥；统一经 `SecretStore` 收口，见 `frontend/lib/services/secret_store.dart`） |
| audio_service（vendored fork，`third_party/audio_service`） | Android 通知栏 / 后台播放（前台服务 + 媒体通知，`SelfMusicAudioHandler` 5 键自定义处理器）；鸿蒙不适用——走自建 AVSession 桥（见「鸿蒙适配」） |
| crypto | 缓存 key / 封面等哈希去重 |
| sqlite3 / sqlite3_flutter_libs | 客户端本地库（`data/local/`）：源索引 idx_songs + cache + play_meta + playlists + app_settings + song_lyrics + play_state；读写分离与事务合批见「[客户端本地数据层](#客户端本地数据层sqlite-写隔离)」 |
| xml | WebDAV PROPFIND XML 解析 |
| file_selector | 备份导入导出、本地文件夹源「选择目录」（ohos 端选目录走自建平台桥，见「鸿蒙适配」） |
| permission_handler | Android 本地文件夹源运行时权限（READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE） |

### 平台收口层（`lib/platform/`）

跨平台代码里**不要在业务层写 `Platform.isAndroid` / `Platform.isLinux` 之类判断**：鸿蒙走三方 Flutter 分支，官方 target 的 `Platform` 行为与原生插件实现都可能不一致。平台差异统一收敛到 `lib/platform/<target>/`，启动时由该平台的 bootstrap 装配，新增平台只补一个目录、不动上层。

现状（`lib/platform/harmonyos/`）：

- `ohos_bootstrap.dart`：`setupOhos()` 在 `main()` 里 `runApp` 前调用，装配六件事——sqlite3 `open.overrideForAll`（顶层函数，isolate 安全）、`FlutterSecureStoragePlatform` 桩、`JustAudioPlatform` AVPlayer 适配、path_provider 重试包装、HTTPS 根证书注入、`WakelockPlusPlatformInterface` 常亮平台实现（2026-10）
- `just_audio_avplayer.dart` / `secure_storage_ohos.dart`：音频后端（系统 AVPlayer 桥）与安全存储的 ohos 实现
- `ohos_platform_bridge.dart` / `wakelock_plus_ohos.dart`（2026-10）：系统能力平台桥 Dart 封装（常亮/本地文件/蓝牙，见「鸿蒙适配·系统能力平台桥」）
- 平台判定统一用 `Platform.operatingSystem == 'ohos'`（stable 工具链没有 `Platform.isOhos` getter，见「[鸿蒙适配](#鸿蒙适配)」）
- 其余平台差异目前靠条件导入式的一层封装（`just_audio` 默认 Android 走 ExoPlayer、桌面走 media_kit），尚**未**抽成统一 `capabilities` 接口——新增平台能力时优先考虑在 `lib/platform/` 补齐
- 少数确实需要平台判断的调用点（音频焦点、通知栏）以 `Platform.isAndroid` 门控，并在注释里说明「ohos 走降级路径」；常亮 / 本地文件夹源 / 蓝牙设备查询已由平台桥支持 ohos（2026-10），对应调用点改为 `isOhos` 分支

### 客户端播放源（Source 抽象层）

`MusicSource` 抽象（`data/sources/music_source.dart`）是双模式的基石，四个实现：`LocalDirectSource` / `WebdavDirectSource` / `SmbDirectSource`（双后端）/ `SftpDirectSource`。

```dart
abstract class MusicSource {
  String get key;                          // 'smb:nas1'/'webdav:xx'/'sftp:xx'/'local:xx'
  String get name;
  SourceKind get kind;                     // local / webdav / smb / sftp
  bool get supportsDirect => false;        // 默认不支持直连（scan/open 抛错）
  Future<ScanSummary> scan({ScanOptions options, ScanToken? token, void Function(ScanProgress)? onProgress});
  Future<OpenedStream> open(Song song, {IntRange? range});
  DirectStream? directStream(Song song);   // 可直交播放器的原生 URL（Range/seek 更稳）
  Future<void> probe(Song song);
  Future<void> cacheSong(Song song, {bool Function()? shouldAbort});
  Future<String?> cachedFilePath(Song song);
  Future<List<Song>> search({String? query, int page, int size});
  String displayPath(Song song);
  Future<void> close();
}
```

- 播放器只认 `MusicSource`；**直连播放优先级**：用户缓存文件（`cache.kind=user`，不受转码设置影响）→ 转码开时当前设置一致的变体缓存 → 转码流 → 预载原文件（`preload_origin`）兜底 → `directStream()`（原生 URL，WebDAV 用）→ 自建 `StreamAudioSource`（`open()`）回落。
- **SFTP**：无 `directStream`（just_audio 播不了 `sftp://`），恒走 `open()` 字节流（协议原生支持偏移读，seek 精度优于 HTTP Range）；选型 `dartssh2`（纯 Dart，三端同代码）。密码 / 私钥 / 主机密钥 TOFU 见 `ssh_known_hosts`。**直写**（与 WebDAV 同口径：根目录、静默覆盖）：上传经 `open(write|create|truncate)` + `SftpFile.write` 流式分块（16KB/64 并发），删文件经 `remove`，建目录经 `mkdir`（已存在先 stat 确认是目录才视为成功）；写走同一 `_withSftp`（共享连接、掉线重建、TOFU 门槛不变），`permissionDenied` 转中文权限文案（鉴权已过，不报账密错误）。
- **SMB**：**全平台统一走 `dart_smb2`**（FFI libsmb2，SMB 2.0.2→3.1.1，含 SMB3 加密；主 isolate 用异步 `Smb2Pool`、扫描 isolate 用同步 `Smb2Client`）。Android/Windows/Linux/iOS/macOS 由包的 ffiPlugin 打包预编译库；ohos 由 vendored `third_party/dart_smb2` + 手工打包的 `ohos/entry/libs/arm64-v8a/libsmb2.so`（DevEco NDK 交叉编译，见 `third_party/dart_smb2/PATCHES.md`）加载，行为与安卓同栈。`smb_connect` 纯 Dart 后端保留在代码中仅作历史/调试备用（`useSmbConnect` 恒为 false），主流程不再使用。范围读按 256KB 分块（stateless，取消即停）；弹窗只填一个「路径」（首个 `/` 前为共享名，其余为共享内目录，落库仍拆 `share`/`path` 两键）；扫描枚举的 `ref` 恒为源内相对（walk 内按 `rootPath` 折前缀，播放/展示由 `smbRemotePath(rootPath, ref)` 拼回，不出现双重前缀）；凭据存 `SecretStore`（`smb_pwd:<sourceKey>`）；**直写**（与 WebDAV 同口径）：经 `truncate(0)` + `writeFileRange` 256KB 分块顺序写（覆盖）、`deleteFile`、`mkdir`（已存在先列目录确认才视为成功）。`accessDenied` 在写链路转"无写入权限"中文 StateError（鉴权已过）。代理 origin 为 `smb://host/share/逐段编码路径`（无 userinfo），凭据走 `X-Origin-Smb` 信封。**方言/加密**：libsmb2 默认广告 SMB3 加密能力，并在 tree connect 发现共享要求加密时自动启用（`server smb encrypt = required` 可连）。
- WebDAV `ref` 存**解码后**路径，请求时按路径段重新编码；扫描头部元数据解析对大内嵌封面做边界保护（超采样即停止解析，不抛 `RangeError`）。
- 源列表 = `sources` 表里启用的源；配置后端地址后解锁多设备同步（与曲库无关）。

**离线缓存**：远端源（WebDAV/SMB/SFTP）缓存走整曲下载，`cacheSong` 按 1MiB 攒批落临时文件后原子换入（见「[客户端同步与缓存批处理](#客户端同步与缓存批处理)」）；本地源文件本体即缓存，`cachedFilePath` 直接返回绝对路径走 `setFilePath`。

**缓存与预载分离**：`cache` 表新增 `source_key/song_ref/kind/variant_of`。`kind=user` 才是“已缓存”（手动/收藏自动缓存，播放无条件优先、计入歌曲上限）；`preload_origin` 是转码关闭时预载的原文件，`preload_variant` 是转码预载产物，二者都不算已缓存、不占歌曲上限（只占字节上限）。手动/自动缓存成功后会清掉该歌全部变体。淘汰按歌曲分组：中位进度升序（样本 <3 条/无样本最弱）→ 播放次数升序 → LRU；收藏歌曲豁免；组内先删变体再删原文件。预载变体失败不回退原文件，只对 429/502/网络类瞬态错误做有界延迟重试（429 遵从 `Retry-After`）。

### 客户端本地数据层（SQLite 写隔离）

> 机制背景（为什么有这层）见「[总体架构](#总体架构)」与「[客户端播放源](#客户端播放源source-抽象层)」；本节是**写代码时必守的规则**。

结构（`lib/data/local/`）：

| 文件 | 职责 |
|------|------|
| `schema.dart` | 建表 + 迁移的**唯一事实源**（`applySchema(db)` 幂等），主读连接与写连接各跑一遍 |
| `db_writer.dart` | `DbWriter`：后台 isolate 独占第二个连接，串行执行并自动合批 |
| `local_index.dart` | 主 isolate 侧门面：读用主连接，所有写转发给 `DbWriter` |

**为什么这样切**：逐行 autocommit 写几万条索引会打满磁盘 I/O，Windows 上表现为启动卡死。改为写全部离开主 isolate、队列内多条语句合并成单个事务后，「几万次小块写」收敛为少量大块顺序写。

核心约定：

- **主连接只读**：`_db` 仅用于 SELECT 与 `applySchema`；`LocalIndex` 的所有写方法都走 `_writer`（`exec` / `execUpdated` / `execInsert` / `op` / `opBatch`）
- **事务合批**：写隔离内队列满 **256 条**或距上次 flush **2ms** 即提交一次（`BEGIN … COMMIT` 裹住整批）；所有调用按到达顺序 **FIFO** 执行
- **WAL + 降 fsync**：`journal_mode=WAL`、`synchronous=NORMAL`（WAL 下仅 checkpoint fsync）、`busy_timeout=30000`、`wal_autocheckpoint=1000`
- **Future 语义**：需要回执的写返回 `Future`，**落库后才完成**（主连接经 WAL 立即读到已提交数据）；只有可丢失的旁路写用 `execFire`（如 `app_settings` 内存缓存回写）
- **复合逻辑用 `op`**：读改写必须在写连接内原子完成，不能「主连接读 → 主线程算 → 写连接写」。已封装的 op：`applyWeightEvent` / `setFavorite` / `upsertPlayMeta` / `upsertSongs` / `clearMissing` / `renameSource` / `deleteSource` / `movePlaylistItem` / `updateSongUserMeta` / `apply*Snapshot` / `migrateMetaRefs` 等（完整清单见 `db_writer.dart` 的 `_runOp`）
- **播放统计用挂钟 + 写连接累加**：`play_meta.play_sec` 由 `player_provider` 在「暂停 / 切歌 / 退出 / 位置事件」处结算（`DateTime.now` 差值，非位置采样，故后台节流不影响），经 `DbWriter.addPlaySec` 在写连接内累加；`shutdown()` 需先 flush 再关写连接。**不要为它开周期定时器**——`fake_async` 下会留下 pending timer 导致测试失败
- **落库时机要显式**：`LocalIndex.flushWrites()` 在**导出 / 导入备份**（`backup_service.dart`）与**退出**（`player_provider` 的 `shutdown()`）前必须调用；进程被杀时排队中的写会丢，因此只允许把它用在可重算的派生数据上
- **断点（`play_state`）不能高频整写**：该行含整个队列 JSON（1207 首实测约 240KB）。真机取证（2026-10-15，当时 `ohos` 写层为内联写，序列化与写库都在 UI 线程）：每 2s 一次「重编码队列 + 重写整行」= 序列化 28~61ms + 写库 9~24ms，表现为周期性掉帧。现口径：**队列 JSON 按 `Object.hashAll(_queue)` 做缓存**（`Song` 字段全 `final`，身份哈希即内容指纹；队列元素替换/增删/重排都会失效），**周期落库放宽到 `_stateSaveInterval`=10s**，切歌（`_lastSavedSongKey` 变化）/暂停/退后台/退出仍强制落库。写层现已默认后台隔离，但队列序列化仍在 UI，故保留 10s 周期；改动落库频率前先确认队列规模 × 频率的乘积
- **数据迁移在写隔离 `init` 里跑**：历史 `play_meta` 的 `ENCODE(ref)` 脏值由 `migrateMetaRefs` 在开连接时修一次（幂等）
- **平台差异**：写隔离是独立 isolate，拿不到主 isolate 的 `open.overrideFor`（测试正是靠它注入），因此 `openIsolateDatabase` 自己解析 `libsqlite3`——Linux 依次试 `libsqlite3.so` / `libsqlite3.so.0`（发行版常只有后者）；OHOS 在子 isolate 内重新注入随包 `libsqlite3.so`（sqlite3 2.9.4 的 `OperatingSystem` 枚举没有 ohos）。OHOS 写隔离启动有 **8s** 上限（spawn + boot + init），超时或报错会杀掉半启动 isolate 并回退 `_InlineDbWriter`（同 isolate 内联、200 行/事务分片、片间让出），避免启动白屏

测试约定：写是异步的，断言落库结果前先 `await index.flushWrites()`；组件测试里用 `settleWriter(tester)` 辅助冲刷写队列（`test/playlists_view_test.dart` / `test/song_tile_test.dart`），不要靠固定 `Future.delayed` 猜时间。

### 客户端扫描与元数据（实现要点）

> 扫描方式与指纹语义见「[数据模型](#数据模型)」客户端表与「[客户端扫描与元数据](#客户端扫描与元数据实现要点)」；本节只记**写代码时必守的隔离与数据规则**。

- 扫描在独立 Isolate 运行（`data/sources/scan_worker.dart` 的 `runScan`）：入口函数只收可序列化的原始参数
  （HTTP 客户端 / DB 句柄 / `LocalIndex` 等**不得跨 isolate 发送**）；指纹表由主 isolate 在 `scan()` 前查好以 `Map<String,Object?>` 传入
- 增量指纹键 `(ref, size, mtime, etag)`：WebDAV 从 PROPFIND 的 `getlastmodified`/`getetag`/`getcontentlength` 解析；
  `scanFingerprint` 主 isolate 查询一次传入，避免 worker 碰 DB
- 快速只建索引：worker 内**不打开任何音频文件、不发任何 Range 请求**，只用枚举 + stat 的 ref/size/mtime/etag 落库。音频解析与封面提取只在播放时补读/后台补读链路发生
- WebDAV 列目录并发（`_mapConcurrent` 并发 6）
- 结果回主 isolate 后统一 `upsertSongs`（**整批单事务**，走 `op('upsertSongs', …)`；同步快照批量用 `opBatch('applySongSnapshots', …)`）+ `persistCover` + `markMissingExcept` + `clearMissing`；
  `LocalIndex` 只允许主 isolate 访问，写全部转发写隔离
- `upsertSongs` 的覆盖保护：用户手改过（`user_edited=1`）的标题/歌手/专辑不被扫描覆盖；补读解析出的空值不覆盖已存值；只有本次解析出时长才标 `meta_read`
- 自动扫描：本地 `Directory.watch(recursive)` 变化去抖 2s 触发 `scanSource(key)`；周期定时器按 `scan_auto_interval_min` 轮询全部直连源；`_inFlightScan` 全局互斥防重复扫描
- 播放时懒补全：`PlayerProvider._enrichLazily` 播放后按结构定位精确 Range 读取（`readAudioMeta`），`enrichSong` 回填，失败静默
- 测试：`test/webdav_scan_test.dart` 用真 `HttpServer`（PROPFIND/GET/Range + 可变 etag）验证跨 isolate 扫描、增量跳过与 etag 变化仅重探目标文件；`test/audio_metadata_test.dart` 覆盖头部越界与大封面边界；
  另有 `duration_format_test`（时长 mm:ss/h:mm:ss）、`lrc_parser_test`（歌词解析）、`song_title_format_test`（标题格式）、`play_reconcile_test`（播放前最新行纠正）、`top_bar_search_test`（搜索追焦与区域提示语）、`source_browse_search_test`（源内复用顶栏搜索）、`view_mode_settings_test`（集合页视图持久化）、`playlist_membership_test`（歌单归属/切换）与 `playlists_view_test` 等
- 历史问题：mp3 enc==3 / flac VORBIS_COMMENT 曾用 `String.fromCharCodes` 逐字节解码导致 CJK 乱码——已改 UTF-8 解码；修复后需对已有源重扫一次覆写旧行（`upsert` 无条件覆盖 title/artist/album，无需删库）

**读头部的多段策略（`data/local/audio_metadata.dart`）**

- **结构化阶梯读（`readAudioMeta`，播放补读与后台补读共用同一函数）**：首段采样（256KB）→ `coverReadHint` 按**文件自己声明的长度**（mp3 的 ID3v2 synchsafe 总长 / flac 元数据块的 24 位块长）给出「读到封面块尾」所需字节数，跳过去再解析。不够就继续阶梯，直到 `coverReadHint` 返回 null（结构上到头）或触到 `kMetaRegionCapBytes` = 16MB。歌词（USLT / LYRICS）与长文本帧同在整段标签内，随阶梯一并补全
- **两条补读驱动**：(1) **结构跳**——按声明长度精确落点；(2) **几何放大（×4）**——结构上算不出落点时。典型是 FLAC 的 `PICTURE` 排在 `VORBIS_COMMENT` 之前：读完封面块标题还在更后面；ogg/opus 的段表在读完段表之后才知道 payload 落在哪，采样截断时同样只能放大
- **`coverReadHint` 返回 null = 结构上到头**，此时不再放大：mp3 标签读完 / flac 块列表走到 last 块 / ogg comment 包完整 / 无结构可循的格式（m4a 的 moov 在文件尾，走尾部阶梯，不在头部放大到上限）
- **绝不整读**：没有「采样不足就从 0 读到 fileSize」的退路（旧实现有 `fullRead`，在后台逐首补读链路上为拿几个标签把几十上百 MB 整首下下来，且命中的恰恰是大文件）。单次读取上限 `kMetaRegionCapBytes` = 16MB，是**声明值**的合理性边界，不是文件大小上限
- **尾部补读 `tailReadHint`**：moov-at-end 的 m4a（按 256KB→1MB→4MB 逐级放大，上限同上）、ogg/opus 时长（取末页 granule）、无 ID3v2 的 mp3 ID3v1（取尾 128B）、**wav/aiff 的尾随 `id3 ` 块**（见下）
- **wav / aiff / aifc（RIFF/FORM 容器）**：这两种容器没有官方标签规范，工具把 ID3v2 塞进一个 `id3 ` 块（RIFF/FORM 块 id 是 4 字节 ASCII，wav 块长小端、FORM 块长大端），位置也不固定（ffmpeg `-write_id3v2 1` 写在音频块**之后**）。`tailReadHint` 按音频块（`data`/`SSND`）**声明的长度**跳过音频，算出后面元数据区的长度并一次读准，不碰音频数据；尾读窗口解析 `id3 `（复用 mp3 那套 ID3v2 帧/APIC 解析）与 `LIST INFO`。老设备常把 RIFF 总长或 `data` 声明写错，块列表对不上时兜底在窗口内扫 `id3 ` 标记并按 ID3v2 头自己声明的长度严格校验，避免把音频数据里巧合的字节误当标签。aiff 另解析 `COMM` 的采样帧数与 80 位扩展浮点采样率算时长，`NAME`/`AUTH` 兜底标题/歌手
- **FLAC 前置 ID3v2（非标准写入的兼容，MusicPlayer2/TagLib 口径）**：部分老工具会在 `fLaC` 前塞一整个 ID3v2 标签。读侧先按 ID3v2 头声明的长度跳到 `fLaC` 再走块列表；文本字段 **Xiph（VORBIS_COMMENT）优先、ID3 文本帧补缺**（TIT2/TPE1/TPE2/TALB/TCON/TYER·TDRC/TRCK）；歌词只在 FLAC **完全没有 Vorbis 条目**时取 USLT（TagLib 的 `properties()` 只取第一个非空标签）；封面仍只认 FLAC PICTURE 块，**不读 ID3 APIC**。写侧（`audio_tag_writer.dart`）统一输出标准 FLAC：丢弃前置 ID3v2 与尾部 ID3v1，丢弃前把 ID3 文本/USLT/APIC 迁移到 Vorbis comment / PICTURE（Xiph 已有键优先）。已标已读但 `artist` 为空的 flac 行由一次性迁移（`kFlacId3PrefixMetaV1Done`，设备本地标记）重置重读。
- **不误报**：音频块声明长度 ≥ 文件实际大小、声明溢出为负、或尾部没有别的块时 `tailReadHint` 返回 null（不做无用尾读）
- 扫描 `full` + 提取封面走 `readAudioMeta` 统一读序；旧版已标已读但无封面的 mp3/flac 行由一次性迁移（`kCoverReenrichV1Done`，设备本地标记）重置为未读，交给后台补读重取
- **同目录回退**：仍无封面 → 「同名图片（`.png/.jpg/.jpeg/.webp`）→ `cover.*`/`folder.*`/`front.*`/`album.*`」顺序取同目录图片（会话级缓存，含否定结果），经校验后落盘；同名 `.lrc` 歌词回退同在一条路径
- **图片必须完整才落盘**：`isImageBytes` 除图片签名外还要求字节数不少于资源的**真实总长度**。范围读取时 `OpenedStream.contentLength` 只是「这次拿到多少」，新增的 `OpenedStream.totalLength` 才是总长度（本地源给文件大小，WebDAV 从 `Content-Range: bytes 0-…/total` 尾部取，服务端不回该头时为 null）。否则一张比读取上限大的图被截断后只凭前 12 字节签名就能通过，Android `ImageDecoder` 解码失败 → 界面上没有封面，而这行已标「已读」永不重试。读满上限或流短于总长同样判为「读不全」
- **补读的并发与优先级（`DirectTaskQueue`）**：当前曲补读、下一首预载、全库后台补读**串行**执行，一次只跑一个，跑之前重挑最高优先级：当前曲音频（阻塞装载）→ 当前曲元数据/封面 → 下一首音频（`preloadNext` 开启时）→ 下一首元数据/封面 → 全库后台补读。串行的理由是 `open`/`cacheSong`/`probe` 各建各的 HttpClient，并发就是同时开 N 条连接抢同一条链路。三个易错点：
  - 队列开跑前先 `await` 一轮事件循环：切歌那一刻四级任务是同一个同步块里陆续提交的，不让这一轮落地就先到的全库任务抢到了当前曲前面
  - 换歌/插队/删曲时作废未开始的「下一首」任务；在途的整曲下载用 `cacheSong(shouldAbort:)` + 自增票据号放弃（半截 `.tmp-` 由 `cacheSong` 自己的 `finally` 清理）——队列不能中断正在跑的任务，而整曲几十 MB 能把当前曲的元数据堵到几分钟后
  - 全库补读每首一个任务、整批先排队再 `await tasks.idle()` 取下一批（保持游标语义），且**每批只通知一次** UI（一批 100 首逐首通知会让整库页重建 100 次）
- **编码规则**：mp3 ID3v2 按帧 encoding 选解码（enc==3 → UTF-8；enc==0 → 尝试 UTF-8 再回退 Latin-1）；flac/ogg VORBIS_COMMENT 按规范 UTF-8（失败回退 Latin-1）；m4a 文本原子 UTF-8；无内嵌标签时走文件名/同目录回退
- **时长探测**：mp3 估算法（文件大小÷码率）或解析 Xing/VBRI 头；flac 读 STREAMINFO

**元数据补读：分片让出 + 解析下沉原生（`spec/ohos-meta-enrich-native`，2026-10-11）**

- **根因（真机取证；2026-10-20 更正）**：后台补读的纯 Dart 标签解析/封面提取当时跑在根 isolate（`runOffThread` 有 OHOS 内联守卫，该守卫已于 2026-10-20 移除），以 ~1.4s 同步块反复独占主线程（探针 `phase=meta.enrich`）→ 系统看门狗 `THREAD_BLOCK_6S` 强杀。**不是引擎不能 spawn 子 isolate**——同期 `runScan` 已在 OHOS 用 `Isolate.spawn` 跑 WebDAV/SFTP/SMB 扫描，2026-10 SFTP 长活 worker 再次验证。
- **分片让出（Dart，FR-001）**：`direct_source_manager.dart` 的 `_pumpUnread` 把整批「游标推进 + 入队」改为 `utils/chunked_scheduler.dart` 的 `runChunked` 驱动（每 `kEnrichSubmitChunk=16` 首让出事件循环一次），保证单次同步块 ≪ 50ms；游标逐首前进、`await tasks.idle()` 维持批次语义不变。
- **解析下沉原生（ohos，FR-002/003）**：新增通道方法 `extractAudioMeta`（`selfmusic/platform` 第 11 个）。`meta_enrich.dart` 的 ohos 分支（`isOhos` 门控）取 `cachedFilePath` 的沙箱真路径 → `OhosPlatformBridge.extractAudioMeta(path, coverPath:)`。ArkTS 侧 `AudioMetaPipeline.ets`（**无 UI 依赖**纯管线：`media.createAVMetadataExtractor()` + `fdSrc`(fd) + `fetchMetadata()` + `fetchAlbumCover()` → `image.createImagePacker().packToFile(<coverPath>.tmp)` 后 `renameSync` 原子落盘，句柄全程自建自释）由 `AudioMetaTask.ets` 的 `@Concurrent` 入口在**任务池**执行；`PlatformBridge.ets` 的 handler 只做参数校验 + 有界并发（`META_MAX_INFLIGHT=2`，与缩略图生成并存不相互挤占，FR-007）+ 结果回报，任何失败 `ok=false`（**绝不向 Dart 抛错**）。
- **封面路径口径保持**：封面目标路径由 Dart 用 `LocalIndex.coverPathFor`（**沿用 `persistCover` 的 `covers/<md5(ref)>.jpg`**）算出后作为 `coverPath` 传入，原生写盘并回传——Dart 不再持有/重解析封面字节，产物路径与缩略图派生（`<md5>.thumb.jpg`）约定不变；原生无内嵌封面时仍走既有同目录图片回退（不劣化封面覆盖）。
- **失败语义与收敛（FR-004/006）**：原生 `ok=false` ⇒ **不标已读**，并由 `enrichSongMeta` 回退既有 Dart 路径（`_enrichViaDart`）——保字段覆盖与补读收敛；成功才 `enrichSong`（内含 `meta_read=1`）。缺失字段留空（`enrichSong` 的 `COALESCE(NULLIF(...))` 保持库中既有值）。**非 ohos 逐字节零回归**（`isOhos` 门控，Dart 读序原样抽出为 `_enrichViaDart`）。
- **残留风险（真机核对项）**：`AVMetadata` 当前不提供**音轨号/内嵌歌词**（留空不劣化，歌词为预留字段）；`AVMetadata.duration` 官方文档未标注单位，Dart 侧按**毫秒**换算为秒（`OhosAudioMetaResult.durationSec`，若真机核对为秒需改口径）；超大内嵌封面未在原生侧限制尺寸（`fetchAlbumCover` 全尺寸 PixelMap 在任务池线程处理，不占主线程）。

**主线程长同步块治理：补读 / 权重预热 / 歌手解析（`spec/ohos-mainthread-long-blocks`，2026-10-11）**

> 承接上节：真机探针（`utils/main_thread_probe.dart`，临时保留至验收）在**远程源**（sftp/webdav，无本地缓存 → 原生解析被绕过）曲库上又测出三处主线程长同步块：`meta.enrich` 单次最大 6.1s、`weight.warmMetaOf` ~1.5s、`artist._runBatch` 最大 2.5s。本节记**写代码时必守的切片让出规则**。

- **统一原则**：鸿蒙上 Dart 根 isolate 即应用主线程，**留在根 isolate 的**可切分纯 Dart 重活必须**片间 `await` 让出事件循环**（统一用 `utils/chunked_scheduler.dart` 的 `runChunked`/`runChunkedCancellable`，或公开的 `yieldToEventLoop()` 钩子），保证单次同步块 < 50ms；纯 Dart 重活**优先移到子 isolate**（`Isolate.run`/`Isolate.spawn`，OHOS 已由 `runScan` 与 SFTP worker 真机验证）。`runOffThread` 已于 2026-10-20 全平台走真实后台 isolate（OHOS 的 DB 读在子 isolate 内由 `openIsolateDatabase` 重新注入 sqlite3 override；应急回退 `--dart-define=OFF_THREAD_DIRECT=true`）；注意子 isolate **不继承**平台通道、插件单例、`open.overrideForAll`，需要这些能力的代码要么留在根 isolate，要么在子 isolate 内显式重建。

> **2026-10-20 更正**：早期文档中的「fork 引擎无子 isolate」是误判。`runScan`（`Isolate.spawn`）自 2026-09 起在 OHOS 用于 WebDAV/SFTP/SMB 扫描并通过 2026-09-30 PoC；2026-10 SFTP 长活 worker 再次验证。`runOffThread` 的 OHOS 内联守卫已于 2026-10-20 移除（全平台真实后台 isolate，DB 读在子 isolate 内注入 sqlite3 override）。`DbWriter` 写层也已切回写隔离：子 isolate 内由 `openIsolateDatabase` 注入 override，并加 8s 启动超时/内联兜底，不再是「待切回」。详见 `db_writer.dart` / `off_thread.dart` 头注释。
- **补读兜底路径切片（`meta_enrich.dart` 的 `_enrichViaDart`，P1）**：远程源无本地缓存时无法走原生，纯 Dart 读序（解析 → 封面处理 → 落盘/哈希 → 落库）各阶段之间 `await yieldToEventLoop()`；`readAudioMeta` 传 `yieldTo`，头部/尾部阶梯每轮之间让出；封面落盘改走 `LocalIndex.persistCoverChunked`（md5 哈希 + 写盘分片让出）。
- **解析器字节区间切片（`audio_metadata.dart`）**：大内嵌封面**不再整块复制**——mp3 APIC / flac PICTURE / m4a covr 一律用 `Uint8List.sublistView` 零拷贝视图（解析只校验前 12 字节签名）；ogg/flac 的 base64 内嵌封面（`METADATA_BLOCK_PICTURE`/`COVERART`）解析阶段只**登记**字符串（`AudioMeta.pendingCoverB64`），解码挪到 `readAudioMeta` 末尾分片进行（`_decodeBase64Chunked`，按 4 字符对齐切段、段间让出）；`parseAudioHead` 同步调用方（扫描/单测）仍在末尾一步到位解码，逐字节零回归。
- **原生路径判定修正（`meta_enrich.dart` + `MusicSource.localSandboxPath`，R-2）**：原生 `extractAudioMeta` 的可用性以「**是否存在可打开的本地沙箱真路径**」判定，**不得**再把原生绑死在「离线缓存登记」上——本地源本体即本地文件（旧判定用 `cachedFilePath==null` 对本地源误判为不可用）。`LocalDirectSource.localSandboxPath` 显式表达「原生可用性」；远端源默认委托 `cachedFilePath`（未缓存 = null → 走切片后的 Dart 兜底）。
- **权重预热限量分批（`song_weight_store.dart` 的 `warmMetaOf`，R-3）**：不再整表一次同步查 `play_meta`；按 `_warmBatch=300` 分批、批间 `yieldToEventLoop()`。方法改为 `Future<void>`（5 处 `onWarm: () => weight.warmMetaOf(...)` 仍以 `VoidCallback` 丢弃 Future，语义「最终填满缓存」不变）；单批异常静默（逐行 `metaOf` 兜底）。
- **歌手解析批次切片（`artist_resolver.dart`，R-4）**：`_runBatch` 项与项之间、`_resolveOne` 本地直查与网络/合流之间、`_expandMembers` 成员展开逐项之间 `await yieldToEventLoop()`；**重试/退避语义与请求数完全不变**（真实瓶颈仍是 MB 1 req/s 限流，切片只解决主线程占用）。
- **失败可观测**：三处失败语义不变——补读未识别容器不标已读、下一轮重试（`_enrichViaDart` 返回 false）；原生失败 `ok=false` 回退 Dart 并附 `error`；歌手解析失败 `debugPrint('[artist-resolve] …')` 后指数退避。切片过程**不得**吞掉失败原因（预热批异常静默是唯一的「静默」例外，因其有逐行兜底）。
- **零回归**：非 ohos 逐字节不变（`isOhos` 门控；`readAudioMeta` 的 `yieldTo` 默认 null → 同步路径一致）；Dart 既有单测保持通过（Windows 环境个别用例在**删临时目录**处因写隔离句柄未释放而报 `errno=32`，属既有环境问题，非本特性引入）。

**SFTP 直连解密的主线程治理（2026-10-11 真机取证，承接上节）**

> 上节切片后仍持续掉帧：冻结堆栈用同构建 `--split-debug-info` 符号化，定位到 **dartssh2 的纯 Dart AEAD 解密**（pointycastle `GCMBlockCipher._gHASHBlock`）在 UI isolate 上以微任务链连跑（`SSHTransport._consumeAeadPacket`）；微任务优先于渲染事件，主线程被连续占满。本节记 **SFTP 读取必守的限流纪律**。

- **根因**：`SftpFile.read` 默认 64 并发 × 16KB 扇出，会把整段 Range（补读可达 16MB）灌成一条解密链——实测单次同步块 9~11s（THREAD_BLOCK_6S 强杀），30~80MB 大封面 FLAC 单曲补读 28s。
- **请求限流（旧直连回退，`sftp_direct_source.open`）**：`chunkSize: 16KB, maxPendingRequests: 1`——同一时刻只有一个 16KB 请求在飞，解密与网络事件交替，单块同步块 ~10ms。**旧直连路径勿放开 maxPendingRequests**；worker 路径（默认）已把解密移出 UI isolate，不受此限。
- **补读让出节拍（仅旧直连回退，`meta_enrich._readRange`）**：`!SftpWorker.enabled` 且 SFTP 时每个解密块后 `await Future.delayed(8ms)`（前 32KB 不让，保证头部/标签快出）；整曲缓存（`SftpDirectSource.cacheSong`）同口径 6ms/块。worker 路径解密不在 UI isolate，无需节拍。
- **业务状态错误不重连（`sftp_direct_source._withSftp`）**：同目录图片回退会逐个 `open` 不存在的候选路径，服务端回 `SftpStatusCode.noSuchFile`——旧实现对所有异常 `close()`+重连，每个候选白付一次纯 Dart SSH 握手（~600ms 主线程 stall；无内嵌封面歌曲 11 个候选 → 5~7s 卡顿）。只有 `noConnection`/`connectionLost` 与未知异常才重建重试。
- **头部阶梯增量拼接（`audio_metadata.readAudioMeta`）**：阶梯每级只 `readRange(len, target-len)` 续读再拼到已读缓冲，不再 `readRange(0, target)` 从头重下——多级阶梯（2.1MB→11MB→16MB）少下近一倍字节，SFTP 上每字节都要主线程解密，收益直接。
- **验收口径（真机 120s 冷启动，SFTP 曲库）**：`[perf] stall` ≥250ms 计数 **51 → 1**；`THREAD_BLOCK_6S` **0**；100 首补读批次约 2 分钟内完成（大封面歌曲受让出节拍限速属预期）。

### 客户端同步与缓存批处理

- **先落库再上报**：调权 / 收藏 / 歌单 / 断点先写本地（`applyWeightEvent` 在写连接内原子读改写并同时入 `weight_outbox`），再由 `SyncEngine` 推送——**不要**在 UI 回调里直接调 API
- **outbox 幂等**：每条事件带 `event_uuid`，服务端按 uuid 去重；直连歌曲**未配对或 `sync_enabled=0` 时不入队**，避免无限积压
- **推拉节奏**：`SyncEngine` 2s tick 推增量、30s 拉增量、失败指数退避（上限 30s）、首帧后启动做一次增量校准。启动/回前台先走 `GET /playstates/latest` 断点快路径（1 RTT，旧服务端 404 静默回退），**冷启动首轮只拉不推**（`pullOnly`：先掌握远端再上报积压；首轮在飞行时 tick 被单飞挡下，收尾后首个 tick 见积压才发全量轮先推后拉；`awaitFirstPull` 等这轮收尾，不重复发起）。断点回调整轮 pull 结束后统一触发（single-flight、与首次恢复异步尾串行，不多页中途换曲）。播放/暂停/切歌经 `PlayerProvider.attachSyncHooks` 即时 `poke()` 一轮（单飞合并；暂停/停止先强制落最终断点再推，保证本轮带走最终位置）。**首帧轻量化**：`sync.start()` / `direct.attachApi()` / `ArtistResolver.start()` 统一在 `main()` 的 post-frame 回调里启动，不参与首帧渲染
- **后台同步门控（播放中例外）**：退后台且未播放则停表（`pause()`，在飞轮次不打断）；**播放中后台保持 2s tick**（`setPlaying` 由播放状态流驱动，四端一致、不做平台判断——前台服务保活下网络可用）。暂停态后台不轮询，回前台/开播即补轮
- **本机优先**：pull 快照命中“本地还有未推事件”的实体时跳过，不覆盖本地脏行（实体键 `sync_entity_key.dart` 与服务端 `entityKeyOf` 同规则；push 回包 corrections 是刚推完的仲裁结果、不受此限；ack 后下一轮自然收敛）
- **断点采纳口径（v2 按版本，legacy 按最后操作时间）**：v2 客户端同一歌单用 `head_rev`/`history_rev` 是否前进判断（`breakpoint_sync_state` 持久化已应用版本；pending head 未确认前 defer 远端 head），跨歌单仍按 `head_updated_at`；legacy 路径保持原口径：`GET /playstates/latest` 全局最新断点行，排序与「谁更新」比较一律用**最后操作时间 `last_event_at`**（= 命中事件的 `occurred_at`；服务端 `coalesce(last_event_at, updated_at)` 兼容旧行，客户端 `compareClock = last_event_at ?? updated_at`）——`updated_at` 是服务端写入/上传时间，只作诊断，不参与仲裁。`db_writer` 按 v2 版本或 legacy 时钟守卫（旧快照不覆盖新镜像）。服务端断点当前曲/进度 v2 走 head HLC，legacy 走行级 LWW；**深层列表不参与 LWW**，走下面的分支合并
- **启动收敛闸门（防旧态盖新）**：恢复发起（`restoreIfAny`/`restorePreferRemote`）即关闸——首个 `applyNewerMirrorIfAny` 判定跑完（或 30s 兜底超时）前，断点一律不入队：本机恢复出的旧断点可能已被远端更新，此时盖 now 的 `occurred_at` 推上去会被服务端 LWW 收下（毒源），随后本机又把自己的回声拉回来（回退旧曲的完整回路）。暂停/停止的**强制**断点在闸后**补跑一次**（`_bootForcedPending`）；周期保存直接丢弃。同类防线（非启动期）：**暂停态补写不刷新 `occurred_at`**——非强制补写只在断点真的变了（切歌/位置前进）时才入队，原样补写直接跳过（回前台/退后台/退出落盘都走这条，否则旧断点盖 now 推上去与启动期毒源同款）。无恢复路径（未开断点续播）时闸门默认已开
- **自写回声过滤**：快照来源 `device_client_id` == 本设备（fastPath / pull playstates / push corrections 三条落镜像路径）一律跳过、不落 `breakpoint_mirror`、不通知播放器——本机运行时状态必然不旧于自己推上去的数据，回流只会招来「自己套用自己的旧快照」；镜像行持久化来源设备（`breakpoint_mirror.device_id`）供诊断与排查
- **同步后台化（写隔离收口）**：outbox 读取 + `jsonDecode`（`pendingOutbox`/`pendingOutboxCount` op）、pull 快照的字段映射与落库（`applySongSnapshotsRaw` / `applyPlaylistSnapshots` / `applyPlaystateMirror`）、断点歌单存在性判定，全部在写隔离（`db_writer`）内完成；UI isolate 只 `await`。**OHOS**：写隔离已于 2026-10-20 切回（子 isolate 内由 `openIsolateDatabase` 注入 sqlite3 override），正常路径不再在 UI 线程写库；仅当写隔离启动超过 8s 或初始化失败时回退 `_InlineDbWriter`，兜底路径按 200 行/事务分片、片间 `await` 让出事件循环。cursor 在整页应用后才推进，中途失败靠重拉幂等收敛。内联的历史原因是 `open.overrideForAll` 只在当前 isolate 生效，子 isolate 里 `sqlite3.open` 会抛 `UnsupportedError`——**不是引擎不能 spawn**
- **跨页去重**：服务端只在单页内按实体去重，`_pull` 按 `source_id|ref` / uuid 跨页去重，重复快照只计数不重复落库
- **落库回调帧末投递**：`onSourcesApplied/onSongStatesApplied/onPlaylistsApplied` 经 `scheduleAfterFrame`（`utils/frame_scheduler.dart`）推迟到帧末；歌单回调携带本轮变更 uuid，`PlaylistsProvider.refresh(changedUuids:)` 只重查变更歌单计数（避免同步一次 N+1 全量重查）；源 watcher 仅在本地源 key/rootPath 真变化时重建
- **拉到的快照走 `apply*Snapshot` op**：身份收集恒不建行（已删歌曲不重新建行）；远端断点落 `breakpoint_mirror`，不直接改运行时 `play_state`
- **缓存写入攒批**：WebDAV 缓存下载按 1MiB（`_cacheWriteBufBytes`）攒够再落临时文件，成功后 `cacheCommit` 换入正式路径并更新 `cache` 表——避免逐 chunk 小写入；`persistCover` 同样先写临时文件再改名，保证重复扫描幂等
- 同步协议语义（LWW / 事件重算 / 歌曲身份 / 断点不牵连歌单快照 / 事件日志压缩）见「[播放算法与同步协议](#播放算法与同步协议)」

### 歌词与后台播放

- **歌词三通道**：内嵌标签（mp3 `USLT` / FLAC `LYRICS`·`UNSYNCEDLYRICS`）→ 同目录同名 `.lrc`（local/WebDAV 通用，UTF-8/UTF-16 BOM 兼容，后端不提供歌词）；解析为 LRC 文本入库 `song_lyrics`（`(source_key,ref)` 主键，三态：内容 / 显式标记缺失 / 未读取），缺失标记避免每次播放重复读文件。
- **歌词页**：与播放进度同步滚动 + 高亮当前行 + 点击任意行 seek；对齐位按布局区分（`LyricsView.align`）：竖屏三页布局的整页歌词页 `0.42`（略偏上，给下方未唱行留空间），横屏两页布局的内嵌歌词列 `0.5`（垂直居中）。手动拖动暂停跟随，空闲「追焦等待」超时后回中，切歌归位；`lrc_parser.dart` 支持多标签 / `offset` / 毫秒位数 / 纯文本退化 / 二分定位 / 译文行 ` / ` 换行。
- **歌词跟焦为自愈式**（`lyrics_view.dart`）：每次位置事件都按真实布局复核当前行是否在位，不以「行号是否变化」为触发条件——`ListView.builder` 懒构建导致目标行尚未构建时，先临时加宽 `cacheExtent` 让目标行被构建（经典 `double` 写法以兼容 ohos 分支，最多补滚 3 次），再用 `RenderAbstractViewport.getOffsetToReveal` 只滚歌词列表（不用 `Scrollable.ensureVisible`，避免把外层 `PageView` 一起拖动）；首次归位 `jumpTo`、换行 `animateTo`；拖动 / 鼠标滚轮 / 触控板滚动均抑制跟焦（滚轮 `dragDetails` 为 null，需经指针信号单独识别），续期式空闲计时超时后恢复并回中。
  **复核 ≠ 重开动画**（2026-10-15 真机取证）：位置事件可以比帧频还快——just_audio 的 `positionStream` = 播放事件 + `Timer.periodic(duration/800)`，鸿蒙位置事件由 AVPlayer `timeUpdate` 驱动（默认 100ms；旧 fvp 后端在部分机型按帧率触发 68 次/秒，平板 10 次/秒，这也正是「平板不复现」的原因）。旧实现每次事件都 `animateTo`，把 320ms 的缓动拆成逐帧重开：**每段新动画的第一次 tick 位移恒为 0**（ticker 起始时间在首帧才记），滚动退化为爬行卡顿（现象：追焦一卡一卡、手指一碰即不卡、当前行高亮正常）。现规则：动画在飞期间只有「换行」或目标漂移超过 `_retargetTolerance`（4px）才重定目标，其余交给动画自己走完；动画完成回调带代次校验（`_animGen`），旧动画被取代后不得清空新动画的飞行状态；剩余距离 <24px 用 140ms 短动画。回归用例：`test/lyrics_follow_test.dart`「位置事件比帧频还快时不得反复打断跟焦动画」
  **行高必须在换行帧定稿**（2026-10-15 真机反馈「每次换行收尾补 4px」的根因）：字号/字重若走 200ms 补间，行高在换行后持续变化（当前行变高 4.5px、上一行同步变矮），目标由「上一行行顶 + 本行行高×对齐位」共同决定 → 动画落点必然差几像素，收尾还得补一次；**长行/长译文更糟**：折行数在补间中途跨越阈值突然 +1 行，目标整行跳变（≥24px）→ 每次都二次校正。故行文本拆 `_LyricRowText`/`_FadingText`：字号/字重同帧切换，只有颜色补间（颜色不影响排版）。回归用例：`test/lyrics_follow_test.dart`「换行后行高同帧定稿」「长行折行（行数随状态变化）时同样一次落位」——两条用例在旧写法下必失败（实测：折行用例报 `Expected >110, Actual 88`）
- **后台播放**：Android 走 `audio_service` 自研处理器（`SelfMusicAudioHandler`），返回桌面 / 切后台**继续播放**；通知栏「退出软件」/ 划掉任务 / 侧边栏「退出」才真正停止。**前台服务恒注册**，`notification_controls=false` 只隐藏通知里的 5 个按钮（后台保活不受该开关影响）；鸿蒙 AVSession 桥同理恒注册（见「[鸿蒙适配](#鸿蒙适配)」）。
- **睡眠定时四模式**：指定时间 / 时长 / 曲数 / 列表结尾（+ 播放完最后曲目）；「指定时长/曲数」滚轮选择并**记忆上次值**（`sleep_default_duration_minutes` / `sleep_default_count`）；「播放结束退出软件」仅当次生效（开时 `shutdown()` 后 `exit(0)`，否则暂停驻留）。
- **播放页控件自动隐藏**（`player_auto_hide_idle_sec`，默认 5，0=不隐藏）：仅播放页计静置；超时淡出左上「返回内容」与封面右上「更多」两个纯入口；根布局 `Listener(translucent)` 任何触摸都重新计时，进入歌单页 / 歌词页 / 切到内容区不参与隐藏。

### 列表 / 卡片 / 多选

四层收口（此前同一形态在 10 处各写一遍）：

| 层 | 载体 | 约定 |
|----|------|------|
| 外壳 | `widgets/row_list.dart` 的 `RowList` | 唯一固定行高列表外壳：统一 `itemExtent`、分隔线缩进、末行不带线、可选下拉刷新 |
| 行 | `widgets/song_list.dart` 的 `SongTile` | 唯一歌曲行：封面 + 标题 + 副标题 + 时长/菜单；集合类行（歌单 / 专辑 / 歌手 / 播放源）用 `ListTile` + `CoverThumb` |
| 卡片 | `widgets/square_card.dart` 的 `SquareCard`/`SquareCardGrid` | 唯一方形卡片：封面恒 1:1（列宽按可用宽度算，不写死 `childAspectRatio`）、标题 2 行上限、按「最大宽 × 设备像素比」降采样解码 |
| 多选 | `widgets/list_selection.dart` 的 `Selection<T>` + `widgets/selection_bar.dart` | 选择状态内核与批量栏；勾选标记统一 `widgets/selection_badge.dart` |

几何常量（`row_list.dart`，改动须同步 `playlists_view_test` 的 `itemExtent` 断言）：`kRowHeight=72`、`kRowSeparatorHeight=1`、`kRowExtent=73`、`kRowDividerIndent=72`、`kListHeaderHeight=44`。

**为什么 `itemExtent` 不能省**：没有它时 Sliver 为定位深处目标需从第 0 行逐行排到目标行——千首歌单一帧构建 700+ 行与封面，进入必卡（实测 712 项 vs 16 项，`playlists_view_test` 有回归用例）。

- 标题常驻加粗（`w600`），播放中 / 选中只叠主色区分；封面位恒为封面，播放指示 `graphic_eq` 排在标题之后。
- 多选勾选框叠在封面左上角；多选态隐藏单曲三点菜单；「已选 N」与批量动作口径 = 当前可见项（搜索过滤后不统计也不作用）；队列面板不参与多选。
- 歌曲列表计数栏右侧固定为工具条图标：**多选 / 全部展开 / 全部折叠 / 分类 / 排序**（展开/折叠仅在平铺分组或源页有文件夹时出现，按当前状态禁用）；进入多选后顶栏换成 **全选 / 全不选** 图标 + 批量动作三点菜单；「长按展开/折叠」只影响长按组头/文件夹行行为，不再改变工具条入口。
- **源页文件夹树**：`source_folders.dart` 的 `SourceFolderTree` 一次构建完整目录树（`SourceFolderTreeCache` 按路径列表身份缓存），`song_groups.dart` 的 `buildSourceTreeRows` 按展开集合先序扁平成带 `depth` 的行；文件夹行右侧只保留「展开/折叠」箭头（进入目录靠行点击/面包屑），展开状态按 collectionKey 持久化；A 模式长按选中子树，B 模式长按切换该文件夹展开；搜索态仍强制平铺。
- **桌面鼠标右键 = 三点按钮同款菜单**（指针处展开，定位统一走 `widgets/context_menu.dart` 的 `showContextMenuAt`）；菜单项与选中回调必须三点/右键共用一份；多选态、已吊销设备等「按钮不出现」的场景右键同样不响应；触摸端无 secondary tap，行为不变。覆盖：歌曲行（含队列）、歌单行/卡片、播放源行/卡片、设备行、播放页封面。
- 视图模式：`ViewModeState` mixin + `ViewModeSlot`（`view_mode_toggle.dart`）收口歌单 / 播放源 / 专辑 / 歌手四页切换。

### 内容页分栏（大横屏 · 列表模式）

大横屏下内容页拆「左列表 / 右详情」两栏：左栏是当前分组的列表（歌单 / 专辑 / 歌手），右栏是选中项的详情。窄屏、卡片模式、内容区不够宽仍走原形态（拖拽弹层 / 整页叠层）。

| 关注点 | 落点 | 约定 |
|--------|------|------|
| 判屏口径 | `layout/screen_metrics.dart` 的 `ScreenMetrics` | **唯一出口**：`isWide`（宽 ≥900 或任意横屏）、`isLandscape`、`isLargeLandscape`（内容区 ≥ `kSplitMinContentWidth=640`）、`listPaneWidth`（内容区 34%，钳 280~360） |
| 是否分栏 | `splitDetailActive(context)` | 判屏 + 该分组有"列表→详情"语义（歌单/专辑/歌手）+ 该分组**展示形式为列表**；卡片在窄左栏放不下一列，不分栏 |
| 容器 | `widgets/list_detail_split.dart` 的 `ListDetailSplit` | `enabled=false` 时原样返回列表（零额外图层）；两栏各自 `RepaintBoundary` + 1px `outlineVariant` 竖分隔线 |
| 右栏 | 同文件 `DetailPane` | 空态占位 + 栏内轻量过渡（`kDetailPaneMotion=180ms`，全局「关闭」档为零）；比整页 300ms 短，因为只有一栏在动 |
| 详情本体 | `library_screen.dart` 的 `detailPageOf` | 窄屏弹层 / 宽屏整页叠层 / 分栏右栏**共用同一份**详情实现（`_AlbumDetailPage` / `_ArtistDetailPage` / `PlaylistDetailView(inline: true)`） |
| 状态 | `NavigationProvider.details` / `browsingPlaylistId` | 分栏不新增"选中态"：右栏直接消费既有路由状态，跨断点切换不丢"当前在看什么" |

- **内容区宽度必须用目标值**：`AppShell` 按 `窗口宽 − 侧栏 260 − 队列 360`（都是**目标**宽度，不是 300ms 伸缩动画中的实时值）算好经 `ScreenMetrics` 下发，否则分栏会在阈值附近来回抖。手机横屏（800−260=540）因此不会误分栏。
- **区域切换动画与分栏互斥**：分栏时 `AppContent` 把区域键固定成 `split:<分组>`，进/出歌单、专辑、歌手详情只换右栏（`AppContent` 注释）；设置页与源内浏览仍走原区域键与滑动动画。
- **搜索词保留**：分栏时搜索框就是左栏的过滤器，`enterPlaylist / enterAlbum / enterArtist / exitDetail / exitPlaylist / backToPrevious` 都带 `keepSearch`，由调用点按 `splitDetailActive` 传值；非分栏沿用"进/出详情清空搜索"的旧口径。
- **左栏换选中项不叠加层**：左栏（分组列表）点选用 `root: true` 把详情栈重置为这一层；只有详情内部的嵌套入口（歌手专辑横条、成员/组合作品行）才压在上一层之上（`fromDetail`）。
- **行内"宽行技术信息"按列表实际宽度判定**：`SongCollectionView` 在外层做一次 `LayoutBuilder`（不再用窗口宽），否则分栏右栏（如 360 宽）会塞进 `播放源 · 格式 · 码率 · 大小` 撑爆 `ListTile` 尾部断言。
- 左栏选中行用 `ListTile.tileColor`（主色 10%）提示，不用 `selected`（避免文字/图标整体变主色）；列表带 `PageStorageKey`，分栏↔整页切换后滚动位置仍在。
- 回归：`test/album_artist_detail_wide_test.dart`（分栏/整页两条路径 + 换选中项 + 搜索保留）、`test/content_split_layout_test.dart`（阈值、容器、右栏过渡、歌单分栏与搜索语义）。

### 顶栏搜索作用域

全局只有一个搜索词：`NavigationProvider.search`，顶栏 `TopBar` 是唯一输入框。各区域不各自保存查询串，而是按当前路由解释同一个词；提示语由 `NavigationProvider.searchHint` 统一给出：

| 区域 | 搜索对象 | 提示语 |
|------|----------|--------|
| 播放源列表 | 播放源名称 | 搜索播放源 |
| 源内浏览 | 当前源全部曲目的标题/歌手/专辑 | 搜索该源全部曲目 |
| 歌单列表 | 歌单名 / 歌曲 | 搜索歌单 / 歌曲 |
| 歌单详情 | 歌单内歌曲 | 搜索歌单内歌曲 |
| 专辑 / 歌手列表 | 专辑名/艺术家、歌手名 | 搜索专辑 / 艺术家、搜索歌手 |
| 歌曲 / 喜欢 | 标题/艺术家 | 搜索标题 / 艺术家 |
| 设置 / 队列 / 播放页 | 不参与（顶栏不可见或无列表） | — |

生命周期：六个顶级分区之间切换**保留**搜索词（便于跨页找同一批内容）；进入或离开源内、歌单详情、宽屏专辑/歌手详情栈时**清空**（详情页的搜索对象与分区不同，带着旧词会让目标页看起来被莫名过滤）。例外是**大横屏分栏**（见上一节）：左栏就是该分组的列表，搜索框仍是它的过滤器，进出右栏详情保留搜索词。清空与路由变更合并在同一次 `notifyListeners()` 中，不得额外通知。源内浏览不得再加本地搜索框；`SongList` 在顶栏可见的页面用 `globalSearch: true`，仅播放器附着的歌单页因顶栏不可见保留 `globalSearch: false` 的本地输入框。

### 桌面音频后端（media_kit）

Linux / Windows 桌面统一 `just_audio_media_kit`（底层 libmpv）：libmpv 由 `media_kit_libs_linux` / `media_kit_libs_windows_audio` **随包分发，无需系统安装 mpv**。`main()` 顶部 `JustAudioMediaKit.ensureInitialized()` 完成注册（默认参数 Windows/Linux 启用、Android 关闭走 ExoPlayer）。

**请求头不再走 just_audio 的 Dart 回环代理**：`AudioPlayer(useProxyForRequestHeaders:false)` 在所有支持平台生效——桌面由 just_audio_media_kit 的 `Media(httpHeaders)` 落到 mpv `http-header-fields`（Linux 已实测 Basic 鉴权头、百分号编码 URL 均到达源），Android/鸿蒙分别走 ExoPlayer/AVPlayer 原生请求头。该 Dart 代理会把音频逐块经 UI isolate 转发，是桌面 mpv 启动预载与移动端之间唯一的网络链路差异（e202168 因此改为延迟装载）。SMB/SFTP 的自建字节流（`StreamAudioSource`）不受该开关控制、仍走 just_audio 代理。

**桌面均衡器（10 段）**：`frontend/lib/services/equalizer/` 统一 10 段标准频率、preamp 与各平台后端。桌面 `MpvEqualizerBackend` 通过 vendored `just_audio_media_kit` 暴露的 mpv Player 设置 `af` 链：10 个命名 `lavfi-equalizer` + 可选 `lavfi-volume` 前级；拖动时用 `af-command eqN gain ...` 平滑更新（30ms 合并），300ms 后用 `af set` 写回完整链（mpv 的 af-command 不更新存储参数，seek/切歌会按旧参数重建）。`main()` 中必须保持 `JustAudioMediaKit.pitch = false`：否则 just_audio 每次装载的 `setSpeed/setPitch(1.0)` 会写 `af=scaletempo` 覆盖 EQ 链。Android 侧由 `EqualizerController.kt` 挂到 just_audio 的 audioSessionId，优先 `DynamicsProcessing`、失败回退系统 `Equalizer`；鸿蒙 AVPlayer 无自定义 EQ，UI 明确置灰。

启动预载门控（`PlayerProvider._canPreloadRestore`）在桌面按「最终链路是否安全」判定：直连 URL/本地文件、本地原文件缓存、转码变体缓存、后端代理/转码 HTTP、以及 MediaProxy 可用的 SMB/SFTP 都会预载；只有 MediaProxy 不可用且最终只能落到 `DirectAudioSource` 的源继续延迟。所有桌面预载都带 `preloadOnly` 安全边界：缓存索引失效、后端转码失败或 MediaProxy 启动失败时直接中止并保持延迟，绝不回落 Dart 字节流。桌面预载在首帧后启动、不阻塞 `restoreFuture`；`applyNewerMirrorIfAny` 会等预载收尾，并跳过用户装载中的窗口。

### SMB/SFTP MediaProxy（独立 isolate 回环 HTTP）

SMB/SFTP 原始流默认不再走 just_audio 的 `StreamAudioSource`/Dart 回环代理，而是由 `MediaProxyClient` 启动独立 isolate：isolate 内绑定 `127.0.0.1` 的 `HttpServer`，SMB 用 `Smb2Pool`、SFTP 用 `SftpWorker` 读取，直接向 native player 输出 `GET/HEAD + Range`；UI isolate 只拿一个带随机 token 的 loopback URL 并 `setUrl`。音频字节不再经过 UI。

- 总开关：`kMediaProxyEnabled`（默认 true；应急 `--dart-define=MEDIA_PROXY=false` 关闭，整体回落旧路径）。
- session：进程内一个 MediaProxy isolate、同一时间一个活动 session；换曲/停止作废旧 token，旧请求 404/410。
- SFTP 读槽优先级：每个 HTTP Range 按「越短优先级越高」分配 `priority`，同长度按新流优先（日志 `http.request ... prio=N tie=M`），worker 的 4 个读槽优先服务 seek/探测流。播放器 seek 时会新开 Range、旧的全文件流不关闭；没有优先级时旧流会把 seek 流饿死（真机曾 31s 只拿到 131KB）。SMB 走独立连接池，不受此调度影响。
- 尾部预读：SFTP session 启动时在 probe 内预读最后 64KB 存入 session 缓存（日志 `adapter.tailCache`），播放器的尾部 Range（FLAC seektable，通常 1–3KB）直接命中（日志 `cache=tail`），不再排在全文件流的 4 个在途读之后 open（真机曾 5.8s）。未命中的 Range 仍走正常链路。
- SMB 初始化：`SmbInitBroker` 用独立 broker isolate 串行化所有 `Smb2Pool.connect`/`smb2Walk`（libsmb2 的全局 `active_contexts` 无内部锁）；UI/扫描/代理共用同一 broker 端口。
- 失败策略：MediaProxy 启动失败先重启 isolate 重试一次；用户主动播放仍失败则回落 `DirectAudioSource`（UI 字节）；桌面启动预载失败保持延迟，绝不回落。文件不存在/无权限/鉴权失败/主机指纹失配属于永久错误，不重启、不回退，直接抛 `MediaProxyUnavailableException`（多线路时只再试下一线路）。运行中播放错误由 `_onPlaybackError` 走 `_recoverPlayback` 重建 session。
- 埋点（App 内收集日志可 grep）：`mediaProxy.isolate.*`、`mediaProxy.smbBroker`、`mediaProxy.start*`、`mediaProxy.retry/fallback/unavailable/configUnavailable/loadFail`、`mediaProxy.worker isolate.ready/adapter.probe.*/session.*/http.*`、`smbInitBroker.*`。其中 `http.done` 是完整传完，`http.cancel/http.abort` 是切歌/停止/客户端断开导致的正常中止（不记错误），只有 `http.error` 才是真实传输失败。
- worker 的 `file` 适配器仅测试用；真实 SMB/SFTP 需按日志在 Windows/Android/鸿蒙真机验证。

> 注：`just_audio_mpv`（0.1.7）从未接线（无 import、无初始化），已从 pubspec 移除；Linux 桌面播放由 media_kit 接通。

### 客户端播放要点（装载/切歌/返回）

- **装载前置鉴权探针**：原生装载器（AVPlayer/ExoPlayer）对 401/403 错误响应只会无限缓冲，进度停 0:00 且无任何提示（2026-09-29 密码过期真机实测）。`_loadOnce` 在 setUrl 前先发 1 字节 Range 探针（`MusicSource.probe`，与取流路径同口径）：401/403 立即失败提示，其余探针异常忽略后继续装载（网络抖动交给播放器重试）
- **装载看门狗（2026-09-30）**：原生播放器对「主机不可达/无响应」的 open 可能没有应用层超时——历史实测（mdk）IPv6 路由丢失时 prepare 永久挂起，UI 卡 00:00/00:00、点播放无响应。setUrl 统一裹 15s 超时（`PlayerProvider._loadUrlTimeout`），超时按装载失败进入 `loadBackoff` 退避重试、耗尽后走失败提示/自动跳曲；被放弃的迟到结果用 `Future.ignore()` 吞掉防 unhandled。AVPlayer/ExoPlayer 自带连接超时通常先报错，看门狗仅作兜底
- **自动切歌 play 空转问题（2026-09-30）**：just_audio 的 `play()` 首行 `if (playing) return`——上一首自然播完 playing 不会自动复位，装载下一首后 `play()` 静默空转、平台层收不到播放指令。ohos 表现为切歌无声 + 进度条靠 Dart 时钟插值假走（暂停时回跳 0）；Android 因 ExoPlayer `playWhenReady` 状态跨装载保持而恰好正常。修复在 `PlayerProvider._play`：装载完成需要播放时先 `pause()` 复位 playing 再 `play()`——**该复位逻辑为必要修复，请勿删除或"优化"**，详见该处注释
- **返回手势 = 转后台**：移动端侧滑/返回键不退出应用（后台续播），收口在 `platform/app_background.dart`（Android 通道 `com.shamiko.selfmusic/app`、ohos 通道 `selfmusic/app`，均为 `moveToBackground`），`main.dart` 的 `_onPopInvoked` 是唯一调用点、通道失败兜底原行为；桌面端恒 false。调整退出行为只动这两处

### 鸿蒙适配

工具链：`CPF-Flutter/flutter_flutter` 三方分支 `oh-3.41.9-release`（Dart 3.11，与 stable 并存，独立 wrapper 切换）+ DevEco Studio（ohpm/hvigor/node）+ 真机联调（Windows 上无模拟器）。壳工程 `frontend/ohos/` 已由 `flutter create --platforms ohos .` 生成。

插件审计结论（2026-09，pub.dev 实测）：

| 依赖 | ohos 方案 | 状态 |
|------|-----------|------|
| path_provider | `path_provider_ohos` 2.2.1 + 超时重试包装（保险层：1s 超时 × 5 次重发 + 沙盒回退；旧"引擎吞回复"假设已被实测否定，见下节） | ✅ 直接用 + 保险 |
| file_selector | 备份导入导出直接用；本地文件夹源「选择目录」的 `getDirectoryPath` 在 `file_selector_ohos` 未实现（调用必抛异常）→ ohos 改走平台桥 `pickDirectory`（DocumentViewPicker FOLDER + fileShare 持久化，见「系统能力平台桥」）；「收集日志」同理改走平台桥 `saveFile`（DocumentViewPicker 保存模式 + 原生复制） | ✅ 分场景处理 |
| **just_audio（音频后端）** | **系统 AVPlayer**（API 12+）+ 自写纯 Dart 适配层 `just_audio_platform_interface` → ArkTS 桥 `AvPlayerBridge.ets`（方法/事件双通道） | ✅ 已实现（`lib/platform/harmonyos/just_audio_avplayer.dart`，2026-10 真机 P0 全过） |
| flutter_secure_storage | 两层适配：① `FlutterSecureStoragePlatform` 文件 shim；② **前端类绕过**——上游 9.2.4 的 `_selectOptions()` 对 ohos 无条件 throw 且 `_platform` 是逐调用 getter（包级注册平台实例救不了前端），子类 `OhosFlutterSecureStorage` 覆写六入口直调平台实例 + `createSecureStorage()` 工厂收口构造点 | ✅ 已实现（`secure_storage_ohos.dart`） |
| permission_handler | 桩包同样不兼容；应用内调用点均已 `Platform.isAndroid` 门控，ohos 不触发 | ✅ 无需处理 |
| wakelock_plus | 桩包不兼容 → `setupOhos` 注册 `OhosWakelockPlusPlatform`（`wakelock_plus_ohos.dart`，转接平台桥 keepScreenOn → `window.setWindowKeepScreenOn`），player_screen 的 ohos guard 移除、常亮逻辑全平台统一 | ✅ 已实现（2026-10，见「系统能力平台桥」） |
| audio_service | 无 ohos 实现 → 按预案降级「无通知栏」（代码已按 `Platform.isAndroid` 门控） | ✅ |
| sqlite3 | `open.overrideForAll()` 按名 dlopen `libsqlite3.so`——**设备系统无此库**（7 路径实测全无），命中的是随包分发的自编译副本（构建配方见下节） | ✅ 已实现（`ohos_bootstrap.dart` + `entry/libs/arm64-v8a/libsqlite3.so`） |
| audio_session | `AudioSession.instance` 在无插件平台 catch 掉 `MissingPluginException` 返回空实现，just_audio 的 `handleInterruptions` 安全（与 Windows/Linux 同路径） | ✅ 已验证，无需处理 |
| cached_network_image | 传递依赖 sqflite 无 ohos 实现 → 封面降级显示，不阻塞点播验收 | ⚠️ 已知问题 |

关键事实：
- **跨 SDK 兼容铁律**：stable 工具链的 `dart:io` 没有 `Platform.isOhos` getter，所有 ohos 判断必须写 `Platform.operatingSystem == 'ohos'`（两套 SDK 都可编译且行为一致），见 `lib/platform/harmonyos/ohos_bootstrap.dart` 的 `isOhos`
- **stable 新 API 在 ohos 分支可能不存在**：同一 `lib/` 要在两套 SDK 下编译，新 API 先查 ohos 分支（3.41.9）有没有——实例：`ScrollCacheExtent` 类 ohos 分支没有，`lyrics_view.dart` 的 cacheExtent 改回经典 `double` 写法（2026-09-30）。analyze 双跑（stable + ohos 分支）是这类问题的验收闸门
- WebDAV 直连鉴权走 `Authorization: Basic` 头；鸿蒙 AVPlayer 经 `media.createMediaSourceWithUrl(url, headers)` 原生透传（Bearer / X-Origin-* 同理），文件/回环字节流走 `fdSrc`/`http://127.0.0.1`。`DirectAudioSource` 字节流（just_audio 内建 localhost 代理）为兜底，三种音源形态（file://、https://+Basic、127.0.0.1 代理）都到达 `ProgressiveAudioSourceMessage` 统一处理
- 鸿蒙播放由系统 AVPlayer 提供，**不再随包分发播放/解码 .so**：HAP 的 native 库只剩 libapp / libflutter / libsqlite3（自编译）/ libsmb2（SMB FFI）。2026-10 全量替换实测 HAP 43.0MB → **32.1MB**（arm64-v8a），构建期也不再下载 mdk 预编译库
- 自签证书：真机实测 **Media Kit 不校验 TLS**（从未安装过的自签叶证书直接可播）；`允许自签` 开关只影响 dart:io 的扫描/探测/API。注意这是相对 mdk（默认校验证书）的安全行为变化（HTTPS 播放可被中间人替换流/窃取 `Authorization` 头），产品上已知悉并接受
- 转码流：AVPlayer 报出的 duration 可能为无效大值（实测 53,686,988ms），适配层按 URL 含 `/transcode/stream` 强制忽略、回退歌曲元数据时长；seek 走应用层 `start_sec` 重载（服务端 ffmpeg 重启约 4s）
- flutter 工具自动把带 ohos 模块的插件写入 `ohos/build-profile.json5` modules 与 har overrides，无需手工接线

适配层实现（`lib/platform/harmonyos/`，2026-09）：
- `ohos_bootstrap.dart`：`setupOhos()` 在 `main()` 里 runApp 前调用，六件事全部仅 ohos 生效——sqlite3 overrideForAll（顶层函数，**仅本 isolate 有效**：不随 Isolate.spawn 传入子 isolate；子 isolate 内由 `openIsolateDatabase` 重新注入，写隔离与后台读快照均可用；不是引擎限制）、`FlutterSecureStoragePlatform.instance = OhosSecureStorage()`（包级注册只覆盖平台侧，前端类另需绕过，见上表）、`JustAudioPlatform.instance = AvPlayerJustAudio()`、`PathProviderPlatform.instance = OhosRetryingPathProvider(原实现)`（单点收口：启动链全部路径调用均经该 instance）、`SecurityContext` 根证书注入（`_loadRootCerts`）、`WakelockPlusPlatformInterface.instance = OhosWakelockPlusPlatform()`（2026-10，常亮见下节）
- `path_provider_ohos_retry.dart`：1s 超时 × 5 次重发的保险包装 + 全超时沙盒路径回退（命中时日志 `[ohos] path_provider.* 响应超时`）；旧"引擎竞态吞回复"假设已被 verify-5/6 逐消息对账否定（见下节），保留理由：路径查询幂等、成本为零、覆盖未证实的极端时序
- `just_audio_avplayer.dart`：`AvPlayerJustAudio.init/disposePlayer` 管理播放器表；`AvPlayerHandle` 实现负载面 load/play/pause/seek/setVolume，pitch/shuffle/speed/loop 静默 no-op（应用层自实现循环）；事件映射：ArkTS 侧 `stateChange/position/duration/buffered/seekDone/error` → `PlaybackEventMessage`；错误必须 `_events.addError`（just_audio 0.9.46 不读 errorCode 字段）；位置由 AVPlayer timeUpdate 原生上报（默认 100ms），无 Dart 轮询；文件走 `fdSrc`（fd 由 ArkTS 持有到 reset/dispose）；带请求头走 `setMediaSource(createMediaSourceWithUrl)`（注意该 API 在目标机同步返回 void，不能 `.then`）；`setVolume` 在 prepared 前暂存、prepared 后补发，5400102 视为非致命
- **播放器生命周期竞态（2026-10-28 修复；日志特征 `404 播放器不存在`）**：原生 AVPlayer 报错 → 适配层 error 分支上报 idle → just_audio 0.9.46 对 playbackEvent 的 idle 转移**不 await** 地降级平台（`_setPlatformActive(false)` → `disposePlayer`）；旧桥 `handleDispose` 在 `await AVPlayer.release()` **之后**才按 id 删表，而回落重建（just_audio 重新 `createPlayer`，Dart 侧 player id 跨平台重建不变）可在该窗口内把同 id 新实例放进表，迟到的 delete 盲删把新实例清掉——Dart 仍认为平台激活、不会自行重建，此后 load/play/setVolume 恒 404，退避重试与换线路全部无效，只能重启应用。修法：桥内 create/dispose/disposeAll/shutdown 一律**同步摘表（`detachEntry`）再异步释放**，按 id 的后续消息立刻按不存在处理；Dart 适配层对 load 的 `404 播放器不存在` 补发 `createPlayer` 后重试一次（just_audio 不会自行重建，这是唯一自愈时机），已释放句柄不再下发 play/pause/seek/setVolume。错误文案可区分来源：`播放器不存在: <id>` 来自 load（表里已无该 id），不带 id 的来自 play/pause/seek/setVolume（实例在表但 player 为空/释放中）。回归测试 `test/just_audio_avplayer_load_recovery_test.dart`
- `secure_storage_ohos.dart`：文档目录单 JSON 文件 + 整文件 base64 混淆，内存即权威源；读写失败不抛（密钥问题不崩登录/配对流程）；对应 platform_interface 1.1.2 Map-options 签名（flutter_secure_storage 9.2.4 锁定该版本，`*Params` API 是 1.2+ 才有，勿混淆）

启动白屏根因（2026-09 真机取证）：两个应用/生态层问题，与引擎无关。

> 排查过程：最初根据"启动早期平台消息无回复"假设引擎存在消息竞态（约 130ms 窗口），并据此实现了超时重试包装。verify-5 逐消息对账否定了该假设——**67 条 FlutterNapi 回执无一丢失**，引擎消息通道全程正常；原取证中"挂起的 documentsPath 调用"实来自 `OhosSecureStorage._ensureLoaded`，回复本身已送达，阻塞发生在后续的前端读取。重试包装保留为无害保险层。

**白屏故障模型**（两个根因都"仅抛异常"，为何表现为永久白屏 + 零日志）：

- **白屏 = 渲染从未开始**：ArkTS 侧窗口/Surface 早已建好，内容全靠 `runApp()` 挂载组件树后才有人画；而 `main()` 的全部初始化都在 runApp 之前逐个 await——**链上任何一环抛异常，其后代码（runApp、markBootReady）全部不执行**
- **僵尸态**：Dart 的 async 异常只终止 `main()` 这个 Future 的续体，**不退出 isolate**——事件循环、平台通道、已注册回调全部存活。verify-5 实证：看门狗 60 次 poke 全被 Dart 收到并处理，而 markBootReady（位于 runApp 之后）永不触发；进程健在 → 系统无理由弹崩溃框 → 活进程 + 永远空白的窗口
- **零日志**：fork 启动早期未捕获异常的 stderr→hilog 转发缺失——verify-1~5 全文检索 Unhandled/UnsupportedError 为 0 命中，但异常确定抛出（修复后同一行代码立即恢复）；只能靠间接痕迹定位（根因① 看消息对账断在哪条回执后；根因② 看 MUSL-LDSO 行）
- **同类先例**：Android 上通知服务异常曾拖垮启动（`main.dart` 中"曾致白屏"的注释，修法为 try/catch）——故障类别相同，鸿蒙两处根因只是隐蔽性更强
- **故障链路**（函数级定位，修复后回溯验证）：根因① `main()` 的 `await ServerSettings.load()` → `server_settings.dart` load() 内 `secret.pairingKey()` → `secret_store.dart` 直通 `storage.read` → 前端 `_selectOptions` throw；根因② `main()` 的 `await direct.init()` → `local_index.dart` 索引库 `sqlite3.open` → override 的 `DynamicLibrary.open('libsqlite3.so')` → dlopen errno=2

- **根因① flutter_secure_storage 前端类在 ohos 直接 throw**：上游 9.2.4 的 `_selectOptions()` 对 ohos 不在预置平台表内时无条件抛错，且 `_platform` 是逐调用 getter——包级注册平台实例救不了前端。启动链 `ServerSettings.load()` 读配对密钥时 Future 链**静默断裂**（无 Unhandled/UnsupportedError 日志）。修复：`OhosFlutterSecureStorage` 子类覆写 write/read/containsKey/delete/readAll/deleteAll 六入口直调平台实例 + `createSecureStorage()` 工厂收口（`secret_store` / `api_client` / `theme_provider` 三处构造点）；`server_settings.load()` 另加读失败按未配对继续的兜底
- **根因② libsqlite3.so 缺失**：sqlite3 包在 ohos 走 `DynamicLibrary.open('libsqlite3.so')`，而设备系统 7 个候选路径全无此库、DevEco SDK 无、`sqlite3_flutter_libs`（0.5.42）只有 android/darwin/linux/windows 目录。`direct.init()` 内 dlopen 失败同样**静默中断**，唯一线索是 hilog 里应用 pid 的 `MUSL-LDSO: load libsqlite3.so failed ... errno=2` 三行。修复：自编译 musl 版 .so 随包分发（配方见下）
- **静默故障取证方法**（同类问题排查流程）：① `main()` 全链 `[boot]` 里程碑 debugPrint；② ArkTS 启动看门狗（`EntryAbility.ets` 每 1000ms poke，Dart 侧 `markBootReady()` 解除——未解除即 main 未走完）；③ hilog 逐消息对账：发送 = `DartMessenger --> Received message from Dart over channel '...'`，回复 = `FlutterNapi --> called handlePlatformMessage ... Response ID`；④ 原生库加载失败只看应用 pid 的 `MUSL-LDSO` 行（系统进程噪音极多）；⑤ 疑似卡死时 `hdc fport` + VM service 取栈
- **libsqlite3.so 构建配方**（sqlite.org 官网 Download 页 amalgamation 包，当前 3.53.4；产物 NEEDED 仅 libc.so——musl 全并入 libc，无需 -lm/-ldl）：

  ```powershell
  # <DevEco> = DevEco Studio 安装目录；升级 sqlite 版本时照抄换源码即可
  & "<DevEco>\sdk\default\openharmony\native\llvm\bin\clang.exe" `
    --target=aarch64-linux-ohos "--sysroot=<DevEco>\sdk\default\openharmony\native\sysroot" `
    -march=armv8-a -fPIC -shared -O2 -D__MUSL__ '-Wl,-soname,libsqlite3.so' `
    sqlite3.c -o frontend/ohos/entry/libs/arm64-v8a/libsqlite3.so
  ```

  hvigor 自动把 `entry/libs/arm64-v8a/` 打进 hap，应用 dlopen 按名命中包内副本
- 上游反馈（待办）：① flutter_secure_storage 支持 ohos（`_selectOptions` 放行或官方 ohos 分支）；② `sqlite3_flutter_libs` ohos 移植
- **验证（verify-6）**：启动引导 → 服务端设置加载完成 → db-writer 就绪（当时为内联；现默认写隔离，失败/超时才回退内联）→ 直连源就绪 → 进入 runApp → 看门狗解除，全链 1.4s 点亮；进程存活无崩溃标记，FlutterView 持续输出 `Display on` / `avoidAreaChangeCallback`（视图真实渲染非白屏）

其他鸿蒙配置事实（2026-09 收尾两连修，真机已验收）：

- 横竖屏：module.json5 abilities 的 `orientation` 字段 **fork 模板默认缺失 = 窗口不随传感器旋转**（与 Android manifest 无 screenOrientation 的行为不一致，勿想当然）；补 `"orientation": "auto_rotation"` 即放行（Flutter 侧 `player_screen.dart` 横屏分支本就存在，纯配置层问题），控制中心旋转锁定关闭时横屏 UI 正常触发。HAP 内 module.json 可明文核对该字段
- 应用图标：`AppScope/resources/base/media/app_icon.png` + `entry/src/main/resources/base/media/icon.png` 两个文件（模板默认 = Flutter 默认图 144×144），直接覆盖内容即可，`$media:app_icon`/`$media:icon` 引用与资源 ID 不动；图标源 = 仓库根 `selfmusic-sharp.png`（2026-10 起，1024×1024 / 841 KB / 32bpp 带透明；hvigor 打包会自动重编码压至 512×512 / 238 KB 进 HAP，无需手动缩放；2026-10-19 MatePad Air 真机复验通过：桌面/启动/主界面）；旧源 `frontend/assets/selfmusic.png` 288×288 圆角方案弃用，Flutter 侧资产文件保留未动

通知栏媒体播控（AVSession 桥，2026-09-29 真机验收）：

- 形态差异：鸿蒙没有 Android 式应用自绘媒体通知，媒体卡由系统统一渲染（通知栏/锁屏/播控中心三处），第三方只能喂 `AVSession` 数据、不能自定义布局；接入 AVSession 后后台长时任务的常驻通知也被 AVSession 接管，**不会**再出一条"播放中"通知——媒体卡本身就是鸿蒙的通知形态
- 架构（与 audio_handler 同构的非劫持薄转发）：`AvSessionBridge.ets`（通道 `selfmusic/avsession`，生命周期 create→元数据+播放态+命令注册→activate→`backgroundTaskManager` AUDIO_PLAYBACK 长时任务；destroy 收卡）+ `ohos_media_session.dart`（Dart 全量 sync 推送）+ `PlayerProvider.attachSystemMediaSync` 挂 `_syncSystemMedia` 既有时机；direct 监听补推收藏与内嵌歌词晚到
- int 映射（ArkTS 侧 switch 显式映射防非法值）：播放态 playing?2:3（`PlaybackState.PLAY=2/PAUSE=3`）；LoopMode sequence→0（LOOP_MODE_SEQUENCE）/loopOne→1（**SINGLE**）/loopList→2（**LIST 非 ALL**）/weighted→3（SHUFFLE）
- 歌词：AVMetadata.lyric 只收内嵌 LRC 文本，服务端 40960 字节上限，Dart 侧按 UTF-8 40000 截断后下发
- module.json5：backgroundModes 必须写在 **abilities[] 条目内**（`"backgroundModes": ["audioPlayback"]`；三重证据：官方属性表/modulecheck 白名单/FAQ），配 `ohos.permission.KEEP_BACKGROUND_RUNNING`（system_grant 免 reason）
- **封面（两段式，2026-09-30）**：元数据先行（卡片秒出，缺封面显示应用图标），封面异步解码后经第二次 `setAVMetadata` 补推。实测记录：`mediaImage` 传裸路径/`file://` string 时 `isImageValid checkFail`（av_session 服务进程读不了应用沙箱路径）→ `980000502`，**单字段校验失败会阻断整个播控卡**；PixelMap 方案首轮又因过早 release 触发 `GetMediaImageTopic checkFail`。最终方案要点：coverPath 传应用沙箱绝对路径，ArkTS 侧 fd→ImageSource→PixelMap 进 IPC 共享内存；PixelMap **保持引用至替换完成才 release**；同曲按路径去重、快速切歌用任务票据竞态淘汰过期解码（`AvSessionBridge.ets` 的 updateCover/decodeCover）
- ArkTS 注意：`MethodCall.argument()` 返回 Any，hvigor 编译器拒 Any 推断（`arkts-no-any-unknown`，**hvigor 比 arkts_check 严**）——用 argString/argNumber/argBool 类型化取参
- 验收（2026-09-29 真机）：卡片三处出现/播放暂停上一首下一首真控制/循环模式双向同步 ✓；收藏/后台持续/歌词因 WebDAV 服务器内容缺失暂无法验收（环境问题非回归：歌单同步正常证明主服务器 API 在线，WebDAV 扫描 0 首+流缓冲无声）；启动链零回归（桥就绪与看门狗同毫秒，Dart ready 1.65s）

系统能力平台桥（`selfmusic/platform`，2026-10 ohos-permissions feature；2026-10-06 ohos-thumb-native-decode feature 扩封面缩略图原生管线）：

- 缘起：常亮（wakelock_plus 桩不兼容）、本地文件夹源选目录（`file_selector_ohos` 无 getDirectoryPath）、蓝牙设备查询（Android 专有通道）三项在 ohos 均无可用插件实现——统一自建平台桥，装配范式同 AVSession 桥：ArkTS 侧 `entry/src/main/ets/platform/PlatformBridge.ets`（EntryAbility configureFlutterEngine 装配 / onDestroy 回收），Dart 侧 `ohos_platform_bridge.dart` 封装，业务层只在 `isOhos` 分支调用；后补第四项：封面缩略图原生解码（见下「封面缩略图」；当时 `runOffThread` 在 OHOS 内联，纯 Dart 编码卡 UI——内联是代码守卫，不是引擎限制）
- 18 方法契约（前 9 个唯一事实源：`spec/ohos-permissions/plan.md`「Contracts & Interfaces」；makeCoverThumb：`spec/ohos-thumb-native-decode/plan.md`；extractAudioMeta：`spec/ohos-meta-enrich-native/plan.md`；saveFile：2026-10-20 日志导出修复；文件级本地源 6 个方法：2026-10-22 鸿蒙 6 降级）：keepScreenOn / pickDirectory / saveFile / activateDirectory / listDirectory / readRange / requestBluetoothPermission / hasBluetoothPermission / listBondedDevices / connectedDevices / makeCoverThumb / extractAudioMeta / supportsFolderSelection / pickAudioFiles / activateUris / statFileUris / resolveFileUri / readFileUriRange
- 日志导出（2026-10-20）：鸿蒙「收集日志」原走 `file_selector` 的 `getDirectoryPath`，但 `file_selector_ohos` 0.5.0 的 pigeon 通道（`dev.flutter.pigeon.FileSelectorApi.getDirectoryPath`）压根没注册处理器，Dart 侧必抛 `PlatformException(channel-error, Unable to establish connection on channel.)`；反馈携带日志走 `selfmusic/email` 原生桥所以不受影响。修复：`saveFile` 用 `DocumentViewPicker` 保存模式（`newFileNames` 预填）选目标，用户取消（13900042/空结果）回 null，选定后把 Dart 侧临时日志分块复制到返回 URI；真实失败 error 上抛由 UI toast
- 本地文件夹源（US1）：module.json5 申请 `FILE_ACCESS_PERSIST`（system_grant 免弹窗免 reason）；选目录 = `picker.DocumentViewPicker` FOLDER 模式 + 当场 `fileShare.persistPermission`（**持久化必须趁选择器临时授权存活的同一会话内完成**，临时授权随应用退出清除；重复选择同一目录幂等处理——persistPermission 失败用 checkPersistentPermission 复核）；重启后首次访问前 `activatePermission` 激活（持久化数据在系统数据库，每次启动需手动激活；`OhosPlatformBridge.ensureDirectoryActivated` 同 URI 单飞 + 成功缓存，扫描/播放/元数据补读/字节流兜底统一经过它）；扫描 = `fs.listFile(recursion)` + 逐文件 `fs.stat` 全量快照，**主 isolate 执行不走 runScan**（授权 URI 非 dart:io 路径，且桥 handler 在主 isolate）——过滤/指纹 diff 复用 `local_direct_source.dart` 的 `_diffSnapshotEntry` 公共纯函数，isolate 路径行为逐字节不变；点播 = `cachedFilePath` 返回 null → DirectAudioSource 字节流兜底，`fs.read` 512 KiB 分块拉流（ArkTS 侧单次上限 2 MiB 防御，读取不完整按 13900030 error 上抛）；授权失效（撤销/目录删除）统一转译「目录授权已失效，请编辑该源重新选择目录」。ref 形态注意：库内 song ref 存无头相对路径（对齐 Android），桥 readRange 封装负责补 `/` 头再拼 URI
- 文件级本地源（鸿蒙 6 手机/平板降级，2026-10-22；同日调整入口时机）：`DocumentSelectMode.FOLDER` 的 FolderSelection 在 Phone/Tablet 到 API 26 才开放，鸿蒙 6 调用会触发系统「功能未开放」toast。UI 进入本地类型时不再预检/自动切模式，始终先展示「本地文件夹」输入框；点击选择按钮时才经 `supportsFolderSelection`（`canIUse`）校验：不支持则 toast「当前系统不支持选择文件夹，已改为选择音频文件」并直接打开 `pickAudioFiles`（DocumentViewPicker FILE 模式，500 上限，音频后缀过滤，取消 13900042 返回 null），成功后替换为文件列表（清空或移除最后一个文件恢复目录栏）。选择后逐 URI `persistPermission`（100 个一批，失败用 `checkPersistentPermission` 复核），配置存 `{"mode":"files","files":[{"ref","uri","name","size","mtime"}]}`（旧 `path` 配置零迁移）；ref 默认文件名，重名按扩展名前 ` (2)` 去重。扫描 = `statFileUris` 逐 URI stat + 指纹 diff（主 isolate，20000 上限）；播放优先 `resolveFileUri` 沙箱路径直连，失败回退 `readFileUriRange` 512 KiB 字节流；冷启动先 `activateUris` 激活（成功缓存）。限制：文件级源仅主本地源、无写操作/无 sidecar/无 watcher/不参与跨设备同步；同目录 .lrc 与封面不在授权范围
- 常亮（US2）：`window.setWindowKeepScreenOn`（无需权限声明，仅前台生效；退后台随窗口失焦自动失效是系统预期，回前台由播放器页按播放态重新拉起）；Dart 侧 `OhosWakelockPlusPlatform`（wakelock_plus_ohos.dart）注册进 `WakelockPlusPlatformInterface.instance`（setupOhos 第六件事），player_screen 的 ohos guard 移除、常亮门控逻辑全平台统一
- 蓝牙（US3）：module.json5 申请 `ACCESS_BLUETOOTH`（user_grant，`$string:bluetooth_permission_reason` + usedScene，base/zh_CN/en_US 三处 string.json 同步）；FR-009 启动期零权限——仅「常亮限定设备」设置页触发三段式申请（`requestPermissionsFromUser` 已授权短路 → 未授权走 `requestPermissionOnSetting` 设置弹框兜底，两次拒绝后只能引导去系统设置）；查询 = `connection.getPairedDevices` / `getRemoteDeviceName` + `a2dp.getConnectedDevices`（均同步 API + try/catch，蓝牙未开启 2900001 等异常一律降级空集合——与 Android「按未连接判定」的静默降级语义一致，`bluetooth_service.dart` 四方法 `isOhos` 分支收口）
- 封面缩略图原生管线（2026-10-06 ohos-thumb-native-decode feature）：列表缩略图原为纯 Dart `image` 包 `runOffThread` 编码——当时 `runOffThread` 在 OHOS 走内联守卫（**不是引擎不能 spawn**），打开应用触发存量封面回填时逐张数百 ms UI 块（全局卡顿根因，spec R-1）。原生管线保留：系统解码/编码更快，且字节不过通道。下沉为 `makeCoverThumb`（第 10 个通道方法）：ArkTS 侧 `@ohos.multimedia.image` 全链完成——fd→ImageSource 解码 → EXIF orientation 映射 rotate/flip 烘焙 → 最长边 768 降采样（90°/270° 注意 desiredSize 按旋转后语义换算宽高、绝不放大）→ JPEG q82 重编码 → `<thumbPath>.tmp` 写盘后 rename 原子替换；**缩略图字节不过通道**（Dart 只收 bool），读盘/解码/编码/写盘全在系统原生线程。失败纪律（R-5）：参数缺失/解码失败/超时（Dart 侧 15s）/任何异常一律 `result.success(false)` 静默回原图，**绝不回退内联 Dart 编码**（避免卡顿源重新生效）；`ensureCoverThumb` 的 ohos 分支复用既有 `_thumbInflight` 去重与 `_displayPathCache`/`_thumbReady` 缓存，非 ohos 代码路径字节不变（零回归）。启动回填配 50ms 逐张节流（`direct_source_manager.dart` 的 `_thumbBackfillGap`）错峰首屏渲染（R-8）。测试范式（R-7）：宿主非 ohos 用 `cover_thumb.dart` 模块级 `forceNativeThumbInTests` 开关 + `TestDefaultBinaryMessenger` mock 通道，覆盖缓存切换/静默回退/并发去重/删除生命周期/与补读解耦（`meta_enrich.dart` 的 `unawaited(ensureCoverThumb)` 不等缩略图）
- 缩略图调度链（2026-10-11 ohos-thumb-dispatch-fix feature，前序 `spec/ohos-thumb-taskpool` 契约延续；调度器 `entry/src/main/ets/platform/ThumbDispatcher.ets`，入口声明 `entry/build-profile.json5`，兜底线程 `entry/src/main/ets/workers/ThumbWorker.ets` 协议不变）：
  - **有界并发 + 去重**：`maxInflight=2` 泵动队列，同 `thumbPath` 复用同一在飞 Promise（语义不变）。
  - **首选可恢复**：TaskPool 为「统一单实例 Worker 版」的首选；其健康状态**可恢复**——单次 `taskpool.execute` 失败**不**永久关闭首选，连续失败累计 ≥2（`PRIMARY_FAIL_THRESHOLD`）才临时降级 30s（`PRIMARY_RETRY_DELAY_MS`）并在窗口到期后自动重试，任一次成功即清零失败计数；替代原「单次失败即永久置位 `taskpoolBroken`」（真机取证兜底加载失败 51 次的放大器）。
  - **兜底单实例长驻复用**：降级走**单实例长驻 Worker**——惰性创建至多一次，按请求-应答 **FIFO 串行复用**同一独立线程（`workerQueue` + `workerInFlight` 关联），彻底消除逐任务 `new worker.ThreadWorker`（每 Worker 独立执行环境、创建成本高，即主线程 80% CPU 空转与被强杀的直接来源）。
  - **兜底损坏闩锁（无初始化风暴）**：兜底创建失败 / `onerror` / `onexit` / 反序列化失败即闩锁 `workerBroken`，永久禁用兜底并以 `ok=false` 结算在飞与排队全部等待者，不再「每任务重复初始化 → 必失败」。
  - **零回归**：产物路径/质量、同目标去重、失败静默回原图、`degraded` 标记（`''`/`'worker'`/`'shutdown'`）、`shutdown()` 安全收敛（取消在飞 TaskPool、结算并终止长驻 Worker、不残留 `.tmp`）均与既有一致；Dart（`frontend/lib/**`）与非鸿蒙平台零改动。
- ArkTS 注意（沿用 AVSession 桥经验）：`MethodCall.argument()` 返回 Any，hvigor 拒 Any 推断——PlatformBridge.ets 用 argString/argNumber/argBool 类型化取参；async handler 的 Promise 必须 `.catch((): void => {})` 收口防 unhandled rejection

构建验证状态（2026-09）：
- 双 SDK `flutter analyze` 零问题（ohos 3.41.9 与 stable 各自通过；两 SDK 的 pub get 会对 meta/test_api/vector_math 等 4 个 flutter_test 传递依赖来回改写 lock，属已知无害现象）
- `flutter build hap --debug` 编译链全通：ArkTS（GeneratedPluginRegistrant）+ Dart（kernel_blob JIT）+ `entry/libs` 预编译库（libsqlite3/libsmb2），assembleHap 出 signed hap；release 出包用根目录 `build-ohos.ps1`（`hap` 参数出三架构 arm64/armv7/x86，缺省出 AGC 发布签名 .app）
- 2026-10-22 鸿蒙 6 文件级源：桥/源测试 35 项通过；`build-ohos.ps1` release arm64 出包成功（`frontend/build/dist/SelfMusic_1.0.3_ohos_arm64_release.hap`，SHA256 `84295ecf…`）
- 真机部署已走通：`devecocli signature generate`（签名材料落 `~/.ohos/config/`）→ 出包 → `hdc install -r` / `devecocli run`
- **签名材料不入库**：`devecocli signature generate` 会把本机材料路径写进 `ohos/build-profile.json5`，该文件已 gitignore；仓库只留 `build-profile.json5.example` 模板（新机器复制一份改名即可）
- 启动白屏已修复（两个应用/生态层根因，见上文）：verify-6 全链路点亮，看门狗 1 次 poke 即解除

真机部署步骤：
```powershell
# 0. 真机开启开发者模式 + USB 调试，USB 连电脑（首次连接手机上确认授权弹窗）
# 1. 检查设备识别
devecocli device list
# 2. 自动生成调试签名（需已 devecocli auth login；自动写 ohos/build-profile.json5，
#    材料落在 ~/.ohos/config/：p12/csr/cer/p7b）
devecocli signature generate --product default
# 3. 重新构建（签名就位后 assembleHap 可出包）
flutter-ohos build hap --debug
# 4. 安装并启动（或 DevEco Studio 直接 Run）
devecocli run   # 或 hdc install <hap 路径> 后手动启动
# 5. 远程（锁屏）启动：aa start 报 10106102 (unlock screen failed) 时先唤醒屏幕
#    hdc shell power-shell wakeup
#    hdc shell aa start -a EntryAbility -b com.shamiko.selfmusic
#    注意：无密码锁屏 wakeup 即可放行；安全锁屏（密码/指纹）下 wakeup + uitest 上滑
#    均无效，10106102 仍复现——只能人工解锁设备（2026-09-29 实测）
```

PoC 验收口径（`win10开发机准备.md` §2.4）：空壳 + 直连 WebDAV 浏览 + 本地索引 + 真机点播一首歌；跑不通则按「[风险与开放问题](#风险与开放问题)」R2 降级「仅 WebDAV 直连」。

**验收结论（2026-09-30 全部通过，PoC 转日常使用）**：直连 WebDAV 浏览/扫描/点播 ✓；重复 load 复位（重播同一首）✓；completed→自动切歌 ✓（初版 play 空转无声已修，见「客户端播放要点」）；WebDAV Basic 鉴权 ✓。此外装载看门狗（不可达主机 15s 有界失败）、AVSession 播控、横竖屏、应用图标、宽屏队列面板（无界宽度布局崩溃 + 状态栏让位）均已真机验收。后续问题按普通 bug 修，不再按 PoC 口径管理。

**播放后端替换（2026-10-17 真机验收）**：fvp/libmdk 全量替换为系统 AVPlayer（`just_audio_avplayer.dart` + `AvPlayerBridge.ets`）。P0 全过：自签 HTTPS（Media Kit 不校验证书，自签叶直接可播）、转码流（位置/进度/seek 重载）、明文 HTTP、Authorization 头、SFTP/SMB 回环字节流、AIFF/AIFC/Ogg Opus/hi-res FLAC、fdSrc 本地缓存。HAP 43.0MB → 32.1MB，构建期不再下载 mdk。安全行为变化：HTTPS 播放的 TLS 校验不再由应用掌控（见「鸿蒙适配·关键事实」）。

### 新机接入（团队协作，2026-10）

> 面向只做鸿蒙端的协作者：新电脑 + 新真机 + 共用华为开发者账号。全程约 1-2 小时（大头是 SDK 下载）。前置：已装 DevEco Studio，且「Settings > SDK」里可见 API 26（过低先升级，否则 hvigor 构建失败）。

1. **ohos 分支 Flutter SDK**（独立目录，勿与其它 Flutter 混放）：

   ```powershell
   git clone https://gitcode.com/CPF-Flutter/flutter_flutter.git
   git checkout oh-3.41.9-release
   git checkout 62357a93d653bf844f730bb1f4b7cc9e2139d14e
   ```

   固定 commit：上游分支在动，engine 二进制必须与团队一致（framework 3.41.9 / Dart 3.11.5）。

2. **自建 wrapper**（`*.bat` 不入库，每机一份；路径按本机实际情况修改）：

   ```bat
   @echo off
   set "TOOL_HOME=<DevEco Studio 安装目录>"
   set "DEVECO_SDK_HOME=%TOOL_HOME%\sdk"
   set "HOS_SDK_HOME=%TOOL_HOME%\sdk"
   set "JAVA_HOME=%TOOL_HOME%\jbr"
   set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
   set "PUB_HOSTED_URL=https://pub.dev"
   set "PUB_CACHE=<pub 缓存目录，可省略用默认>"
   set "PATH=%TOOL_HOME%\tools\ohpm\bin;%TOOL_HOME%\tools\hvigor\bin;%TOOL_HOME%\tools\node;%JAVA_HOME%\bin;%PATH%"
   call "<ohos Flutter SDK>\bin\flutter.bat" %*
   ```

   `PUB_HOSTED_URL` 必须直连 pub.dev（CN pub 镜像对 ohos 桩包持续 502）；`FLUTTER_STORAGE_BASE_URL` 是引擎/Dart 工件镜像。

3. **PATH**：wrapper 所在目录 + `%TOOL_HOME%\sdk\default\openharmony\toolchains`（hdc）。

4. **验工具链**：`flutter-ohos doctor`——只看 HarmonyOS toolchain 一行全绿（OpenHarmony SDK / ohpm / node / hvigorw）；Android/Chrome 缺失不影响鸿蒙开发。

5. **取代码并重建本机文件**（`build-profile.json5`、`local.properties` 等被 gitignore，clone 后缺失，必须重建）：

   ```powershell
   git clone <仓库地址>
   cd frontend
   flutter-ohos create --platforms ohos .   # 只补缺失的本机文件，已入库文件不动
   copy ohos\build-profile.json5.example ohos\build-profile.json5
   flutter-ohos pub get                     # 自动把 ohos 插件写进 modules
   ```

   在干净 git 工作区执行，`git status` 复核无意外改动。`local.properties` 首次构建时由工具按 `DEVECO_SDK_HOME` 自动写入，不用手建。

   根目录的出包脚本同样是模板入库、本机私有，一并复制后改工具链路径：

   ```powershell
   copy build-ohos.ps1.example build-ohos.ps1
   notepad build-ohos.ps1        # 改 $Flutter / $DevEco 两个路径
   Unblock-File .\build-ohos.ps1 # 执行策略拦下时先解封，否则用 -ExecutionPolicy Bypass -File
   ```

6. **账号与调试签名（GUI 自动签名，不依赖 devecocli）**：
   - DevEco Studio 登录共用华为账号；
   - 真机开开发者模式 + USB/无线调试连接电脑（无线：手机上看端口，`hdc tconn <ip:端口>`；首连在设备上点允许；端口每次重开无线调试会变）；
   - 打开 `frontend/ohos` 工程 → File > Project Structure > Signing Configs → 勾选 **Automatically generate signature** → 共用账号登录确认。自动生成本机 p12/csr、下载云调试证书、创建调试 Profile，**并把已连接设备自动注册进 AGC 设备管理**；signingConfigs 写入本机 `build-profile.json5`（该文件不入库）；
   - 若报证书/Profile 配额错误（AGC 错误码 205389872 / 205389938）：共用账号下多机多套材料会累积，到 AGC 控制台「用户与访问」清理旧的 auto_debug 调试 Profile 后重试。

7. **构建装机**（与「真机部署步骤」一致）：

   ```powershell
   flutter-ohos build hap --debug
   hdc install -r build\ohos\hap\entry-default-signed.hap
   hdc shell aa start -a EntryAbility -b com.shamiko.selfmusic
   ```

8. **日常**：日志 `hdc shell hilog`（Dart `debugPrint` 进 hilog）；截图/布局树可用 devecocli（可选，需另装 DevEco Code，本流程不依赖）。鸿蒙播放后端已换成系统 AVPlayer，首次构建不再下载 mdk/ffmpeg 预编译库（旧 fvp 方案的 CMake 下载/解压流程已移除）。

团队约定：`build-profile.json5` / `local.properties` / `*.bat` / `*.ps1` / `pubspec.lock` 均本机私有不提交；ohos 平台判断一律 `Platform.operatingSystem == 'ohos'`（「跨 SDK 兼容铁律」）；共用账号的 AGC 调试证书/Profile 有配额，废弃设备与过期 Profile 及时在 AGC「设备管理」清理。

> 仓库里的 `.ps1` 一律 **UTF-8 with BOM + CRLF**：Windows PowerShell 5.1 按 ANSI 读无 BOM 文件，中文注释会被解成乱码并直接报「字符串缺少终止符」。`.gitattributes` 已用 `*.ps1 text eol=crlf` 钉住换行，但 BOM 属于文件内容，clone 后若仍是乱码，检查编辑器是否把 BOM 删了。

---

## 播放算法与同步协议

### 随机播放（加权 / 普通）

设列表 n 首（n≥2）：`基础权重 w₀ = 1/n`，`weight = w₀ × factor`，`factor ∈ [0.5, 1.5]`、连续取值、步长 0.1、初始 1.0；唯一例外是「不喜欢」锁定态——固定 `0.1`（`dislikedFactor`，低于下限、只由手动开关写入）。

```
连续完整播放（like_streak≥3）且中位播放进度达门槛 → factor 提高 0.1（上限 1.5）
连续中断（dislike_streak≥3）→ factor 降低 0.1（下限 0.5；不看中位进度）
liked / 手动喜欢            → factor 直接 1.5（并解除「不喜欢」锁定）
手动不喜欢（开关）          → factor 直接 0.1 并锁定（frozen=true）
frozen=true                 → 权重锁定 0.1，跳过自动调权与时长削弱
选中概率 p_i = factor_i / Σfactor_j（对候选集合归一化；锁定态按 0.1 代入）
```

**中位播放进度（升权第二条线）**：每次离开曲目时按 `position / duration` 记一个最终进度样本（自然结束固定 100%；30%~95% 的离开也采样；时长未知且非自然结束不采样；暂停不采样；同一曲目一次占用只采一次）。每首歌维护 101 桶直方图（0..100%，1% 粒度），全历史中位数即「中位播放进度」。升权时两条线必须同时满足：

| 目标 factor | 中位进度门槛 |
|---|---|
| ≤ 1.0（从低位回升到 1.0） | 不设闸门 |
| 1.1 | ≥ 50% |
| 1.2 | ≥ 55% |
| 1.3 / 1.4 / 1.5 | ≥ 60% / 65% / 70% |

门槛公式 `50 + (目标 factor − 1.1) × 50`（离群档位线性外推）。tracked 事件（complete/skip 带 `progress_pct`、manual 带 `tracked:true`）在样本 <3 条时视为闸门不满足；旧客户端事件没有进度字段 → 不启用闸门，沿用旧单线规则。闸门未过时**保留 streak 不清零**，后续每次完播继续评比，中位达标时立即 +0.1 并清零；`complete_manual` 同样过闸门，失败保留权重与刚累计的 streak（通过才清零）。降权完全不看中位进度。

选歌（加权随机模式）：**并非无放回抽取**——每步从队列**全量**（排除上一首，n≥2 时对剩余归一化）按 factor 采样，喜欢的歌可在一轮中多次、不喜欢的歌可能要若干轮才播一次，无固定「单轮」长度，每步独立随机采样。

普通随机（设置→播放「加权随机」关闭）：**不放回抽取**。池 = 完整基座（锚定列表；非锚定队列退回当前队列）- 深层列表已播身份 - 当前曲；每步在池内均匀抽样。深层列表容量 = 列表长度，自动推进推入末尾；满容量后下一次 `pushPlayed` 清空重来，即一轮结束、池自然重置。轮次状态直接复用深层列表（持久化/同步），不额外维护已抽集合；`prev` 弹出末尾天然回滚。手动点播 / 「下一首播放」等显式覆盖沿用深层列表既有 `replaceTail` / `pushPlayed` 语义（可能替换末尾或重复占用容量，属于显式覆盖）。非锚定普通队列没有深层列表，退化为均匀随机（允许重复）。

**时长削弱**（设置 `>歌曲`：`curve_weight_enabled` + `curve_weight_segments`）：抽样时按歌曲时长乘分段系数 `effective = factor × curve(duration)` 再钳回 [0.5,1.5]；分段作用域 `[min,max)` 命中第一段即止，`max=null` 表示「超过 min 恒生效」，未命中 / 时长未知 = 1.0（不削弱）。**「不喜欢」锁定态例外**：恒 0.1，不乘系数也不被下限钳回。**仅抽样侧即时计算**：不落库、不改 `play_meta`、服务端零改动。

事件规则（后端 `SyncService` 与本地 `db_writer` 严格镜像同一语义，事件经 `song.complete_manual` 等同步）：

| 事件 | 触发 | 效果 |
|------|------|------|
| complete | 自然结束且播放比例 >95% | 先记一条进度样本；like_streak++，dislike_streak=0；非锁定态 like_streak≥3 且中位闸门通过 → factor=min(1.5, +0.1)、streak 清零；闸门未过保留 streak（后续完播继续评比）；锁定态只记 streak 不调权 |
| complete_manual | **用户手动点播**（`_play(manual:true)` 起始）且自然完播 | 不重复采样（前一条 complete 已记）；tracked 时同样过中位闸门；通过 → like_streak=0、dislike_streak=0、factor=min(1.5, +0.1)；失败保留权重与 streak；锁定态不动权重 |
| skip | 被 next/prev/换歌打断且比例 <30% | 先记一条进度样本；dislike_streak++，like_streak=0；非锁定态 dislike_streak≥3 → factor=max(0.5, −0.1)、streak 清零；锁定态只记 streak；降权不看中位进度 |
| progress | 30%~95% 离开 / 补推基线 | `song.progress`：普通样本 progress_pct 只 +1 桶；`baseline:true` 的 progress_hist 按桶 max；不改权重/streak |
| liked | 手动喜欢 / 收藏 | favorite=true，factor=1.5，解除「不喜欢」锁定（frozen=false） |
| unfavorite | 取消喜欢 / 收藏 | favorite=false；非锁定态 factor 回 1.0；锁定态保持 0.1 |
| disliked | 手动不喜欢（开关式） | favorite 不变；开 → factor=0.1 且 frozen=true；关 → 解锁回 1.0 |
| reset | 手动重置 | 双 streak 清零，factor 回 1.0，解除「不喜欢」锁定 |

> `complete_manual` 仅**用户主动选择**（playAt / playQueue / 播放页点行 / 歌单「播放全部」）起始的歌自然完播才计数；`next()`/`prev()`/自动下一首/失败重试均为非手动起点。

播放模式：`sequence`（顺序播放，播完即停）/ `loopList` / `loopOne` / `weighted`（显示「随机播放」，由 `weighted_random_enabled` 决定加权随机 / 普通不放回）；切换入口播放页 + 队列面板；`next()` 与自动下一首按当前模式路由。

**歌单起播**（`startIndexForOrder`）：歌单详情「播放」的起始曲按当前模式决定——随机播放按当前算法抽样（加权开启用 `_weightedPickIndex`；关闭用普通随机，新上下文深层列表为空）、列表循环接续当前曲（末尾回绕）、顺序/单曲循环取首曲；队列本身按歌单当前排序装载（不按模式重排），「从头播放」是显式例外。

**播放统计**：播放次数不单独落库，由**累计播放秒数**派生（`次数 = play_meta.play_sec / duration`）。采集用**挂钟口径**（`DateTime.now` 差值，不采样播放位置，后台/息屏节流不影响），结算点为「暂停 / 切歌 / 退出 / 位置事件」四类，走 `DbWriter.addPlaySec`（写连接内累加）；以 `>=1s` 为有效增量。

**深层列表**（`data/deep_list.dart`，隐藏能力）：锚定列表的「仅可修改末尾值」有界历史栈，容量 = 该列表歌曲总数。手动点播一律替换末尾（不增长）；自动推进（自然播完 / 失败跳歌 / 随机抽样）才推入末尾（超容量视为播完一轮，清空后从当前曲重来）；「上一首」弹出末尾。队列面板形态恒为「深层 ‖ 基座续播段」。不影响「下一首」语义——未来播放顺序仍由队列与随机算法决定；普通随机直接把深层列表当作本轮已播集合（池 = 基座 - 深层）。顺序模式播到队尾则深层清零、从头播放；非锚定普通队列仍收尾停止。

> **写路径**：调权 / 收藏不是「先算再存」，而是由 `applyWeightEvent` 等 op 在**写连接的单个事务内**完成读改写并同时入 `weight_outbox`（见「[客户端同步与缓存批处理](#客户端同步与缓存批处理)」）。

### 同步协议

- **方向**：客户端本地 SQLite 是运行时事实源；后端是多设备汇聚点。
- **Pull**：每 30s `GET /sync/pull?since_cursor=`；cursor 为服务端 `sync_events.seq` 单调递增变更号。快照按实体去重（服务端单页内 + 客户端跨页）：每页只回该页事件涉及实体的**当前快照**；**`breakpoint.set` 只回断点（playstate），不携带歌单条目快照**（稳态流量放大器修复）。断点回调整轮 pull 结束后统一触发一次。
- **断点快路径**：启动 / 回前台先打 `GET /playstates/latest`（1 RTT 直取全局最新断点快照；旧服务端 404 客户端静默回退，全量 pull 仍是兜底）。启动首轮只拉不推（`pullOnly`：先掌握远端再上报积压，推由后续全量轮先推后拉带走；`awaitFirstPull` 等首轮收尾）；套用 single-flight、与首次恢复的异步尾串行。
- **事件日志压缩**：`sync_events` 只追加，服务端按「所有未吊销设备的最小 pull 水位」（`devices.last_pull_cursor`）定期回收旧事件，且**每实体保留最新一条**（`sync_events.entity_key` 锚点）；事件表不随使用时长无限增长，新设备首拉成本从 O(历史事件数) 收敛到 O(实体数)；`entity_key` 为空的旧行不参与压缩。
- **Push**：本地权重事件 / 断点 / 歌单改动 → 写 `weight_outbox`（带 `event_uuid`）→ 2s 防抖批量上推；服务端按 uuid 幂等去重。事件类型（`SyncEventTypes`，前后端同名）：`song.complete / song.skip / song.complete_manual / song.liked / song.unfavorite / song.disliked / song.reset / song.state`（权重）、`song.progress`（进度样本/基线）、`playlist.create|update|delete` 与 `playlist.item_add|item_remove|item_move`、`source.create|update|delete`、`breakpoint.set`（载荷含 `deep_list`；纯追加另带 `deep_added`，位置-only 用空 `deep_added`，非追加带 `base_deep_list`；v2 另带 `protocol:2 + op_id + op_clock + intent + head{session_id,playing,...}`，见「断点协议 v2」）。同一歌单的离线断点事件在 push 前只保留最新一条，旧事件随 ack 清理，避免同一后缀重复追加。歌手身份**不参与同步**。配对前存量补推（权重 `backfill()` / 歌单 `backfill()` / 源自举）带 `backfill:true` 标记：服务端“只建行、不赢现行行”（`create` 已存在判输、`item_add` 已存在条目不覆快照；首配空库照常建）。push/pull 回包带 `server_time`（见下「时钟校准」）。
- **累计播放时长**：`play_sec` 随 `song.state` 上下推，两端一律取 `max(行值, 快照值)` 单调合并（服务端 `mergePlaySec` + 客户端落库同口径），不因乱序 / 旧快照倒退。
- **中位播放进度**：`progress_hist`（101 桶 JSON）只由样本事件累加——complete/skip 载荷的 `progress_pct`、`song.progress` 的普通样本各 +1 桶；配对前存量由 `song.progress` 的 `baseline:true + progress_hist` 补推，按桶 max 合并（不累加）。`song.state` 不携带直方图，避免与样本事件重复计数。pull 歌曲快照带非空 `progress_hist`，客户端按桶 max 合并；本地有该曲未推 `song.*` 事件时既有 pull guard 跳过该曲快照。旧数据无直方图 / 旧客户端无进度字段 → 不启用中位闸门，沿用旧单线规则。
- **冲突（字段级合并）**：权重走**事件重算**（两设备并发点赞按到达序重放，不互抹）；收藏 / 歌单元数据 / 删除墓碑走**行级 LWW**（事件 `occurred_at` vs 行 `last_event_at`，输方收 correction 回执自纠；仲裁时钟为服务端 `arrived_at`）；歌单条目按 seq 到达序重放（后到达胜出）。直接 REST 变更（歌单 CRUD / 断点 PUT / 调权 POST）同样先记事件再生效。**断点当前曲/进度例外**：v2 客户端改由 `head_*` HLC 仲裁（见下条「断点协议 v2」），`last_event_at` 行级 LWW 仅保留给旧客户端 / 旧协议 / `PUT /playstates/{id}`。
- **断点深层列表分支合并**：客户端本地 `breakpoint_sync_base` 记录每个歌单**本机已采用且与服务端确认过**的深层列表；拉取镜像但播放器未采用时不得推进 base，否则本机旧列表会被误判成非追加分支。本地若只是 base 的尾部追加，合并只消费 `deep_added` 后缀，服务端执行 `server + deep_added`；若发生上一首/替换末尾/清空等非追加操作，push 带 `base_deep_list` 走三向列表合并 `C + server[C:] + device[C:]`（`C`=最长公共前缀，身份按 `source_ref`，去重保留最后，超容量只裁最旧端）。`deep_list` 仍随载荷携带：服务端首写/旧行无历史时用全量兜底，无合并回执时客户端用它确认 base。服务端在结果与来件不同时于 push 回包 `merged`（按 event_uuid 键控）返回完整快照；位置-only 事件在服务端历史与来件不同时也回 `merged`。客户端即使 `device_client_id` 是自己也强制落镜像，非当前歌单只落镜像并抑制自动套用；当前歌单只更新历史/融合队列、不 seek、不打断播放，base 按本机实际采用结果推进。合并时钟取 `max(现行 last_event_at, 来件 occurred_at, 服务端 now)` 且严格大于两边，避免对端镜像时钟拒收；历史未变但接受了当前曲/进度时时钟只前进不回退。
- **断点协议 v2（head/history 分离，最后一次真实操作赢）**：服务端先升级，客户端从 pull/push/latest 回包看到 `breakpoint_protocol: 2` 后切 v2（旧服务端无该字段继续走 legacy，旧客户端忽略新字段）。v2 把断点拆成「当前播放头 head」与「深层历史 history」：
  - **head 仲裁**：真实播放操作（`play_track/pause/resume/seek`）才产生 head 操作，携带设备侧 HLC `op_clock`（`wall-counter`，服务端按认证 `clientId` 补设备维度后比较 `wall-counter-device`）与唯一 `op_id`；服务端单调保留时钟最大的操作，判输方不再回 correction 弹窗/回退，直接在 push 回包 `breakpoints` 里看到权威快照。`progress` 心跳只允许当前 `head_device`、同 `head_session`、同曲上报，只刷新位置/播放态与 `head_rev`，**不推进 `head_clock`/`head_op_id`/`head_session`**——否则一次心跳会把时钟推高，令另一台设备稍后到达的真实操作被误判为旧。
  - **history 合并**：`history_rev` 只随深层列表变化递增；head 判输时历史合并照常执行，离线两端新增内容都不丢（继续复用「断点深层列表分支合并」的三向合并）：`play_track` 被接受时把当前曲补到历史尾部并递增 `history_rev`；容量溢出只从最旧端裁剪。
  - **客户端状态机**：按歌单持久化 `applied_head_rev`/`applied_history_rev`/`pending_head_op_id`/`session_id`/`server_epoch`。真实操作写 pending head；启动恢复、周期保存、回前台/退后台补写不是真实操作，只发 `progress` 或不发，绝不产生 head（恢复装载也不再借 `pushPlayed` 改写历史）。pending 期间 pull 的远端 head 一律 defer，直到 push 回执裁决（接受 / 判输 / 死信清 pending 后，由 `applyNewerMirrorIfAny` 在空闲时套用；播放中绝不打断）。`server_epoch` 变化时清空本地 revision（镜像内容保留），防 DB 重建后旧高版本挡新快照。
  - **回执与镜像**：`breakpoints` 按 `playlist_uuid` 键控（旧 `merged` 仍按 `event_uuid`），客户端无条件落 `breakpoint_mirror`；镜像写入按 `head_rev`/`history_rev` 分别守卫，旧 head 不回退当前曲/进度，旧 history 不回退深层列表，`force` 只绕墙钟不绕版本。merged/历史-only 快照只更新深层历史与融合队列，**不 seek、不打断播放**；非当前歌单只落镜像并抑制自动套用。
  - **兼容**：`last_event_at`/`updated_at`/`deep_list` 字段保留；旧协议路径（无 `protocol` 或 `<2`）继续走行级 LWW + 分支合并，服务端对旧行回填 `head_rev=history_rev=1`（`V3__breakpoint_head_v2.sql`），保证首次升级即可比较版本。
- **时钟校准**：`occurred_at` 是各设备墙钟入队时间，偏移会导致 LWW 误判旧赢新。push/pull 回包带 `server_time`，客户端记 `skew = serverTime - now` 并修正后续入队时间戳（`LocalIndex.setClockSkew`，唯一入队口；旧服务端无该字段退化为本地钟）；修正值回跳时本机单调 guard 兜住（新戳不得小于上次 +1ms）。skew 内存态，重启后下次同步重建。
- **歌曲身份**：服务端无曲库，统一为 `source_id + source_ref`（source_id=客户端源实例 uuid，旧数据为 `legacy:<协议>`）；权重 / 收藏落 `song_states`，歌单条目与断点自持身份及展示快照（pull 不覆盖客户端本地标题）；pull 身份收集恒不建行（已删歌曲不重新建行）。未配对（无后端地址）或 `sync_enabled=0` 时直连事件不进队，避免 outbox 无限积压。
- **播放源同步**：`source.create/update/delete` + 行级 LWW；身份 `client_uuid`，去重键 `(kind, address)`（地址两端归一化——WebDAV 缺 scheme 补 https、去尾斜杠，SFTP 形态 `host:port/path`；转码强校验按同一归一化匹配）。本地文件夹源不参与；密码与私钥（含 passphrase）不入服务端（新设备显示「待配置密码」）；SFTP 主机密钥钉 `ssh_known_hosts` 亦不参与同步（各设备各自 TOFU）。存量远端源接入时补 uuid 并补发一次 create；旧协议级身份在设备重新上报时由服务端懒迁移。删除是**软删墓碑**（`deleted=1` 留行，供 LWW 与去重键延续）；同址重新添加（新 uuid 撞旧行）时复用该行并**清回 `deleted=false`**，否则该源在服务端永远不可见、别机收不到它回来。
- **删源清理范围**（本机删除与别机同步删除同一口径，`LocalIndex.deleteSource` + `_opDeleteSource` 单事务）：远端文件一律不动；本地清 `sources` / `idx_songs` / `playlist_items`（先按歌单补发 `playlist.item_remove`）/ `artist_song_map` / `play_meta`（权重·收藏·播放进度）/ `song_lyrics` / `cache`（**先删真实文件再删登记行**，删不掉就留行给 LRU 淘汰）/ `source_line:<key>` 与 `source_created_folders_<key>` 两条按源设置；`deep_lists` 各锚定栈按 `sourceKey` 过滤（剔空整行删，该源自身的 `source:<key>` 锚定直接删）、`play_state.queue_json` 同步过滤并修正 `idx`（当前曲被删落到其后第一首存活曲，剔空则删行=无断点）。运行态由 `PlayerProvider.onSourceRemoved` 收口（队列/融合基座/预载槽/深层历史同步剔除；当前曲属于该源则按「删当前曲」续播，无存活曲则收尾停止），`DirectSourceManager.onSourceRemoved` 是两条路径（本机 `removeSource` 与同步 `reloadSourcesFromIndex` 对账）的唯一出口，SecretStore 凭据（主源 + 两个备用槽的 WebDAV/SFTP/SMB）两条路径都会清。
- **跨设备断点消费**：`breakpoint.set` 快照带来源设备与最后操作时间；客户端 pull 落 `breakpoint_mirror`（自写回声过滤，见上）。v2 同一歌单按 `head_rev` 是否前进判断「谁更新」，跨歌单/legacy 仍按比较时钟（`last_event_at ?? updated_at`，v2 行优先 `head_updated_at`）；本机有未确认 pending head 时先不上远端。启动恢复与歌单「播放全部」在远端更新时自动从该进度续播并 toast；目标歌本机无源时退到其后第一首可播条目，全不可播则回落本机恢复。远端赢家只要本机还在播就不打断，等暂停/回前台/下轮同步再套用；深层历史照常先合并。
- 直连模式（无服务器）：上述全部跳过，数据只在本机。

### 歌手身份聚合（MusicBrainz 后台解析）

纯客户端本地能力，不参与跨设备同步。歌曲标签里的歌手名（括号 / 分隔符 / 大小写差异 / NFKC 变体）经身份管线归一到唯一 `artist_key`，再对 MusicBrainz 后台解析出正式名、别名、角色与乐队成员，用于歌手页聚合。

- `ArtistResolver`（`services/artist_resolver.dart`）：MB 搜索选型 + 按 MBID lookup，单次 `inc=artist-rels+aliases`；匹配分（`match_score`）、disambiguation、按年过滤；`1 req/s` 令牌桶节流、`error_count/next_at` 指数回退、`networkDown` 标记。
- 状态机：pending → local（未解析）→ resolved（命中 mbid）→ ambiguous（多名候选）；成员经 `artist_member` 关系图**递归展开**（Group→Character→Person，成员即 resolved）。
- 落库：`artists / artist_canon / artist_song_map / artist_member`（见「[数据模型](#数据模型)」客户端表）。
- 入口：歌曲播放补读时顺带析出歌手 → 后台循环批量解析；侧边栏「信息」页展示解析进度；「强制解析」可重拉已解析歌手。
- 与同步、扫描互不影响：身份结果纯本地，不随 `weight_outbox` / `idx_songs` 上报。

---

## 配置说明

### .env（Docker Compose 读取，勿提交真实密码到公共仓库）

| 变量 | 说明 | 默认 |
|------|------|------|
| `DB_HOST` | MySQL 所在宿主机内网 IP | 无 |
| `DB_PORT` | MySQL 端口 | 3306 |
| `DB_NAME` | 库名 | selfmusic |
| `DB_USERNAME` | 数据库用户 | shamiko |
| `DB_PASSWORD` | 数据库密码 | 无 |
| `PAIRING_TOKEN` | 配对密钥（可选；每次启动覆盖写入，改后重启生效，仅影响新设备；留空则首次随机生成） | 首次随机 |
| `CACHE_MAX_MIB` | 服务端缓存建议上限（单位 MiB；每次启动换算成字节覆盖写入 `settings.cache_max_bytes`，非法/缺省时沿用旧值、库中无则落 5 GiB） | 5120 |
| `CACHE_SONG_LIMIT` | 服务端缓存建议上限（首数；每次启动覆盖写入 `settings.cache_song_limit`，非法/缺省时沿用旧值、库中无则落 200） | 200 |

> 配对密钥查看：① 后端**首次启动**日志以 `WARN` 打印一次；② 已配对设备 `设置 → 服务端 → 配对服务器`（副标题遮显同一份密钥，配对页明文可复制）。

### application.yml 关键项

- 容器内应用监听 8080，对外经 Compose 映射为 18088
- Hikari 连接池：最大 20、最小空闲 5
- devtools 热重载已开启，监控 `src/main/java`
- 业务配置（`LOCAL_MUSIC_ROOT` / `WEBDAV_*` 等出流代理为**历史死配置**，后端已零引用；缓存建议值来源 = `CACHE_MAX_MIB`/`CACHE_SONG_LIMIT` env 镜像）见 [settings.md §5 服务端全局设置](settings.md)；服务端已无 `SCAN_*` 扫描 env（扫描只在 APP 侧）

### Nginx

`nginx/selfmusic.conf` 为模板：`api.selfmusic.local` → `127.0.0.1:8080`。
若走容器后端请把 `proxy_pass` 改为 `127.0.0.1:18088`。修改后：

```bash
sudo nginx -t && sudo nginx -s reload
```

---

## 常见问题排查

### 1. IDE 报 "Failed to init ct.sym ... jrt-fs.jar"

JDK 版本与项目 `java.version` 不一致导致。本项目已统一为 **21**：
确认 IDE 使用 JDK 21（VS Code: `java.jdt.ls.javahome` / Java 扩展运行时设置），然后刷新 Maven 项目。

### 2. "Maven Dependencies references non existing library ..."

依赖没下载全。执行：

```bash
mvn dependency:go-offline -f backend/pom.xml
```

然后在 IDE 里 reload Maven project。若 `.m2` 有损坏的缓存，删除对应目录后重试。

### 3. Docker build 拉取镜像超时（dial tcp ... i/o timeout）

Docker Hub 网络不通。解决方案任选：
- 配置国内镜像加速器（`/etc/docker/daemon.json` 的 `registry-mirrors`）
- 或使用代理：`systemctl edit docker` 设置 `HTTP_PROXY/HTTPS_PROXY` 后 `systemctl restart docker`

### 4. 容器连不上宿主机 MySQL

依次检查：
1. `.env` 的 `DB_HOST` 是否为宿主机**内网 IP**（不是 localhost）
2. MySQL 是否监听外网：`bind-address` 需为 `0.0.0.0` 或内网 IP
3. 用户授权范围需含 `%` 或 Docker 网段：`SELECT host FROM mysql.user WHERE user='xxx';`
4. 防火墙是否放行 3306：`sudo ufw status`

### 5. 端口冲突

- 宿主机 8080 被占用？Compose 已改用 18088，无需处理
- 本地直跑想换端口：`SERVER_PORT=9090 mvn spring-boot:run`

### 6. JPA 启动报 validate 校验失败

实体字段与表结构不一致。核对 `backend/src/main/resources/db/migration/V*.sql` 与 entity 类的字段名/类型/可空性；先看 Flyway 是否执行失败，再临时用 `ddl-auto: none` 启动排查。

---

## 风险与开放问题

| # | 风险 | 影响 | 缓解 |
|---|------|------|------|
| R1 | SMB 移动端 FFI 稳定性 / ohos libsmb2 交叉编译与打包 | 真机不可用 | 全平台统一 `dart_smb2`（FFI libsmb2），ohos 手工打包 `libsmb2.so`（DevEco NDK，见 `third_party/dart_smb2/PATCHES.md`）；`smb_connect` 仅作历史备用；残余风险靠真机验收覆盖 |
| R2 | 鸿蒙三方 Flutter 分支平台通道兼容 + pub 插件生态缺口 | 鸿蒙端可用性 | **已验证可控**：核心依赖全部落地（AVPlayer 播放桥 / secure_storage 双层适配 / sqlite3 随包 / path_provider 重试 / audio_session / AVSession 替代 audio_service）；仅 `cached_network_image`（sqflite 传递依赖缺失）曲库封面降级为已知问题（依赖仍声明锁定、代码零 import，封面走本地 `CoverThumb`/`image` 包 + ohos `makeCoverThumb` 桥） |
| R3 | WebDAV 服务端差异（PROPFIND 深度 / 鉴权 / 限流） | 个别云盘不可用 | 连接测试按钮 + 超时重试封装 |
| R4 | 直连扫描耗流量 / 电量 | 用户感知差 | 仅 Wi-Fi 扫描开关；增量指纹（size/mtime/etag）跳过未变文件；快速只建索引扫描零读头；补读走严格 Range（按结构定位，不整读）；单源上限 20k |
| R5 | ffmpeg 容器 CPU 占用 | 多设备并发卡顿 | 全局并发上限默认 2；超限降级透传 / 回落直连 |
| R6 | 大曲库查询性能 | 列表慢 | 索引齐备；`q` 前缀匹配；预留 FTS 开关 |
| R7 | 公网暴露 | 曲库 / 上传被滥用 | Bearer 认证已是第一道门；文档仍建议叠加 IP 白名单 |
| R8 | 转码流 position 精度（VBR） | 转码后 VBR 断点 ±2s | 文档注明；CBR 精确 |
| R10 | SFTP 密钥与主机信任 | 私钥外泄误伤、中间人 | 私钥文本只存本机 SecretStore，代理转发时内存态单次使用、不记日志不落盘；主机密钥 TOFU（首认弹窗 + 变更加锁拒绝）；服务端不存 known_hosts，凭客户端信封指纹校验 |

> 待拍板项已全部收敛：上传落点可配 / 服务端定时扫描 / 封面两档（均随服务端曲库移除作废）；`hard=true` 仅限 local 源为默认；`frozen` 以「不喜欢」开关形式暴露。

---

## Git 约定

- 分支：`main`（稳定）、`dev`（集成）、`feature/xxx` 功能分支
- 提交信息：仓库现状多用「模块 + 中文短句」的简短描述（如 `歌单数据接入：...`）；也可用 `feat:`/`fix:`/`chore:` 前缀风格，如 `feat: 新增歌单接口`。一条提交做完一件事
- 不要提交：`.env.local`、`build/`、`.dart_tool/`、`.fvm/`、IDE 私有配置（`.gitignore` 已覆盖大部分）
- 远端：推荐推送至自建 **Gitea**（局域网私有仓库），四端代码同仓管理；如启用 FVM，`.fvmrc` 入库可保证各构建机 Flutter 版本一致
