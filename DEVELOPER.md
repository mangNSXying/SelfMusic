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
| Flutter SDK | 3.6+（Dart ^3.6.0） | 前端开发，经 **FVM** 安装管理（见下） |
| FVM | 最新稳定版 | Flutter 版本管理，多项目/长期项目防版本漂移 |
| Android SDK / Android Studio | 最新稳定版 | Android 构建调试 |
| Visual Studio 2022 | 含"使用 C++ 的桌面开发"负载 | Windows 桌面构建（在 Windows 机器上） |

> 注意区分：**Visual Studio 2022**（Windows 原生编译工具链，MSVC + Windows SDK + CMake/Ninja）≠ **VS Code**（日常写 Dart/Java 的编辑器）。Flutter 官方 Windows Desktop 构建依赖前者。
>
> 鸿蒙（OpenHarmony/HarmonyOS NEXT）：Flutter 官方不支持，后续通过 `openharmony-sig/flutter_flutter` 三方分支适配，当前不阻塞开发。

### 多平台构建矩阵

不同平台的最终产物必须在对应操作系统上构建，一台 Ubuntu 无法完成全部：

| 目标平台 | 构建环境 | 状态 |
|---------|---------|------|
| Android | 本机 Ubuntu（Android Studio + SDK） | ✅ 就绪 |
| Linux Desktop | 本机 Ubuntu（clang + GTK + cmake + ninja） | ✅ 就绪 |
| Web | 不做 | ❌ 明确排除 |
| Windows Desktop | 需要 Windows 环境：Flutter + FVM + VS Code + **Visual Studio 2022**（C++ 桌面负载） | ⏳ 后置 |
| HarmonyOS | 需要 DevEco Studio + HarmonyOS SDK + 鸿蒙真机，配合三方 Flutter 分支 | ⏳ 后置（阶段 4 再投入） |

### 环境搭建顺序

**现在（本机 Ubuntu）：**
1. Flutter（经 FVM 安装）+ Linux toolchain
2. Android Studio + Android SDK + 接受 license
3. VS Code + Flutter/Dart 扩展
4. Git（项目已纳入 git 管理）
5. FVM：`fvm use stable` 后生成 `.fvmrc` 入库

**暂时不需要：**
- Chrome / Web SDK（不做 Web）

**之后准备（按路线图触发）：**
- 阶段 1 收尾前后 → Windows 机器（或 VM）+ Visual Studio 2022，用于 Windows Desktop 出包
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
│   ├── lib/main.dart                 # 入口
│   ├── android/ windows/ web/        # 各平台壳工程
│   └── pubspec.yaml
├── scripts/init.sql                  # 数据库初始化脚本（v2 schema）
├── nginx/selfmusic.conf              # Nginx 反代模板（部署到宿主机）
├── docker-compose.yml                # backend（18088）+ backend-dev（18089，profile: dev）
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

### 常用命令

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

### Flutter 版本管理（FVM）

项目使用 **FVM** 锁定 Flutter SDK 版本，避免全局版本漂移：

```bash
# 首次：安装指定版本并生成 .fvmrc（提交入库，团队成员自动对齐）
cd frontend && fvm use 3.x.x   # 以 pubspec environment 约定的版本为准

# 之后所有 flutter 命令经 fvm 调用：
fvm flutter pub get
fvm flutter run -d <device>
fvm flutter analyze
fvm flutter test
fvm flutter build apk --release
fvm flutter build windows --release

# IDE：VS Code 中执行 "FVM: Change SDK" 或把 .fvm/flutter_sdk 加入 dart.sdkPath
```

`.fvm/` 目录不入库（`.gitignore` 已覆盖），`.fvmrc` 必须入库。

### 常用命令

```bash
flutter pub get                # 安装依赖
flutter run -d <device>        # 运行：windows / android / linux
flutter analyze                # 静态检查
flutter test                   # 单元测试
flutter build apk --release    # Android 出包
flutter build windows --release # Windows 出包（需 Windows 环境，见"多平台构建矩阵"）
```

### API 地址配置

`lib/main.dart` 通过编译期常量注入后端地址：

```bash
# 连接本地直跑的后端（8080）
flutter run --dart-define=API_BASE_URL=http://<宿主机IP>:8080

# 连接 Dev 容器后端（日常开发，18089）
flutter run --dart-define=API_BASE_URL=http://<宿主机IP>:18089

# 连接生产镜像后端（18088）
flutter run --dart-define=API_BASE_URL=http://<宿主机IP>:18088

# Android 真机不能用 localhost，必须用宿主机局域网 IP
```

### 技术选型（pubspec.yaml 已引入）

| 包 | 用途 |
|----|------|
| dio | HTTP 客户端 |
| provider | 状态管理 |
| just_audio | 音频播放 |
| cached_network_image | 图片缓存 |
| flutter_secure_storage | 敏感数据安全存储 |

---

## 数据库规范

- 表结构变更：**修改 `scripts/init.sql` 并同步提交**，同时更新对应 JPA 实体；`application.yml` 中 `ddl-auto: validate` 会校验实体与表结构一致性，不一致启动即报错
- 字符集统一 `utf8mb4`
- 所有表带 `id BIGINT AUTO_INCREMENT PRIMARY KEY`、`created_at`、`updated_at`
- 初始化脚本中的用户创建语句已注释（由管理员手工管理账号），执行前确认账号存在且对 `selfmusic.*` 有权限

---

## API 规范

- 路径前缀 `/api/v1/`，资源名用复数：`/api/v1/library/songs`、`/api/v1/playlists`
- 动作语义：GET 查询 / POST 创建 / PUT 全量更新 / PATCH 局部更新 / DELETE 删除
- 认证：除 `/api/v1/health` 与 `/api/v1/auth/**` 外全部要求 `Authorization: Bearer <device_token>`
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
- 提交信息：`feat: 新增歌单接口` / `fix: 修复播放进度丢失` / `chore: 升级依赖`
- 不要提交：`.env.local`、`build/`、`.dart_tool/`、`.fvm/`、IDE 私有配置（`.gitignore` 已覆盖大部分）
- 远端：推荐推送至自建 **Gitea**（局域网私有仓库），四端代码同仓管理；`.fvmrc` 入库保证各构建机 Flutter 版本一致
