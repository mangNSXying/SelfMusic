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
  - [客户端本地数据层（SQLite 写隔离）](#客户端本地数据层sqlite-写隔离)
  - [客户端扫描与元数据](#客户端扫描与元数据实现要点)
  - [客户端同步与缓存批处理](#客户端同步与缓存批处理)
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
> 鸿蒙（HarmonyOS NEXT）：Flutter 官方不支持，经三方分支 `CPF-Flutter/flutter_flutter`（`oh-3.41.9-release`）适配；工具链已就绪、PoC 进行中，详见「鸿蒙适配」一节。

### 多平台构建矩阵

不同平台的最终产物必须在对应操作系统上构建，一台 Ubuntu 无法完成全部：

> **平台开发原则**：Linux 与 Android 同步开发、进度对齐（详见 DESIGN.md §8 顶部约定）——本矩阵只给结论，原因与验收口径在 DESIGN 里。

| 目标平台 | 构建环境 | 状态 |
|---------|---------|------|
| Android | 本机 Ubuntu（Android Studio + SDK） | ✅ 环境就绪；壳工程已重建（`android/app` + Gradle 配置齐全），`flutter build apk` 可出包，双端（Linux/Android）对齐开发 |
| Linux Desktop | 本机 Ubuntu（clang + GTK + cmake + ninja） | ✅ 当前主力平台（UI/主题/播放器/鉴权已落地） |
| Web | 不做 | ❌ 明确排除 |
| Windows Desktop | Win10 开发机：Flutter stable + VS2022 Build Tools（C++ 桌面负载 + ATL） | ✅ 已就绪：`flutter build windows` 可出包；音频后端 media_kit；日常联调用根目录 `run-windows.bat` |
| HarmonyOS | Win10 开发机：DevEco Studio + HarmonyOS SDK + 真机 + 三方 Flutter 分支（`oh-3.41.9-release`） | 🔶 PoC 进行中：工具链 / ohos 壳 / pub get 就绪，桩接线与音频适配层实施中（验收口径见 `win10开发机准备.md` §2.4） |

### 环境搭建顺序

**现在（本机 Ubuntu）：**
1. Flutter（系统安装即可；FVM 可选）+ Linux toolchain
2. Android Studio + Android SDK + 接受 license
3. VS Code + Flutter/Dart 扩展
4. Git（项目已纳入 git 管理）
5. （可选）FVM：`fvm use stable` 生成 `.fvmrc` 入库

**暂时不需要：**
- Chrome / Web SDK（不做 Web）

**平台扩展（进行中）：**
- Windows 出包 → ✅ 已就绪（Win10 机器，VS2022 Build Tools + ATL 补装）
- 鸿蒙 → Win10 机器上并行推进 PoC（DevEco Studio + SDK + 真机）；Ubuntu 上**不要**装鸿蒙 SDK

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
│   ├── android/ linux/ windows/ web/ # 各平台壳工程（安卓壳已重建）
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
| audio_service | Android 通知栏 / 后台播放（前台服务 + 媒体通知，`SelfMusicAudioHandler` 自定义处理器） |
| crypto | 缓存 key / 封面等哈希去重 |
| sqlite3 / sqlite3_flutter_libs | 客户端本地库（`data/local/`）：源索引 idx_songs + cache + play_meta + playlists + app_settings + song_lyrics + play_state；读写分离与事务合批见「[客户端本地数据层](#客户端本地数据层sqlite-写隔离)」 |
| xml | WebDAV PROPFIND XML 解析 |
| file_selector | 备份导入导出、本地文件夹源「选择目录」 |
| permission_handler | Android 本地文件夹源运行时权限（READ_MEDIA_AUDIO / READ_EXTERNAL_STORAGE） |

### 平台收口层（`lib/platform/`）

跨平台代码里**不要在业务层写 `Platform.isAndroid` / `Platform.isLinux` 之类判断**：鸿蒙走三方 Flutter 分支，官方 target 的 `Platform` 行为与原生插件实现都可能不一致。平台差异统一收敛到 `lib/platform/<target>/`，启动时由该平台的 bootstrap 装配，新增平台只补一个目录、不动上层。

现状（`lib/platform/harmonyos/`）：

- `ohos_bootstrap.dart`：`setupOhos()` 在 `main()` 里 `runApp` 前调用，装配三件事——sqlite3 `open.overrideForAll`（顶层函数，isolate 安全）、`FlutterSecureStoragePlatform` 桩、`JustAudioPlatform` fvp 适配
- `just_audio_fvp.dart` / `secure_storage_ohos.dart`：音频后端与安全存储的 ohos 实现
- 平台判定统一用 `Platform.operatingSystem == 'ohos'`（stable 工具链没有 `Platform.isOhos` getter，见「[鸿蒙适配](#鸿蒙适配poc)」）
- 其余平台差异目前靠条件导入式的一层封装（`just_audio` 默认 Android 走 ExoPlayer、桌面走 media_kit），尚**未**抽成统一 `capabilities` 接口——新增平台能力时优先考虑在 `lib/platform/` 补齐
- 少数确实需要平台判断的调用点（音频焦点、wakelock、通知栏）以 `Platform.isAndroid` 门控，并在注释里说明「ohos 走降级路径」

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

> 扫描模式与指纹语义见 [DESIGN.md §6.4](DESIGN.md#64-直连模式本地轻量索引)；本节只记**写代码时必守的隔离与数据规则**。

- 扫描在独立 Isolate 运行（`data/sources/scan_worker.dart` 的 `runScan`）：入口函数只收可序列化的原始参数
  （HTTP 客户端 / DB 句柄 / `LocalIndex` 等**不得跨 isolate 发送**）；指纹表由主 isolate 在 `scan()` 前查好以 `Map<String,Object?>` 传入
- 增量指纹键 `(ref, size, mtime, etag)`：WebDAV 从 PROPFIND 的 `getlastmodified`/`getetag`/`getcontentlength` 解析；
  `scanFingerprint` 主 isolate 查询一次传入，避免 worker 碰 DB
- WebDAV 列表与探测分别并发（`_mapConcurrent` 并发 6 / 本地探测并发 4）；单文件探测失败不拦截整个扫描
- 结果回主 isolate 后统一 `upsertSongs`（**整批单事务**，走 `op('upsertSongs', …)`；同步快照批量用 `opBatch('applySongSnapshots', …)`）+ `persistCover` + `markMissingExcept` + `clearMissing`；
  `LocalIndex` 只允许主 isolate 访问，写全部转发写隔离
- `upsertSongs` 的覆盖保护：用户手改过（`user_edited=1`）的标题/歌手/专辑不被扫描覆盖；浅扫描解析出的空值不覆盖已存值；只有本次解析出时长才标 `meta_read`
- 自动扫描：本地 `Directory.watch(recursive)` 变化去抖 2s 触发 `scanSource(key)`；周期定时器按 `scan_auto_interval_min` 轮询全部直连源；`_inFlightScan` 全局互斥防重复扫描
- 播放时懒补全：`PlayerProvider._enrichLazily` 只在 `duration == null` 时读头解析并 `enrichSong` 回填，失败静默
- 测试：`test/webdav_scan_test.dart` 用真 `HttpServer`（PROPFIND/GET/Range + 可变 etag）验证跨 isolate 扫描、增量跳过与 etag 变化仅重探目标文件；`test/audio_metadata_test.dart` 覆盖头部越界与大封面边界；
  另有 `duration_format_test`（时长 mm:ss/h:mm:ss）、`lrc_parser_test`（歌词解析）、`song_title_format_test`（标题格式）、`play_reconcile_test`（播放前最新行纠正）、`top_bar_search_test`（搜索追焦）、`view_mode_settings_test`（集合页视图持久化）、`playlist_membership_test`（歌单归属/切换）与 `playlists_view_test` 等
- 历史坑：mp3 enc==3 / flac VORBIS_COMMENT 曾用 `String.fromCharCodes` 逐字节解码导致 CJK 乱码——已改 UTF-8 解码；修复后需对已有源重扫一次覆写旧行（`upsert` 无条件覆盖 title/artist/album，无需删库）

**读头部的多段策略（`data/local/audio_metadata.dart`）**

- **两段读**：首段采样（256KB）解析后若缺封面，`coverReadHint` 按 ID3 标签声明长度 / FLAC 块头 / ogg comment 包完成度算出「读到封面块尾」所需字节数，补读一次再解析；上限 `kCoverReadCapBytes` = 8MB（高清扫图常见 1~3MB，一段读会整块丢失）。歌词（USLT / LYRICS）与长文本帧同在整段标签内，随两段读一并补全
- **尾部补读 `tailReadHint`**：moov-at-end 的 m4a（按 256KB→1MB→4MB→8MB 逐级增大）、ogg/opus 时长（取末页 granule）、无 ID3v2 的 mp3 ID3v1（取尾 128B）
- 扫描 `full` + 提取封面走 `readAudioMeta` 统一读序；旧版已标已读但无封面的 mp3/flac 行由一次性迁移（`kCoverReenrichV1Done`，设备本地标记）重置为未读，交给后台补读重取
- **同目录回退**：仍无封面 → 「同名图片（`.png/.jpg/.jpeg/.webp`）→ `cover.*`/`folder.*`/`front.*`/`album.*`」顺序取同目录图片（播放补读按会话缓存，扫描按目录清单/下载缓存去重），经图片签名校验后落盘；同名 `.lrc` 歌词回退同在一条路径
- **编码规则**：mp3 ID3v2 按帧 encoding 选解码（enc==3 → UTF-8；enc==0 → 尝试 UTF-8 再回退 Latin-1）；flac/ogg VORBIS_COMMENT 按规范 UTF-8（失败回退 Latin-1）；m4a 文本原子 UTF-8；无内嵌标签时走文件名/同目录回退
- **时长探测**：mp3 估算法（文件大小÷码率）或解析 Xing/VBRI 头；flac 读 STREAMINFO

### 客户端同步与缓存批处理

- **先落库再上报**：调权 / 收藏 / 歌单 / 断点先写本地（`applyWeightEvent` 在写连接内原子读改写并同时入 `weight_outbox`），再由 `SyncEngine` 推送——**不要**在 UI 回调里直接调 API
- **outbox 幂等**：每条事件带 `event_uuid`，服务端按 uuid 去重；直连歌曲**未配对或 `sync_enabled=0` 时不入队**，避免无限积压
- **推拉节奏**：`SyncEngine` 2s tick 推增量、30s 拉增量、失败指数退避（上限 30s）、启动先做一次全量校准（`since=0`）
- **拉到的快照走 `apply*Snapshot` op**：身份收集恒不建行（已删歌曲不复活）；远端断点落 `breakpoint_mirror`，不直接改运行时 `play_state`
- **缓存写入攒批**：WebDAV 缓存下载按 1MiB（`_cacheWriteBufBytes`）攒够再落临时文件，成功后 `cacheCommit` 换入正式路径并更新 `cache` 表——避免逐 chunk 小写入；`persistCover` 同样先写临时文件再改名，保证重复扫描幂等
- 同步协议语义（LWW / 事件重算 / 歌曲身份）见 [DESIGN.md §7.2](DESIGN.md#72-同步协议)

### 桌面音频后端（media_kit）

Linux / Windows 桌面统一 `just_audio_media_kit`（底层 libmpv）：libmpv 由 `media_kit_libs_linux` / `media_kit_libs_windows_audio` **随包分发，无需系统安装 mpv**。`main()` 顶部 `JustAudioMediaKit.ensureInitialized()` 完成注册（默认参数 Windows/Linux 启用、Android 关闭走 ExoPlayer）。

> 历史注：pubspec 里的 `just_audio_mpv`（0.1.7）从未接线（无 import、无初始化），已删除；Linux 桌面播放随 media_kit 真正接通。

### 鸿蒙适配（PoC）

工具链：`CPF-Flutter/flutter_flutter` 三方分支 `oh-3.41.9-release`（Dart 3.11，与 stable 并存，独立 wrapper 切换）+ DevEco Studio（ohpm/hvigor/node）+ 真机联调（Windows 上无模拟器）。壳工程 `frontend/ohos/` 已由 `flutter create --platforms ohos .` 生成。

插件审计结论（2026-09，pub.dev 实测）：

| 依赖 | ohos 方案 | 状态 |
|------|-----------|------|
| path_provider | `path_provider_ohos` 2.2.1 + 超时重试包装（保险层：1s 超时 × 5 次重发 + 沙盒回退；旧"引擎吞回复"根因已被实测翻案，见下节） | ✅ 直接用 + 保险 |
| file_selector | `file_selector_ohos` 0.5.0+2 | ✅ 直接用 |
| **just_audio（音频后端）** | **fvp**（libmdk 后端，官方支持 HarmonyOS 5.0+）+ 自写纯 Dart 适配层 `just_audio_platform_interface` → fvp Player，无 ArkTS | ✅ 已实现（`lib/platform/harmonyos/just_audio_fvp.dart`） |
| flutter_secure_storage | 两层适配：① `FlutterSecureStoragePlatform` 文件 shim；② **前端类绕过**——上游 9.2.4 的 `_selectOptions()` 对 ohos 无条件 throw 且 `_platform` 是逐调用 getter（包级注册平台实例救不了前端），子类 `OhosFlutterSecureStorage` 覆写六入口直调平台实例 + `createSecureStorage()` 工厂收口构造点 | ✅ 已实现（`secure_storage_ohos.dart`） |
| permission_handler | 桩包同样不兼容；应用内调用点均已 `Platform.isAndroid` 门控，ohos 不触发 | ✅ 无需处理 |
| wakelock_plus | 桩包不兼容 → `player_screen` 调用点按 `Platform.operatingSystem != 'ohos'` guard（ohos 放弃屏幕常亮） | ✅ 已处理 |
| audio_service | 无 ohos 实现 → 按预案降级「无通知栏」（代码已按 `Platform.isAndroid` 门控） | ✅ |
| sqlite3 | `open.overrideForAll()` 按名 dlopen `libsqlite3.so`——**设备系统无此库**（7 路径实测全无），命中的是随包分发的自编译副本（构建配方见下节） | ✅ 已实现（`ohos_bootstrap.dart` + `entry/libs/arm64-v8a/libsqlite3.so`） |
| audio_session | `AudioSession.instance` 在无插件平台 catch 掉 `MissingPluginException` 返回空实现，just_audio 的 `handleInterruptions` 安全（与 Windows/Linux 同路径） | ✅ 已验证，无需处理 |
| cached_network_image | 传递依赖 sqflite 无 ohos 实现 → 封面降级显示，不阻塞点播验收 | ⚠️ 已知问题 |

关键事实：
- **跨 SDK 兼容铁律**：stable 工具链的 `dart:io` 没有 `Platform.isOhos` getter，所有 ohos 判断必须写 `Platform.operatingSystem == 'ohos'`（两套 SDK 都可编译且行为一致），见 `lib/platform/harmonyos/ohos_bootstrap.dart` 的 `isOhos`
- WebDAV 直连鉴权只有 `Authorization: Basic` → 适配层解码回 user:pass percent-encode 折进 URL userinfo（FFmpeg 原生承载，mdk 不支持自定义请求头）；`DirectAudioSource` 字节流（just_audio 内建 localhost 代理）为兜底，三种音源形态（file://、https://+Basic、127.0.0.1 代理）都到达 `ProgressiveAudioSourceMessage` 统一处理
- fvp 构建期经 CMake 从 sourceforge 下载 mdk 预编译库（可用 `FVP_DEPS_URL` 环境变量换镜像）；libmdk.so/libfvp.so/libffmpeg.so 打入 hap，ohos FFI 加载层已内置。实测下载成功：libfvp.so 2.8MB + libmdk.so 2MB + libffmpeg.so 7.4MB（arm64-v8a）
- flutter 工具自动把带 ohos 模块的插件写入 `ohos/build-profile.json5` modules 与 har overrides，无需手工接线
- fvp 用 vendored 副本 `frontend/third_party/fvp`（ohos-only 平台声明 + 删除 video_player 依赖链），升级 = 重新复制 0.38.1 源码 + 重打两个补丁（见该目录 pubspec.yaml / lib/fvp.dart 头部注释）

适配层实现（`lib/platform/harmonyos/`，2026-09）：
- `ohos_bootstrap.dart`：`setupOhos()` 在 `main()` 里 runApp 前调用，四件事全部仅 ohos 生效——sqlite3 overrideForAll（顶层函数，**仅本 isolate 有效**：不随 Isolate.spawn 传入子 isolate，ohos 写层因此退化内联，见 `db_writer.dart` 头注释）、`FlutterSecureStoragePlatform.instance = OhosSecureStorage()`（包级注册只覆盖平台侧，前端类另需绕过，见上表）、`JustAudioPlatform.instance = FvpJustAudio()`、`PathProviderPlatform.instance = OhosRetryingPathProvider(原实现)`（单点收口：启动链全部路径调用均经该 instance）
- `path_provider_ohos_retry.dart`：1s 超时 × 5 次重发的保险包装 + 全超时沙盒路径回退（命中时日志 `[ohos] path_provider.* 响应超时`）；旧"引擎竞态吞回复"根因已被 verify-5/6 逐消息对账翻案（见下节），保留理由：路径查询幂等、成本为零、覆盖未证实的极端时序
- `just_audio_fvp.dart`：`FvpJustAudio.init/disposePlayer` 管理播放器表；`FvpAudioPlayer` 实现负载面 load/play/pause/seek/setVolume（+speed/loop 顺带），pitch/shuffle/skipSilence 静默 no-op；mdk 状态映射：`prepare()<0` 抛 PlatformException、`state=stopped` 且非加载复位/错误 → `completed`（自动切歌依赖）、`MediaStatus.invalid`/`onEvent error` → 错误上报、位置用 200ms Timer 轮询（mdk 无位置流）、同一媒体重复 load 前先回 stopped 复位（mdk prepare 对已加载返回 -1）；音量两侧语义一致（0.0-1.0）
- `secure_storage_ohos.dart`：文档目录单 JSON 文件 + 整文件 base64 混淆，内存即权威源；读写失败不抛（密钥问题不崩登录/配对流程）；对应 platform_interface 1.1.2 Map-options 签名（flutter_secure_storage 9.2.4 锁定该版本，`*Params` API 是 1.2+ 才有，勿混淆）

启动白屏根因（2026-09 真机取证定稿）：两颗应用/生态层地雷，引擎无辜。

> 翻案史：最初据"启动早期平台消息无回复"假设引擎竞态吞回复（~130ms 窗口），据此写了超时重试包装。verify-5 逐消息对账推翻该假设——**67 条 FlutterNapi 回执无一丢失**，引擎消息通道全程正常；旧取证里"挂起的 documentsPath 调用"其实来自 `OhosSecureStorage._ensureLoaded`，回复本身送达了，死的是其后的前端读取。重试包装保留为无害保险层。

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

构建验证状态（2026-09）：
- 双 SDK `flutter analyze` 零问题（ohos 3.41.9 与 stable 各自通过；两 SDK 的 pub get 会对 meta/test_api/vector_math 等 4 个 flutter_test 传递依赖来回改写 lock，属已知无害现象）
- `flutter build hap --debug` 编译链全通：ArkTS（三插件 GeneratedPluginRegistrant）+ native（libfvp.so/libmdk.so arm64-v8a）+ Dart（kernel_blob JIT），assembleHap 出 signed hap
- 真机部署已走通：`devecocli signature generate`（签名材料落 `~/.ohos/config/`）→ 出包 → `hdc install -r` / `devecocli run`
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
```

PoC 验收口径（`win10开发机准备.md` §2.4）：空壳 + 直连 WebDAV 浏览 + 本地索引 + 真机点播一首歌；跑不通则按 DESIGN §9 R2 降级「仅 WebDAV 直连」。重点观察：fvp 重复 load 复位逻辑（重播同一首）、completed→自动切歌、WebDAV Basic 鉴权折叠是否被服务端/FFmpeg 接受。

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

> 配对密钥查看：① 后端**首次启动**日志以 `WARN` 打印一次；② 已配对设备 `设置 → 服务端 → 配对服务器`（副标题遮显同一份密钥，配对页明文可复制）。

### application.yml 关键项

- 容器内应用监听 8080，对外经 Compose 映射为 18088
- Hikari 连接池：最大 20、最小空闲 5
- devtools 热重载已开启，监控 `src/main/java`
- 业务配置（`LOCAL_MUSIC_ROOT` / `WEBDAV_*` 等出流代理、缓存建议值来源）见 [settings.md §5 服务端全局设置](settings.md)；服务端已无 `SCAN_*` 扫描 env（扫描只在 APP 侧）

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
