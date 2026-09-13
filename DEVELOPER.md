# SelfMusic 开发者文档

本文档面向项目开发者，介绍日常开发流程、调试方法与常见问题排查。

环境搭建与快速启动请参考 [README.md](README.md)。

---

## 目录

- [环境要求](#环境要求)
- [项目结构](#项目结构)
- [后端开发](#后端开发)
- [前端开发](#前端开发)
- [数据库规范](#数据库规范)
- [API 规范](#api-规范)
- [配置说明](#配置说明)
- [常见问题排查](#常见问题排查)

---

## 环境要求

| 依赖 | 版本 | 用途 |
|------|------|------|
| JDK | 21 | 后端编译运行（宿主机与容器保持一致） |
| Maven | 3.9+ | 后端构建 |
| Docker + Compose | 任意近期版本 | 后端容器化运行 |
| MySQL | 8.0 | 宿主机已有实例 |
| Flutter SDK | 3.6+（pubspec `sdk: ^3.6.0`） | 前端开发。直接使用系统 `flutter`（FVM 可选，见「版本管理」） |
| FVM（可选） | 最新稳定版 | 团队协作时锁定 Flutter 版本，防版本漂移 |
| mpv + libmpv-dev | 0.37+ | Linux 桌面音频后端（`just_audio_mpv` 依赖，见"Linux 桌面音频依赖"） |
| Android SDK / Android Studio | 最新稳定版 | Android 构建调试 |
| Visual Studio 2022 | 含"使用 C++ 的桌面开发"负载 | Windows 桌面构建（在 Windows 机器上） |

> 注意区分：**Visual Studio 2022**（Windows 原生编译工具链，MSVC + Windows SDK + CMake/Ninja）≠ **VS Code**（日常写 Dart/Java 的编辑器）。Flutter 官方 Windows Desktop 构建依赖前者。
>
> 鸿蒙（OpenHarmony/HarmonyOS NEXT）：Flutter 官方不支持，后续通过 `openharmony-sig/flutter_flutter` 三方分支适配，当前不阻塞开发。

### 多平台构建矩阵

不同平台的最终产物必须在对应操作系统上构建，一台 Ubuntu 无法完成全部：

> **平台开发原则**：**Linux 与 Android 同步开发、进度对齐**。`lib/` 全部代码为跨平台 Dart，特性落地时必须同时给出 Linux + Android 的平台配套（音频后端/权限/生命周期用条件导入或平台插件收口）。详见 `DESIGN.md §8`。

| 目标平台 | 构建环境 | 状态 |
|---------|---------|------|
| Android | 本机 Ubuntu（Android Studio + SDK） | ✅ 环境就绪；壳工程已重建（`android/app` + Gradle 配置齐全），`flutter build apk` 可出包，双端（Linux/Android）对齐开发 |
| Linux Desktop | 本机 Ubuntu（clang + GTK + cmake + ninja） | ✅ 当前主力平台（UI/主题/播放器/鉴权已落地） |
| Web | 不做 | ❌ 明确排除 |
| Windows Desktop | 需要 Windows 环境：Flutter + VS Code + **Visual Studio 2022**（C++ 桌面负载） | ⏳ 后置 |
| HarmonyOS | 需要 DevEco Studio + HarmonyOS SDK + 鸿蒙真机，配合三方 Flutter 分支 | ⏳ 后置（阶段 4 再投入） |

### 环境搭建顺序

**现在（本机 Ubuntu）：**
1. Flutter（系统安装即可；FVM 可选）+ Linux toolchain
2. Android Studio + Android SDK + 接受 license
3. VS Code + Flutter/Dart 扩展
4. Git（项目已纳入 git 管理）
5. （可选）FVM：`fvm use stable` 生成 `.fvmrc` 入库

**暂时不需要：**
- Chrome / Web SDK（不做 Web）

**之后准备（按路线图触发）：**
- Windows 出包前（后置）→ Windows 机器（或 VM）+ Visual Studio 2022，用于 Windows Desktop 出包
- 阶段 4 开始前 → 鸿蒙开发环境（DevEco Studio + SDK + 真机）；**不要提前把鸿蒙 SDK 装进 Ubuntu**

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
│       │   ├── library/              # 曲库 API（songs/albums/favorites）
│       │   ├── stream/               # 流媒体 API + MusicSourceProxy（local/webdav/smb）
│       │   └── domain/
│       │       ├── entity/           # JPA 实体（纯手写 getter/setter，不用 Lombok）
│       │       └── repository/       # Spring Data JPA 接口
│       └── resources/application.yml
├── frontend/                         # Flutter 前端
│   ├── lib/
│   │   ├── main.dart                 # 入口 + Provider 装配 / Root
│   │   ├── theme/                    # 可配置主题（app_theme / theme_provider）
│   │   ├── layout/                   # 自适应布局（app_shell / sidebar / top_bar / queue_panel / mini_player_bar）
│   │   ├── providers/                # 状态（auth / library / player / navigation / playlists / direct_source_manager）
│   │   ├── services/                 # dio+懒刷新拦截器(ApiClient)、AuthService、ServerSettings
│   │   ├── data/sources/             # MusicSource 抽象 + ServerProxy + WebdavDirect + SmbDirect
│   │   ├── data/local/               # audio_metadata（mp3/flac 头部解析）+ local_index + 阶段2 封装（song_weight_store / playlist_store / cache_manager / app_settings）
│   │   ├── models/                   # Song / Album / Artist
│   │   ├── widgets/                  # 共享组件（SongTile / CoverThumb / PlayModeSelector / add_to_playlist）
│   │   └── screens/                  # library / playlists_view / sources / source_browse_view / settings / player / pairing
│   ├── android/ linux/ windows/ web/ # 各平台壳工程（安卓壳已重建）
│   └── pubspec.yaml
├── scripts/init.sql                  # 数据库初始化脚本（v2 schema）
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

### 端口汇总

| 服务 | 宿主机端口 | 说明 |
|------|-----------|------|
| backend-dev | **18089** | Dev 容器，日常开发 |
| backend | **18088** | 生产镜像 |
| 本地直跑 | **8080** | 宿主机直接运行 |

前端联调时 `--dart-define=API_BASE_URL` 指向对应端口。

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
4. 在对应功能包（`auth/`、`library/`、`stream/`…）暴露 REST 接口，路径以 `/api/v1/` 开头
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
| just_audio_mpv | Linux 音频后端（联邦 Dart 插件，走系统 mpv/libmpv） |
| cached_network_image | 图片缓存 |
| flutter_secure_storage | 敏感数据安全存储（token、主题偏好） |
| sqlite3 / sqlite3_flutter_libs | 客户端本地库（local_index）：源索引 idx_songs + cache + play_meta + playlists + app_settings + play_state（drift 的轻量替代，见 DESIGN §3.2） |
| xml | WebDAV PROPFIND XML 解析 |

### 直连索引与元数据编码

`audio_metadata.dart` 纯 Dart 解析 mp3 ID3v2 / flac VORBIS_COMMENT 头部标签，不依赖第三方标签库：

- mp3 ID3v2：按帧 encoding 字节选解码策略（enc==3 → UTF-8；enc==0 → 尝试 UTF-8，失败回退 Latin-1；enc==1/2 → UTF-16）
- flac VORBIS_COMMENT：规范规定 UTF-8（`utf8.decode`），解码失败时回退 Latin-1
- 乱码修复历史：此前 mp3 enc==3 误用 `String.fromCharCodes`（逐字节解码导致 CJK 乱码），flac vorbis 同样误用——均已修正；修复后需对已有播放源重新执行一次「扫描」以覆写旧索引行（`upsert` 自动覆盖，无需手动清库）

### Linux 桌面音频依赖（mpv）

`just_audio` 在 Linux 上需要 mpv 后端（`just_audio_mpv`），因此本机需安装 mpv 及开发库：

```bash
sudo apt install -y mpv libmpv-dev
ldconfig -p | grep libmpv   # 应看到 libmpv.so / libmpv.so.2
```

> 插件以 `dartPluginClass` 联邦方式自动注册到 `JustAudioPlatform.instance`，无需手动初始化；`mpv_dart` 通过 FFI 按名 dlopen `libmpv`。

---

## 数据库规范

> 以下为**服务端 MySQL** 表规范；客户端 SQLite 是独立的轻量库（`local_index`，无 created_at/updated_at 约定），表结构见 `stage2.md §1` 与 `DESIGN.md §3.2`。

- 表结构变更：**修改 `scripts/init.sql` 并同步提交**，同时更新对应 JPA 实体；`application.yml` 中 `ddl-auto: validate` 会校验实体与表结构一致性，不一致启动即报错
- 字符集统一 `utf8mb4`
- 所有表带 `id BIGINT AUTO_INCREMENT PRIMARY KEY`、`created_at`、`updated_at`
- 初始化脚本中的用户创建语句已注释（由管理员手工管理账号），执行前确认账号存在且对 `selfmusic.*` 有权限

---

## API 规范

- 路径前缀 `/api/v1/`，资源名用复数：`/api/v1/library/songs`、`/api/v1/playlists`
- 动作语义：GET 查询 / POST 创建 / PUT 全量更新 / PATCH 局部更新 / DELETE 删除
- 认证：除 `/api/v1/health`、`/api/v1/auth/pair`、`/api/v1/auth/refresh` 外全部要求 `Authorization: Bearer <access_token>`；access 过期返回 `401 + X-Token-Expired: true`，客户端懒刷新
- 统一响应包一层：

```json
{ "code": 0, "message": "ok", "data": { } }
```

- 错误码：`0` 成功，`4xx` 客户端错误，`5xx` 服务端错误
- 健康检查：`GET /api/v1/health`

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

> 配对密钥查看：① 后端**首次启动**日志以 `WARN` 打印一次；② （暂缓）已配对设备 `设置→常规` 明文显示。

### application.yml 关键项

- 容器内应用监听 8080，对外经 Compose 映射为 18088
- Hikari 连接池：最大 20、最小空闲 5
- devtools 热重载已开启，监控 `src/main/java`

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
