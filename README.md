# SelfMusic

一个跨平台音乐播放应用，覆盖 **Android / Windows / 鸿蒙 (OpenHarmony)**，使用容器化后端开发环境。

## 技术栈

| 层级 | 技术 | 备注 |
|------|------|------|
| 前端 | Flutter 3.6+ / Dart | 支持 Android、Windows，计划支持 OpenHarmony |
| 后端 | Spring Boot 3.4.4 / JDK 21 | REST API |
| 构建 | Maven | |
| 数据库 | MySQL 8.0 | 宿主机已有实例，容器内应用直连 |
| 反向代理 | Nginx | 宿主机已有实例 |
| 容器 | Docker + Docker Compose | 仅后端容器化 |

## 快速开始

### 1. 初始化数据库

在宿主机 MySQL 中执行初始化脚本：

```bash
mysql -u root -p < scripts/init.sql
```

### 2. 配置环境变量

复制 `.env` 模板并填入宿主机内网 IP 和 MySQL 密码：

```bash
cp .env .env.local
# 编辑 .env.local，修改 DB_HOST 和 DB_PASSWORD
```

### 3. 启动后端

```bash
docker compose --env-file .env.local up -d --build
```

验证健康检查：

```bash
curl http://localhost:18088/api/health
# 返回 {"status":"UP","service":"SelfMusic API",...}
```

### 4. 编译后端（本地开发）

```bash
mvn dependency:go-offline -f backend/pom.xml
mvn compile -f backend/pom.xml
```

### 5. 启动前端（需要 Flutter SDK）

```bash
cd frontend
flutter pub get
flutter run -d windows   # Windows 桌面
flutter run -d android   # Android
```

### 6. 配置 Nginx（可选）

```bash
sudo cp nginx/selfmusic.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/selfmusic.conf /etc/nginx/sites-enabled/
sudo nginx -s reload
```

## 项目结构

```
selfmusic/
├── backend/                     # Spring Boot 后端
│   ├── Dockerfile               # 多阶段构建（JDK 21）
│   ├── pom.xml
│   └── src/main/java/com/selfmusic/backend/
│       ├── SelfMusicApplication.java
│       ├── config/WebConfig.java
│       └── controller/HealthController.java
├── frontend/                    # Flutter 前端
│   ├── pubspec.yaml
│   ├── lib/main.dart
│   └── assets/{images,icons}/
├── scripts/
│   └── init.sql                 # MySQL 建库建表
├── nginx/
│   └── selfmusic.conf           # Nginx 反向代理配置
├── docker-compose.yml           # Docker 编排
├── .env                         # 环境变量模板
└── README.md
```

## Docker 服务

| 服务 | 暴露端口 | 说明 |
|------|---------|------|
| `backend` | `18088` | Spring Boot API，连接宿主机 MySQL |

## 端口映射

| 端口 | 用途 |
|------|------|
| `18088` | 后端 API（通过 Docker 映射，避免与宿主机 8080 冲突） |

## 宿主机依赖

- Docker + Docker Compose
- MySQL 8.0（已安装）
- Nginx（已安装）
- Flutter SDK（用于前端开发）
- JDK 21（宿主机编译用，容器自带的 Maven 镜像也已包含）
