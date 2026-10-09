# SelfMusic 开发者文档

本文档面向项目开发者，是**开发落地的主文档**：环境搭建、构建矩阵、日常流程、常用命令、客户端实现要点（SQLite 写隔离 / 扫描 / 同步）、调试排查。

文档分工：

| 想知道 | 看哪 |
|--------|------|
| 快速跑起来、服务与端口 | [README.md](README.md) |
| **怎么开发、代码怎么写、改完怎么验证** | **本文** |
| 为什么这么设计、数据模型 / API 契约 / 播放算法 / 路线图 | [DESIGN.md](DESIGN.md) |
| 设置项键名、默认值、入口、生效范围 | [settings.md](settings.md) |

原则：**机制与取舍留在 DESIGN，写代码时必守的规则与命令留在本文**，同一段实现细节只写一处。

---

## 目录

- [环境要求](#环境要求)
- [项目结构](#项目结构)
- [后端开发](#后端开发)
- [前端开发](#前端开发)
  - [平台收口层](#平台收口层libplatform)
  - [客户端播放要点（装载/切歌/返回）](#客户端播放要点装载切歌返回)
  - [客户端本地数据层（SQLite 写隔离）](#客户端本地数据层sqlite-写隔离)
  - [客户端扫描与元数据](#客户端扫描与元数据实现要点)
  - [客户端同步与缓存批处理](#客户端同步与缓存批处理)
  - [鸿蒙适配](#鸿蒙适配)
- [数据库规范](#数据库规范)
- [配置说明](#配置说明)
- [常见问题排查](#常见问题排查)
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

> **平台开发原则**：Linux 与 Android 同步开发、进度对齐（详见 DESIGN.md §8 顶部约定）——本矩阵只给结论，原因与验收口径在 DESIGN 里。

| 目标平台 | 构建环境 | 状态 |
|---------|---------|------|
| Android | 本机 Ubuntu（Android Studio + SDK） | ✅ 环境就绪；壳工程已重建（`android/app` + Gradle 配置齐全），`flutter build apk` 可出包，双端（Linux/Android）对齐开发 |
| Linux Desktop | 本机 Ubuntu（clang + GTK + cmake + ninja） | ✅ 当前主力平台（UI/主题/播放器/鉴权已落地） |
| Web | 不做 | ❌ 明确排除 |
| Windows Desktop | Win10 开发机：Flutter stable + VS2022 Build Tools（C++ 桌面负载 + ATL） | ✅ 已就绪：`flutter build windows` 可出包；音频后端 media_kit；日常联调用根目录 `run-windows.bat` |
| HarmonyOS | Win10 开发机：DevEco Studio + HarmonyOS SDK + 真机 + 三方 Flutter 分支（`oh-3.41.9-release`） | ✅ PoC 验收通过（2026-09-30）：真机点播 / 启动白屏修复 / AVSession 媒体播控 / 横竖屏 / 应用图标 / 自动切歌 / 装载看门狗 / 宽屏队列面板全链走通，真机日常使用中；详见「鸿蒙适配」 |

### 环境搭建顺序

**现在（本机 Ubuntu）：**
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

**Windows 构建网络三坑（新机器必读）：**
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
│       └── resources/application.yml
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
│   │   ├── data/deep_list.dart       # 深层列表：锚定列表的「仅可改末尾」有界历史栈（见 DESIGN §7.1）
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
│   ├── third_party/               # vendored fork：fvp（ohos 平台声明 + 删 video_player 依赖链）、audio_service（通知栏 5 键自定义按钮）
│   └── pubspec.yaml
├── scripts/init.sql                  # 数据库初始化脚本（v2 schema + 阶段5 sync_events / playlists.client_uuid+deleted+last_event_at / play_states.last_event_at）
├── scripts/migration_003_sync.sql    # 存量库补表/补列（阶段5；新部署只需 init.sql）
├── nginx/selfmusic.conf              # Nginx 反代模板（部署到宿主机）
├── docker-compose.yml                # backend（18088）+ backend-dev（18089，profile: dev）
├── run-linux.sh                      # Linux 快速运行：cd frontend && flutter run -d linux
├── run-android.sh                    # Android 快速运行：flutter run -d <设备id> --dart-define=API_BASE_URL=<后端>
└── .env                              # 数据库连接等敏感配置（不入库）
```

**分层约定**：`Controller → Service → Repository`，Controller 只做参数校验和响应封装，业务逻辑放 Service。

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

原理：容器里跑 `mvn spring-boot:run`，你的 `backend/src` 和 `~/.m2` 直接挂载进容器
（UID 1000 一致，读写权限无障碍）。**改完代码不需要重新 build 镜像**；只有换 JDK/Maven 版本或新增依赖才需要
`docker compose --env-file .env build backend-dev` 重建。

### 方式 B：本地直跑

```bash
# 1. 导出数据库连接环境变量（值与 .env 一致）
export DB_HOST=192.168.x.x DB_PORT=3306 DB_NAME=selfmusic \
       DB_USERNAME=<你的用户名> DB_PASSWORD='<密码>'

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

1. 在 `domain/entity/` 建 JPA 实体（对应 `scripts/init.sql` 中已存在的表；**手写 getter/setter**，equals/hashCode 基于 id）
2. 在 `domain/repository/` 建接口继承 `JpaRepository`
3. 在 `service/` 写业务逻辑
4. 在对应功能包（`auth/`、`sync/`、`playlist/`…）暴露 REST 接口，路径以 `/api/v1/` 开头
5. 写测试到 `src/test/java`

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
| just_audio_media_kit（+ media_kit_libs_linux / media_kit_libs_windows_audio） | 桌面音频后端（Linux/Windows 统一 libmpv，库随包分发，`main()` 中 `ensureInitialized()` 注册） |
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

- `ohos_bootstrap.dart`：`setupOhos()` 在 `main()` 里 `runApp` 前调用，装配六件事——sqlite3 `open.overrideForAll`（顶层函数，isolate 安全）、`FlutterSecureStoragePlatform` 桩、`JustAudioPlatform` fvp 适配、path_provider 重试包装、HTTPS 根证书注入、`WakelockPlusPlatformInterface` 常亮平台实现（2026-10）
- `just_audio_fvp.dart` / `secure_storage_ohos.dart`：音频后端与安全存储的 ohos 实现
- `ohos_platform_bridge.dart` / `wakelock_plus_ohos.dart`（2026-10）：系统能力平台桥 Dart 封装（常亮/本地文件/蓝牙，见「鸿蒙适配·系统能力平台桥」）
- 平台判定统一用 `Platform.operatingSystem == 'ohos'`（stable 工具链没有 `Platform.isOhos` getter，见「[鸿蒙适配](#鸿蒙适配)」）
- 其余平台差异目前靠条件导入式的一层封装（`just_audio` 默认 Android 走 ExoPlayer、桌面走 media_kit），尚**未**抽成统一 `capabilities` 接口——新增平台能力时优先考虑在 `lib/platform/` 补齐
- 少数确实需要平台判断的调用点（音频焦点、通知栏）以 `Platform.isAndroid` 门控，并在注释里说明「ohos 走降级路径」；常亮 / 本地文件夹源 / 蓝牙设备查询已由平台桥支持 ohos（2026-10），对应调用点改为 `isOhos` 分支

### 客户端本地数据层（SQLite 写隔离）

> 机制背景（为什么有这层）见 [DESIGN.md §3.2](DESIGN.md#32-客户端sqlite)；本节是**写代码时必守的规则**。

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
- **数据迁移在写隔离 `init` 里跑**：历史 `play_meta` 的 `ENCODE(ref)` 脏值由 `migrateMetaRefs` 在开连接时修一次（幂等）
- **平台差异**：写隔离是独立 isolate，拿不到主 isolate 的 `open.overrideFor`（测试正是靠它注入），因此 `_openWriterDb` 自己解析 `libsqlite3`——Linux 依次试 `libsqlite3.so` / `libsqlite3.so.0`（发行版常只有后者）

测试约定：写是异步的，断言落库结果前先 `await index.flushWrites()`；组件测试里用 `settleWriter(tester)` 辅助冲刷写队列（`test/playlists_view_test.dart` / `test/song_tile_test.dart`），不要靠固定 `Future.delayed` 猜时间。

### 客户端扫描与元数据（实现要点）

> 扫描方式与指纹语义见 [DESIGN.md §6.4](DESIGN.md#64-直连模式本地轻量索引)；本节只记**写代码时必守的隔离与数据规则**。

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
  另有 `duration_format_test`（时长 mm:ss/h:mm:ss）、`lrc_parser_test`（歌词解析）、`song_title_format_test`（标题格式）、`play_reconcile_test`（播放前最新行纠正）、`top_bar_search_test`（搜索追焦）、`view_mode_settings_test`（集合页视图持久化）、`playlist_membership_test`（歌单归属/切换）与 `playlists_view_test` 等
- 历史坑：mp3 enc==3 / flac VORBIS_COMMENT 曾用 `String.fromCharCodes` 逐字节解码导致 CJK 乱码——已改 UTF-8 解码；修复后需对已有源重扫一次覆写旧行（`upsert` 无条件覆盖 title/artist/album，无需删库）

**读头部的多段策略（`data/local/audio_metadata.dart`）**

- **结构化阶梯读（`readAudioMeta`，播放补读与后台补读共用同一函数）**：首段采样（256KB）→ `coverReadHint` 按**文件自己声明的长度**（mp3 的 ID3v2 synchsafe 总长 / flac 元数据块的 24 位块长）给出「读到封面块尾」所需字节数，跳过去再解析。不够就继续阶梯，直到 `coverReadHint` 返回 null（结构上到头）或触到 `kMetaRegionCapBytes` = 16MB。歌词（USLT / LYRICS）与长文本帧同在整段标签内，随阶梯一并补全
- **两条补读驱动**：(1) **结构跳**——按声明长度精确落点；(2) **几何放大（×4）**——结构上算不出落点时。典型是 FLAC 的 `PICTURE` 排在 `VORBIS_COMMENT` 之前：读完封面块标题还在更后面；ogg/opus 的段表在读完段表之后才知道 payload 落在哪，采样截断时同样只能放大
- **`coverReadHint` 返回 null = 结构上到头**，此时不再放大：mp3 标签读完 / flac 块列表走到 last 块 / ogg comment 包完整 / 无结构可循的格式（m4a 的 moov 在文件尾，走尾部阶梯，不在头部放大到上限）
- **绝不整读**：没有「采样不足就从 0 读到 fileSize」的退路（旧实现有 `fullRead`，在后台逐首补读链路上为拿几个标签把几十上百 MB 整首下下来，且命中的恰恰是大文件）。单次读取上限 `kMetaRegionCapBytes` = 16MB，是**声明值**的合理性边界，不是文件大小上限
- **尾部补读 `tailReadHint`**：moov-at-end 的 m4a（按 256KB→1MB→4MB 逐级放大，上限同上）、ogg/opus 时长（取末页 granule）、无 ID3v2 的 mp3 ID3v1（取尾 128B）、**wav/aiff 的尾随 `id3 ` 块**（见下）
- **wav / aiff / aifc（RIFF/FORM 容器）**：这两种容器没有官方标签规范，工具把 ID3v2 塞进一个 `id3 ` 块（RIFF/FORM 块 id 是 4 字节 ASCII，wav 块长小端、FORM 块长大端），位置也不固定（ffmpeg `-write_id3v2 1` 写在音频块**之后**）。`tailReadHint` 按音频块（`data`/`SSND`）**声明的长度**跳过音频，算出后面元数据区的长度并一次读准，不碰音频数据；尾读窗口解析 `id3 `（复用 mp3 那套 ID3v2 帧/APIC 解析）与 `LIST INFO`。老设备常把 RIFF 总长或 `data` 声明写错，块列表对不上时兜底在窗口内扫 `id3 ` 标记并按 ID3v2 头自己声明的长度严格校验，避免把音频数据里巧合的字节误当标签。aiff 另解析 `COMM` 的采样帧数与 80 位扩展浮点采样率算时长，`NAME`/`AUTH` 兜底标题/歌手
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

### 客户端同步与缓存批处理

- **先落库再上报**：调权 / 收藏 / 歌单 / 断点先写本地（`applyWeightEvent` 在写连接内原子读改写并同时入 `weight_outbox`），再由 `SyncEngine` 推送——**不要**在 UI 回调里直接调 API
- **outbox 幂等**：每条事件带 `event_uuid`，服务端按 uuid 去重；直连歌曲**未配对或 `sync_enabled=0` 时不入队**，避免无限积压
- **推拉节奏**：`SyncEngine` 2s tick 推增量、30s 拉增量、失败指数退避（上限 30s）、首帧后启动做一次增量校准。启动/回前台先走 `GET /playstates/latest` 断点快路径（1 RTT，旧服务端 404 静默回退），启动首轮 `pullOnly` 先拉后推（积压 outbox 下一 tick 补推），pull 每页断点落库即 flush 回调。**首帧轻量化**：`sync.start()` / `direct.attachApi()` / `ArtistResolver.start()` 统一在 `main()` 的 post-frame 回调里启动，不参与首帧渲染
- **同步后台化（写隔离收口）**：outbox 读取 + `jsonDecode`（`pendingOutbox`/`pendingOutboxCount` op）、pull 快照的字段映射与落库（`applySongSnapshotsRaw` / `applyPlaylistSnapshots` / `applyPlaystateMirror`）、断点歌单存在性判定，全部在写隔离（`db_writer`）内完成；UI isolate 只 `await`。**ohos 例外**：无子 isolate，内联写按 200 行/事务分片、片间 `await` 让出事件循环（`_InlineDbWriter.opBatch`）；cursor 在整页应用后才推进，中途失败靠重拉幂等收敛
- **跨页去重**：服务端只在单页内按实体去重，`_pull` 按 `source_id|ref` / uuid 跨页去重，重复快照只计数不重复落库
- **落库回调帧末投递**：`onSourcesApplied/onSongStatesApplied/onPlaylistsApplied` 经 `scheduleAfterFrame`（`utils/frame_scheduler.dart`）推迟到帧末；歌单回调携带本轮变更 uuid，`PlaylistsProvider.refresh(changedUuids:)` 只重查变更歌单计数（避免同步一次 N+1 全量重查）；源 watcher 仅在本地源 key/rootPath 真变化时重建
- **拉到的快照走 `apply*Snapshot` op**：身份收集恒不建行（已删歌曲不复活）；远端断点落 `breakpoint_mirror`，不直接改运行时 `play_state`
- **缓存写入攒批**：WebDAV 缓存下载按 1MiB（`_cacheWriteBufBytes`）攒够再落临时文件，成功后 `cacheCommit` 换入正式路径并更新 `cache` 表——避免逐 chunk 小写入；`persistCover` 同样先写临时文件再改名，保证重复扫描幂等
- 同步协议语义（LWW / 事件重算 / 歌曲身份 / 断点不牵连歌单快照 / 事件日志压缩）见 [DESIGN.md §7.2](DESIGN.md#72-同步协议)

### 桌面音频后端（media_kit）

Linux / Windows 桌面统一 `just_audio_media_kit`（底层 libmpv）：libmpv 由 `media_kit_libs_linux` / `media_kit_libs_windows_audio` **随包分发，无需系统安装 mpv**。`main()` 顶部 `JustAudioMediaKit.ensureInitialized()` 完成注册（默认参数 Windows/Linux 启用、Android 关闭走 ExoPlayer）。

> 历史注：pubspec 里的 `just_audio_mpv`（0.1.7）从未接线（无 import、无初始化），已删除；Linux 桌面播放随 media_kit 真正接通。

### 客户端播放要点（装载/切歌/返回）

- **装载前置鉴权探针**：原生装载器（fvp/ExoPlayer）对 401/403 错误响应只会无限缓冲，进度停 0:00 且无任何提示（2026-09-29 密码过期真机实测）。`_loadOnce` 在 setUrl 前先发 1 字节 Range 探针（`MusicSource.probe`，与取流路径同口径）：401/403 立即失败提示，其余探针异常忽略后继续装载（网络抖动交给播放器重试）
- **装载看门狗（2026-09-30）**：mdk/mpv 对「主机不可达/无响应」的 open 没有应用层超时——真机实测 IPv6 路由丢失时 mdk prepare 永久挂起，UI 卡 00:00/00:00、点播放无响应。setUrl 统一裹 15s 超时（`PlayerProvider._loadUrlTimeout`），超时按装载失败进入 `loadBackoff` 退避重试、耗尽后走失败提示/自动跳曲；被放弃的迟到结果用 `Future.ignore()` 吞掉防 unhandled。ExoPlayer 自带连接超时通常先报错，对 Android 无感
- **自动切歌 play 空转坑（2026-09-30）**：just_audio 的 `play()` 首行 `if (playing) return`——上一首自然播完 playing 不会自动复位，装载下一首后 `play()` 静默空转、平台层收不到播放指令。ohos 表现为切歌无声 + 进度条靠 Dart 时钟插值假走（暂停时回跳 0）；Android 靠 ExoPlayer `playWhenReady` 跨装载持久而侥幸正常。修复在 `PlayerProvider._play`：装载完成需要播放时先 `pause()` 复位 playing 再 `play()`——**勿删勿"优化"**，详见该处注释
- **返回手势 = 转后台**：移动端侧滑/返回键不退出应用（后台续播），收口在 `platform/app_background.dart`（Android 通道 `com.shamiko.selfmusic/app`、ohos 通道 `selfmusic/app`，均为 `moveToBackground`），`main.dart` 的 `_onPopInvoked` 是唯一调用点、通道失败兜底原行为；桌面端恒 false。调整退出行为只动这两处

### 鸿蒙适配

工具链：`CPF-Flutter/flutter_flutter` 三方分支 `oh-3.41.9-release`（Dart 3.11，与 stable 并存，独立 wrapper 切换）+ DevEco Studio（ohpm/hvigor/node）+ 真机联调（Windows 上无模拟器）。壳工程 `frontend/ohos/` 已由 `flutter create --platforms ohos .` 生成。

插件审计结论（2026-09，pub.dev 实测）：

| 依赖 | ohos 方案 | 状态 |
|------|-----------|------|
| path_provider | `path_provider_ohos` 2.2.1 + 超时重试包装（保险层：1s 超时 × 5 次重发 + 沙盒回退；旧"引擎吞回复"根因已被实测翻案，见下节） | ✅ 直接用 + 保险 |
| file_selector | 备份导入导出直接用；本地文件夹源「选择目录」的 `getDirectoryPath` 在 `file_selector_ohos` 未实现（调用必抛异常）→ ohos 改走平台桥 `pickDirectory`（DocumentViewPicker FOLDER + fileShare 持久化，见「系统能力平台桥」） | ✅ 分场景处理 |
| **just_audio（音频后端）** | **fvp**（libmdk 后端，官方支持 HarmonyOS 5.0+）+ 自写纯 Dart 适配层 `just_audio_platform_interface` → fvp Player，无 ArkTS | ✅ 已实现（`lib/platform/harmonyos/just_audio_fvp.dart`） |
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
- WebDAV 直连鉴权只有 `Authorization: Basic` → 适配层解码回 user:pass percent-encode 折进 URL userinfo（FFmpeg 原生承载，mdk 不支持自定义请求头）；`DirectAudioSource` 字节流（just_audio 内建 localhost 代理）为兜底，三种音源形态（file://、https://+Basic、127.0.0.1 代理）都到达 `ProgressiveAudioSourceMessage` 统一处理
- fvp 构建期经 CMake 从 sourceforge 下载 mdk 预编译库（可用 `FVP_DEPS_URL` 环境变量换镜像）；libmdk.so/libfvp.so/libffmpeg.so 打入 hap，ohos FFI 加载层已内置。实测下载成功：libfvp.so 2.8MB + libmdk.so 2MB + libffmpeg.so 7.4MB（arm64-v8a）
- flutter 工具自动把带 ohos 模块的插件写入 `ohos/build-profile.json5` modules 与 har overrides，无需手工接线
- fvp 用 vendored 副本 `frontend/third_party/fvp`（ohos-only 平台声明 + 删除 video_player 依赖链），升级 = 重新复制 0.38.1 源码 + 重打两个补丁（见该目录 pubspec.yaml / lib/fvp.dart 头部注释）

适配层实现（`lib/platform/harmonyos/`，2026-09）：
- `ohos_bootstrap.dart`：`setupOhos()` 在 `main()` 里 runApp 前调用，六件事全部仅 ohos 生效——sqlite3 overrideForAll（顶层函数，**仅本 isolate 有效**：不随 Isolate.spawn 传入子 isolate，ohos 写层因此退化内联，见 `db_writer.dart` 头注释）、`FlutterSecureStoragePlatform.instance = OhosSecureStorage()`（包级注册只覆盖平台侧，前端类另需绕过，见上表）、`JustAudioPlatform.instance = FvpJustAudio()`、`PathProviderPlatform.instance = OhosRetryingPathProvider(原实现)`（单点收口：启动链全部路径调用均经该 instance）、`SecurityContext` 根证书注入（`_loadRootCerts`）、`WakelockPlusPlatformInterface.instance = OhosWakelockPlusPlatform()`（2026-10，常亮见下节）
- `path_provider_ohos_retry.dart`：1s 超时 × 5 次重发的保险包装 + 全超时沙盒路径回退（命中时日志 `[ohos] path_provider.* 响应超时`）；旧"引擎竞态吞回复"根因已被 verify-5/6 逐消息对账翻案（见下节），保留理由：路径查询幂等、成本为零、覆盖未证实的极端时序
- `just_audio_fvp.dart`：`FvpJustAudio.init/disposePlayer` 管理播放器表；`FvpAudioPlayer` 实现负载面 load/play/pause/seek/setVolume（+speed/loop 顺带），pitch/shuffle/skipSilence 静默 no-op；mdk 状态映射：`prepare()<0` 抛 PlatformException、`state=stopped` 且非加载复位/错误 → `completed`（自动切歌依赖）、`MediaStatus.invalid`/`onEvent error` → 错误上报、位置用 200ms Timer 轮询（mdk 无位置流）、同一媒体重复 load 前先回 stopped 复位（mdk prepare 对已加载返回 -1）；音量两侧语义一致（0.0-1.0）；mdk prepare 对不可达主机**无超时**——应用层看门狗兜底（见「[客户端播放要点](#客户端播放要点装载切歌返回)」）
- `secure_storage_ohos.dart`：文档目录单 JSON 文件 + 整文件 base64 混淆，内存即权威源；读写失败不抛（密钥问题不崩登录/配对流程）；对应 platform_interface 1.1.2 Map-options 签名（flutter_secure_storage 9.2.4 锁定该版本，`*Params` API 是 1.2+ 才有，勿混淆）

启动白屏根因（2026-09 真机取证定稿）：两颗应用/生态层地雷，引擎无辜。

> 翻案史：最初据"启动早期平台消息无回复"假设引擎竞态吞回复（~130ms 窗口），据此写了超时重试包装。verify-5 逐消息对账推翻该假设——**67 条 FlutterNapi 回执无一丢失**，引擎消息通道全程正常；旧取证里"挂起的 documentsPath 调用"其实来自 `OhosSecureStorage._ensureLoaded`，回复本身送达了，死的是其后的前端读取。重试包装保留为无害保险层。

**白屏故障模型**（两颗雷都"只是抛异常"，为何表现为永久白屏 + 零日志）：

- **白屏 = 渲染从未开始**：ArkTS 侧窗口/Surface 早已建好，内容全靠 `runApp()` 挂载组件树后才有人画；而 `main()` 的全部初始化都在 runApp 之前逐个 await——**链上任何一环抛异常，其后代码（runApp、markBootReady）全部不执行**
- **僵尸态**：Dart 的 async 异常只终止 `main()` 这个 Future 的续体，**不退出 isolate**——事件循环、平台通道、已注册回调全部存活。verify-5 铁证：看门狗 60 次 poke 全被 Dart 收到并处理，而 markBootReady（位于 runApp 之后）永不触发；进程健在 → 系统无理由弹崩溃框 → 活进程 + 永远空白的窗口
- **零日志**：fork 启动早期未捕获异常的 stderr→hilog 转发缺失——verify-1~5 全文检索 Unhandled/UnsupportedError 为 0 命中，但异常确定抛出（修复后同一行代码立即复活）；只能靠间接痕迹定位（雷① 看消息对账断在哪条回执后；雷② 看 MUSL-LDSO 行）
- **同类前科**：Android 时代通知服务异常拖垮启动（`main.dart` "曾致白屏" 注释，修法 try/catch）——同一故障类别，鸿蒙两雷只是死得更隐蔽
- **死亡链**（函数级定位，修复后回溯验证）：雷① `main()` 的 `await ServerSettings.load()` → `server_settings.dart` load() 内 `secret.pairingKey()` → `secret_store.dart` 直通 `storage.read` → 前端 `_selectOptions` throw；雷② `main()` 的 `await direct.init()` → `local_index.dart` 索引库 `sqlite3.open` → override 的 `DynamicLibrary.open('libsqlite3.so')` → dlopen errno=2

- **雷① flutter_secure_storage 前端类在 ohos 直接 throw**：上游 9.2.4 的 `_selectOptions()` 对 ohos 不在预置平台表内时无条件抛错，且 `_platform` 是逐调用 getter——包级注册平台实例救不了前端。启动链 `ServerSettings.load()` 读配对密钥时 Future 链**静默断裂**（无 Unhandled/UnsupportedError 日志）。修复：`OhosFlutterSecureStorage` 子类覆写 write/read/containsKey/delete/readAll/deleteAll 六入口直调平台实例 + `createSecureStorage()` 工厂收口（`secret_store` / `api_client` / `theme_provider` 三处构造点）；`server_settings.load()` 另加读失败按未配对继续的兜底
- **雷② libsqlite3.so 缺失**：sqlite3 包在 ohos 走 `DynamicLibrary.open('libsqlite3.so')`，而设备系统 7 个候选路径全无此库、DevEco SDK 无、`sqlite3_flutter_libs`（0.5.42）只有 android/darwin/linux/windows 目录。`direct.init()` 内 dlopen 失败同样**静默死亡**，唯一线索是 hilog 里应用 pid 的 `MUSL-LDSO: load libsqlite3.so failed ... errno=2` 三行。修复：自编译 musl 版 .so 随包分发（配方见下）
- **静默死亡取证方法学**（下一颗雷照此排）：① `main()` 全链 `[boot]` 里程碑 debugPrint；② ArkTS 启动看门狗（`EntryAbility.ets` 每 1000ms poke，Dart 侧 `markBootReady()` 解除——未解除即 main 未走完）；③ hilog 逐消息对账：发送 = `DartMessenger --> Received message from Dart over channel '...'`，回复 = `FlutterNapi --> called handlePlatformMessage ... Response ID`；④ 原生库加载失败只看应用 pid 的 `MUSL-LDSO` 行（系统进程噪音极多）；⑤ 疑似卡死时 `hdc fport` + VM service 取栈
- **libsqlite3.so 构建配方**（sqlite.org 官网 Download 页 amalgamation 包，当前 3.53.4；产物 NEEDED 仅 libc.so——musl 全并入 libc，无需 -lm/-ldl）：

  ```powershell
  # <DevEco> = DevEco Studio 安装目录；升级 sqlite 版本时照抄换源码即可
  & "<DevEco>\sdk\default\openharmony\native\llvm\bin\clang.exe" `
    --target=aarch64-linux-ohos "--sysroot=<DevEco>\sdk\default\openharmony\native\sysroot" `
    -march=armv8-a -fPIC -shared -O2 -D__MUSL__ '-Wl,-soname,libsqlite3.so' `
    sqlite3.c -o frontend/ohos/entry/libs/arm64-v8a/libsqlite3.so
  ```

  hvigor 自动把 `entry/libs/arm64-v8a/` 打进 hap（与 fvp 的 .so 同机制），应用 dlopen 按名命中包内副本
- 上游反馈（待办）：① flutter_secure_storage 支持 ohos（`_selectOptions` 放行或官方 ohos 分支）；② `sqlite3_flutter_libs` ohos 移植
- **验证（verify-6）**：启动引导 → 服务端设置加载完成 → db-writer 内联就绪 → 直连源就绪 → 进入 runApp → 看门狗解除，全链 1.4s 点亮；进程存活无崩溃标记，FlutterView 持续输出 `Display on` / `avoidAreaChangeCallback`（视图真实渲染非白屏）

其他鸿蒙配置事实（2026-09 收尾两连修，真机已验收）：

- 横竖屏：module.json5 abilities 的 `orientation` 字段 **fork 模板默认缺失 = 窗口不随传感器旋转**（与 Android manifest 无 screenOrientation 的行为不一致，勿想当然）；补 `"orientation": "auto_rotation"` 即放行（Flutter 侧 `player_screen.dart` 横屏分支本就存在，纯配置层问题），控制中心旋转锁定关闭时横屏 UI 正常触发。HAP 内 module.json 可明文核对该字段
- 应用图标：`AppScope/resources/base/media/app_icon.png` + `entry/src/main/resources/base/media/icon.png` 两个文件（模板默认 = Flutter 默认图 144×144），直接覆盖内容即可，`$media:app_icon`/`$media:icon` 引用与资源 ID 不动；图标源 `frontend/assets/selfmusic.png`（1277×1287 满铺圆角+透明四角）整幅缩放 288×288，非等比畸变 0.8% 不可见

通知栏媒体播控（AVSession 桥，2026-09-29 真机验收）：

- 形态差异：鸿蒙没有 Android 式应用自绘媒体通知，媒体卡由系统统一渲染（通知栏/锁屏/播控中心三处），第三方只能喂 `AVSession` 数据、不能自定义布局；接入 AVSession 后后台长时任务的常驻通知也被 AVSession 接管，**不会**再出一条"播放中"通知——媒体卡本身就是鸿蒙的通知形态
- 架构（与 audio_handler 同构的非劫持薄转发）：`AvSessionBridge.ets`（通道 `selfmusic/avsession`，生命周期 create→元数据+播放态+命令注册→activate→`backgroundTaskManager` AUDIO_PLAYBACK 长时任务；destroy 收卡）+ `ohos_media_session.dart`（Dart 全量 sync 推送）+ `PlayerProvider.attachSystemMediaSync` 挂 `_syncSystemMedia` 既有时机；direct 监听补推收藏与内嵌歌词晚到
- int 映射（ArkTS 侧 switch 显式映射防非法值）：播放态 playing?2:3（`PlaybackState.PLAY=2/PAUSE=3`）；LoopMode sequence→0（LOOP_MODE_SEQUENCE）/loopOne→1（**SINGLE**）/loopList→2（**LIST 非 ALL**）/weighted→3（SHUFFLE）
- 歌词：AVMetadata.lyric 只收内嵌 LRC 文本，服务端 40960 字节上限，Dart 侧按 UTF-8 40000 截断后下发
- module.json5：backgroundModes 必须写在 **abilities[] 条目内**（`"backgroundModes": ["audioPlayback"]`；三重证据：官方属性表/modulecheck 白名单/FAQ），配 `ohos.permission.KEEP_BACKGROUND_RUNNING`（system_grant 免 reason）
- **封面（两段式，2026-09-30 定稿）**：元数据先行（卡片秒出，缺封面显示应用图标），封面异步解码后经第二次 `setAVMetadata` 补推。此前踩坑：`mediaImage` 传裸路径/`file://` string 时 `isImageValid checkFail`（av_session 服务进程读不了应用沙箱路径）→ `980000502`，**单字段校验失败会阻断整个播控卡**；PixelMap 方案首轮又因过早 release 触发 `GetMediaImageTopic checkFail`。定稿要点：coverPath 传应用沙箱绝对路径，ArkTS 侧 fd→ImageSource→PixelMap 进 IPC 共享内存；PixelMap **保持引用至替换完成才 release**；同曲按路径去重、快速切歌用任务票据竞态淘汰过期解码（`AvSessionBridge.ets` 的 updateCover/decodeCover）
- ArkTS 坑：`MethodCall.argument()` 返回 Any，hvigor 编译器拒 Any 推断（`arkts-no-any-unknown`，**hvigor 比 arkts_check 严**）——用 argString/argNumber/argBool 类型化取参
- 验收（2026-09-29 真机）：卡片三处出现/播放暂停上一首下一首真控制/循环模式双向同步 ✓；收藏/后台持续/歌词因 WebDAV 服务器内容缺失暂无法验收（环境问题非回归：歌单同步正常证明主服务器 API 在线，WebDAV 扫描 0 首+流缓冲无声）；启动链零回归（桥就绪与看门狗同毫秒，Dart ready 1.65s）

系统能力平台桥（`selfmusic/platform`，2026-10 ohos-permissions feature；2026-10-06 ohos-thumb-native-decode feature 扩封面缩略图原生管线）：

- 缘起：常亮（wakelock_plus 桩不兼容）、本地文件夹源选目录（`file_selector_ohos` 无 getDirectoryPath）、蓝牙设备查询（Android 专有通道）三项在 ohos 均无可用插件实现——统一自建平台桥，装配范式同 AVSession 桥：ArkTS 侧 `entry/src/main/ets/platform/PlatformBridge.ets`（EntryAbility configureFlutterEngine 装配 / onDestroy 回收），Dart 侧 `ohos_platform_bridge.dart` 封装，业务层只在 `isOhos` 分支调用；后补第四项：封面缩略图原生解码（见下「封面缩略图」，fork 引擎无子 isolate、纯 Dart 编码卡 UI）
- 10 方法契约（前 9 个唯一事实源：`spec/ohos-permissions/plan.md`「Contracts & Interfaces」；makeCoverThumb：`spec/ohos-thumb-native-decode/plan.md`）：keepScreenOn / pickDirectory / activateDirectory / listDirectory / readRange / requestBluetoothPermission / hasBluetoothPermission / listBondedDevices / connectedDevices / makeCoverThumb
- 本地文件夹源（US1）：module.json5 申请 `FILE_ACCESS_PERSIST`（system_grant 免弹窗免 reason）；选目录 = `picker.DocumentViewPicker` FOLDER 模式 + 当场 `fileShare.persistPermission`（**持久化必须趁选择器临时授权存活的同一会话内完成**，临时授权随应用退出清除；重复选择同一目录幂等处理——persistPermission 失败用 checkPersistentPermission 复核）；重启后扫描前 `activatePermission` 激活（持久化数据在系统数据库，每次启动需手动激活）；扫描 = `fs.listFile(recursion)` + 逐文件 `fs.stat` 全量快照，**主 isolate 执行不走 runScan**（授权 URI 非 dart:io 路径，且桥 handler 在主 isolate）——过滤/指纹 diff 复用 `local_direct_source.dart` 的 `_diffSnapshotEntry` 公共纯函数，isolate 路径行为逐字节不变；点播 = `cachedFilePath` 返回 null → DirectAudioSource 字节流兜底，`fs.read` 512 KiB 分块拉流（ArkTS 侧单次上限 2 MiB 防御，读取不完整按 13900030 error 上抛）；授权失效（撤销/目录删除）统一转译「目录授权已失效，请编辑该源重新选择目录」。ref 形态注意：库内 song ref 存无头相对路径（对齐 Android），桥 readRange 封装负责补 `/` 头再拼 URI
- 常亮（US2）：`window.setWindowKeepScreenOn`（无需权限声明，仅前台生效；退后台随窗口失焦自动失效是系统预期，回前台由播放器页按播放态重新拉起）；Dart 侧 `OhosWakelockPlusPlatform`（wakelock_plus_ohos.dart）注册进 `WakelockPlusPlatformInterface.instance`（setupOhos 第六件事），player_screen 的 ohos guard 移除、常亮门控逻辑全平台统一
- 蓝牙（US3）：module.json5 申请 `ACCESS_BLUETOOTH`（user_grant，`$string:bluetooth_permission_reason` + usedScene，base/zh_CN/en_US 三处 string.json 同步）；FR-009 启动期零权限——仅「常亮限定设备」设置页触发三段式申请（`requestPermissionsFromUser` 已授权短路 → 未授权走 `requestPermissionOnSetting` 设置弹框兜底，两次拒绝后只能引导去系统设置）；查询 = `connection.getPairedDevices` / `getRemoteDeviceName` + `a2dp.getConnectedDevices`（均同步 API + try/catch，蓝牙未开启 2900001 等异常一律降级空集合——与 Android「按未连接判定」的静默降级语义一致，`bluetooth_service.dart` 四方法 `isOhos` 分支收口）
- 封面缩略图原生管线（2026-10-06 ohos-thumb-native-decode feature）：列表缩略图原为纯 Dart `image` 包 `runOffThread` 编码——**fork 引擎无子 isolate、ohos 上 runOffThread 内联主 isolate**，打开应用触发存量封面回填时逐张数百 ms UI 块（全局卡顿根因，spec R-1）。下沉为 `makeCoverThumb`（第 10 个通道方法）：ArkTS 侧 `@ohos.multimedia.image` 全链完成——fd→ImageSource 解码 → EXIF orientation 映射 rotate/flip 烘焙 → 最长边 768 降采样（90°/270° 注意 desiredSize 按旋转后语义换算宽高、绝不放大）→ JPEG q82 重编码 → `<thumbPath>.tmp` 写盘后 rename 原子替换；**缩略图字节不过通道**（Dart 只收 bool），读盘/解码/编码/写盘全在系统原生线程。失败纪律（R-5）：参数缺失/解码失败/超时（Dart 侧 15s）/任何异常一律 `result.success(false)` 静默回原图，**绝不回退内联 Dart 编码**（卡顿源不能复活）；`ensureCoverThumb` 的 ohos 分支复用既有 `_thumbInflight` 去重与 `_displayPathCache`/`_thumbReady` 缓存，非 ohos 代码路径字节不变（零回归）。启动回填配 50ms 逐张节流（`direct_source_manager.dart` 的 `_thumbBackfillGap`）错峰首屏渲染（R-8）。测试范式（R-7）：宿主非 ohos 用 `cover_thumb.dart` 模块级 `forceNativeThumbInTests` 开关 + `TestDefaultBinaryMessenger` mock 通道，覆盖缓存切换/静默回退/并发去重/删除生命周期/与补读解耦（`meta_enrich.dart` 的 `unawaited(ensureCoverThumb)` 不等缩略图）
- ArkTS 坑（沿用 AVSession 桥经验）：`MethodCall.argument()` 返回 Any，hvigor 拒 Any 推断——PlatformBridge.ets 用 argString/argNumber/argBool 类型化取参；async handler 的 Promise 必须 `.catch((): void => {})` 收口防 unhandled rejection

构建验证状态（2026-09）：
- 双 SDK `flutter analyze` 零问题（ohos 3.41.9 与 stable 各自通过；两 SDK 的 pub get 会对 meta/test_api/vector_math 等 4 个 flutter_test 传递依赖来回改写 lock，属已知无害现象）
- `flutter build hap --debug` 编译链全通：ArkTS（三插件 GeneratedPluginRegistrant）+ native（libfvp.so/libmdk.so arm64-v8a）+ Dart（kernel_blob JIT），assembleHap 出 signed hap；release 出包用根目录 `build-ohos.ps1`（`hap` 参数出三架构 arm64/armv7/x86，缺省出 AGC 发布签名 .app）
- 真机部署已走通：`devecocli signature generate`（签名材料落 `~/.ohos/config/`）→ 出包 → `hdc install -r` / `devecocli run`
- **签名材料不入库**：`devecocli signature generate` 会把本机材料路径写进 `ohos/build-profile.json5`，该文件已 gitignore；仓库只留 `build-profile.json5.example` 模板（新机器复制一份改名即可）
- 启动白屏已修复（两颗应用/生态层地雷，见上）：verify-6 全链路点亮，看门狗 1 次 poke 即解除

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

PoC 验收口径（`win10开发机准备.md` §2.4）：空壳 + 直连 WebDAV 浏览 + 本地索引 + 真机点播一首歌；跑不通则按 DESIGN §9 R2 降级「仅 WebDAV 直连」。

**验收结论（2026-09-30 全部通过，PoC 转日常使用）**：直连 WebDAV 浏览/扫描/点播 ✓；fvp 重复 load 复位（重播同一首）✓；completed→自动切歌 ✓（初版 play 空转无声已修，见「客户端播放要点」）；WebDAV Basic 鉴权折叠被 FFmpeg 接受 ✓。此外装载看门狗（不可达主机 15s 有界失败）、AVSession 播控、横竖屏、应用图标、宽屏队列面板（无界宽度布局崩溃 + 状态栏让位）均已真机验收。后续问题按普通 bug 修，不再按 PoC 口径管理。

### 新机接入（团队协作，2026-10）

> 面向只做鸿蒙端的协作者：新电脑 + 新真机 + 共用华为开发者账号。全程约 1-2 小时（大头是 SDK 下载）。前置：已装 DevEco Studio，且「Settings > SDK」里可见 API 26（过低先升级，否则 hvigor 构建失败）。

1. **ohos 分支 Flutter SDK**（独立目录，勿与其它 Flutter 混放）：

   ```powershell
   git clone https://gitcode.com/CPF-Flutter/flutter_flutter.git
   git checkout oh-3.41.9-release
   git checkout 62357a93d653bf844f730bb1f4b7cc9e2139d14e
   ```

   固定 commit：上游分支在动，engine 二进制必须与团队一致（framework 3.41.9 / Dart 3.11.5）。

2. **自建 wrapper**（`*.bat` 不入库，每机一份；路径换成自己的）：

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

8. **日常**：日志 `hdc shell hilog`（Dart `debugPrint` 进 hilog）；截图/布局树可用 devecocli（可选，需另装 DevEco Code，本流程不依赖）。首次构建 fvp 经 CMake 从 sourceforge 下载 mdk 预编译库（约 12MB，arm64-v8a），网络受限时设 `FVP_DEPS_URL` 换镜像。

团队约定：`build-profile.json5` / `local.properties` / `*.bat` / `*.ps1` / `pubspec.lock` 均本机私有不提交；ohos 平台判断一律 `Platform.operatingSystem == 'ohos'`（「跨 SDK 兼容铁律」）；共用账号的 AGC 调试证书/Profile 有配额，废弃设备与过期 Profile 及时在 AGC「设备管理」清理。

> 仓库里的 `.ps1` 一律 **UTF-8 with BOM + CRLF**：Windows PowerShell 5.1 按 ANSI 读无 BOM 文件，中文注释会被解成乱码并直接报「字符串缺少终止符」。`.gitattributes` 已用 `*.ps1 text eol=crlf` 钉住换行，但 BOM 属于文件内容，clone 后若仍是乱码，检查编辑器是否把 BOM 删了。

---

## 数据库规范

### 服务端 MySQL

- 表结构变更：**修改 `scripts/init.sql` 并同步提交**，同时更新对应 JPA 实体；`application.yml` 中 `ddl-auto: validate` 会校验实体与表结构一致性，不一致启动即报错
- 字符集统一 `utf8mb4`
- 所有表带 `id BIGINT AUTO_INCREMENT PRIMARY KEY`、`created_at`、`updated_at`
- 初始化脚本中的用户创建语句已注释（由管理员手工管理账号），执行前确认账号存在且对 `selfmusic.*` 有权限

### 客户端 SQLite

- 表清单与设计意图见 [DESIGN.md §3.2](DESIGN.md#32-客户端sqlite)，权威定义在 `lib/data/local/schema.dart` 的 `applySchema()`：**改表只改这里**，主读连接与写隔离各跑一遍，幂等（`ALTER TABLE` 先 `PRAGMA table_info` 探测）
- 无 `created_at/updated_at` 统一约定；时间列按需命名（`last_scan_at` / `cached_at` / `updated_at`）
- 写必须走写隔离（见「[客户端本地数据层](#客户端本地数据层sqlite-写隔离)」），不要在主 isolate 直接 `db.execute` 写语句（**例外：ohos**——`DbWriter` 在 ohos 退化内联写：sqlite override 不进子 isolate + fork 引擎子 isolate 可靠性存疑，见「鸿蒙适配」与 `db_writer.dart`）
- 歌曲身份统一 `(source_key, song_ref)` 复合键；收藏状态只认 `play_meta.is_favorite`（旧 `idx_songs.is_favorite` 仅一次性回填）

---

## API 规范

> 完整端点清单、认证细节与**已实现/规划**标注见 DESIGN.md §4。这里只留写代码常用的三条：
>
> - 路径前缀 `/api/v1/`，资源名用复数（`/api/v1/playlists`）
> - 除 `/api/v1/health`、`/api/v1/auth/pair`、`/api/v1/auth/refresh` 外均需 `Authorization: Bearer <access_token>`；access 过期返回 `401 + X-Token-Expired: true`，客户端懒刷新
> - 响应统一包一层 `{ "code": 0, "message": "ok", "data": ... }`；`4xx` 客户端错误，`5xx` 服务端错误

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

实体字段与表结构不一致。核对 `scripts/init.sql` 与 entity 类的字段名/类型/可空性，或临时用 `ddl-auto: none` 启动排查。

---

## Git 约定

- 分支：`main`（稳定）、`dev`（集成）、`feature/xxx` 功能分支
- 提交信息：仓库现状多用「模块 + 中文短句」的简短描述（如 `歌单数据接入：...`）；也可用 `feat:`/`fix:`/`chore:` 前缀风格，如 `feat: 新增歌单接口`。一条提交做完一件事
- 不要提交：`.env.local`、`build/`、`.dart_tool/`、`.fvm/`、IDE 私有配置（`.gitignore` 已覆盖大部分）
- 远端：推荐推送至自建 **Gitea**（局域网私有仓库），四端代码同仓管理；如启用 FVM，`.fvmrc` 入库可保证各构建机 Flutter 版本一致
