# SelfMusic

**去中心化的个人音乐服务**：自建单用户媒体服务器（Spring Boot），配合双模式客户端（Flutter，覆盖 Android / Windows / 鸿蒙）。

- **服务器模式**：统一曲库索引、多设备状态同步、按需转码省流量、设备配对管理
- **直连模式**：无后端时 App 直连 WebDAV / SMB 依然完整可用（浏览/搜索/加权播放/离线缓存）

> 整体设计（数据模型 / API / 播放算法 / 路线图）见 [DESIGN.md](DESIGN.md)，开发环境与日常流程见 [DEVELOPER.md](DEVELOPER.md)。

## 技术栈

| 层级 | 技术 | 备注 |
|------|------|------|
| 前端 | Flutter 3.6+ / Dart | **同步开发 Linux + Android**（`lib/` 全为跨平台 Dart）；Windows 计划；OpenHarmony 计划 |
| 后端 | Spring Boot 3.4.4 / JDK 21 | REST API |
| 构建 | Maven | |
| 数据库 | MySQL 8.0 | 宿主机已有实例，容器内应用直连 |
| 反向代理 | Nginx | 宿主机已有实例 |
| 容器 | Docker + Docker Compose | 仅后端容器化 |

> **平台开发原则**：Linux 桌面与 Android **同步开发、进度对齐**。`frontend/lib/` 的 UI/主题/播放器/鉴权/状态层均为跨平台 Dart，任何特性的落地同时给出双平台平台配套（音频后端/权限/生命周期差异用条件导入收口）。Android 平台对齐计划见 `DESIGN.md` §8「阶段 0」（实现暂缓）。

**音频后端**：`just_audio` 在 Linux 依赖 `just_audio_mpv`（需 `sudo apt install -y mpv libmpv-dev`），在 Android 使用默认 ExoPlayer 后端。

## 快速开始

### 1. 初始化数据库

在宿主机 MySQL 中执行初始化脚本：

```bash
mysql -u root -p < scripts/init.sql
```

### 2. 配置环境变量

编辑 `.env` 模板并填入宿主机内网 IP 和 MySQL 密码：

```bash
# 编辑 .env，修改 DB_HOST 和 DB_PASSWORD
# 配对密钥 PAIRING_TOKEN 可选：留空则首次启动随机生成并在启动日志(WARN)打印一次；
# 改动后重启生效，仅影响新设备（已配对设备不受影响）
```

### 3. 启动后端（二选一）

**日常开发**（Dev 容器，热重载免 build，端口 18089）：

```bash
docker compose --env-file .env up -d --build backend-dev
```

**生产模式**（jar 镜像，端口 18088）：

```bash
docker compose --env-file .env up -d --build backend
```

验证健康检查：

```bash
curl http://localhost:18089/api/health   # dev 模式
curl http://localhost:18088/api/health   # 生产模式
# 返回 {"status":"UP","service":"SelfMusic API",...}
```

### 4. 启动前端（Flutter SDK；Linux 首次需装 mpv）

```bash
sudo apt install -y mpv libmpv-dev   # Linux 桌面音频后端（仅首次）
cd frontend
flutter pub get
flutter run -d linux     # Linux 桌面（默认，当前主力平台）
flutter run -d android   # Android（⚠️ 需先创建安卓壳工程，见 DESIGN.md §8 阶段 0）
```

> **同步开发提示**：`frontend/lib/` 为跨平台 Dart 代码，同一份逻辑可同时在 Linux 与 Android 跑；音频后端按平台自动选择（Linux=mpv，Android=ExoPlayer）。
> Android 壳工程当前为空壳，落地计划见 `DESIGN.md §8 阶段 0`（实现暂缓）。

### 5. 配置 Nginx（可选）

```bash
sudo cp nginx/selfmusic.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/selfmusic.conf /etc/nginx/sites-enabled/
sudo nginx -s reload
```

## 项目结构

```
selfmusic/
├── backend/                     # Spring Boot 后端
│   ├── Dockerfile               # 生产镜像（多阶段构建，JDK 21）
│   ├── Dockerfile.dev           # Dev 镜像（容器内热重载）
│   ├── pom.xml
│   └── src/main/java/com/selfmusic/backend/
│       ├── SelfMusicApplication.java
│       ├── config/WebConfig.java
│       └── controller/HealthController.java
├── frontend/                    # Flutter 前端（可换主题自适应 UI，跨平台 Dart）
│   ├── pubspec.yaml
│   ├── linux/                   # Linux 壳工程（当前主力，完整）
│   ├── android/                 # Android 壳工程（⚠️ 空壳，落地见 DESIGN.md §8 阶段 0）
│   └── lib/
│       ├── main.dart            # 入口 + Provider 装配 / Root
│       ├── theme/               # 可配置主题（app_theme / theme_provider）
│       ├── layout/              # 自适应布局（app_shell/sidebar/top_bar/queue_panel/mini_player_bar）
│       ├── providers/           # 状态（auth/library/player/navigation）
│       ├── services/            # ApiClient（含懒刷新拦截器）/ AuthService
│       ├── data/sources/        # MusicSource 抽象 + ServerProxy
│       └── screens/             # 内容区 / 设置 / 配对 / 播放页
├── scripts/
│   └── init.sql                 # MySQL 建库建表
├── nginx/
│   └── selfmusic.conf           # Nginx 反向代理配置
├── docker-compose.yml           # Docker 编排
├── .env                         # 环境变量模板
└── README.md
```

## Docker 服务

| 服务 | 启动方式 | 暴露端口 | 说明 |
|------|---------|---------|------|
| `backend-dev` | `docker compose --env-file .env up -d --build backend-dev` | `18089` | **日常开发用**，容器内热重载，改代码免 build |
| `backend` | `docker compose --env-file .env up -d --build backend` | `18088` | 生产镜像（打包 jar），发布前验证 |

## 端口映射

| 端口 | 用途 |
|------|------|
| `18089` | Dev 容器后端 API（日常开发） |
| `18088` | 生产镜像后端 API |
| `8080` | 本地直跑后端（`mvn spring-boot:run`） |

## 宿主机依赖

- Docker + Docker Compose
- MySQL 8.0（已安装）
- Nginx（已安装）
- Flutter SDK（用于前端开发）
- JDK 21（宿主机编译用，容器自带的 Maven 镜像也已包含）
