# SelfMusic

**去中心化的个人音乐服务**：自建单用户同步服务（Spring Boot）+ 双模式客户端（Flutter / Linux · Android · Windows · HarmonyOS NEXT）。

- **多设备同步**：权重 / 收藏 / 歌单 / 播放源 / 断点跨设备收敛，设备配对可管理（后端不持有曲库）
- **直连模式**：没有后端也能完整使用 —— App 直连 WebDAV / SMB / 本地文件夹，源内文件夹式浏览 + 全局歌曲/专辑/歌手合并 + 离线缓存

## 文档地图

| 文档 | 内容 |
|------|------|
| **README.md**（本文） | 项目概览、技术栈、快速启动、服务与端口 |
| [DEVELOPER.md](DEVELOPER.md) | 整体架构 / 数据模型 / API 契约 / 播放算法与同步协议 / 环境搭建 / 构建矩阵 / 开发流程 / 客户端实现要点（SQLite 写隔离 / 扫描 / 同步 / 鸿蒙 PoC）/ 排障 / 风险 |
| [settings.md](settings.md) | 设置项权威清单（键名、默认值、入口、生效范围） |
| [frontend/README.md](frontend/README.md) | 前端目录速查与常用 flutter 命令 |

## 主要功能（已实现）

- **播放**：顺序 / 列表循环 / 单曲循环 / 加权随机四种模式；断点续播；淡入淡出、均衡器（Android）；睡眠定时（指定时间 / 时长 / 曲数 / 列表结尾，可播完当前曲）
- **曲库**：本地索引 + 直连扫描三档（fast / minimal / full）增量指纹极速重扫，播放时从头完整补读元数据；歌曲信息 / 修改元数据支持
- **喜欢与权重**：喜欢 / 不喜欢即时生效（不喜欢权重降到 0.1）、加权随机按 factor 选歌、喜欢歌自动缓存离线播
- **交互**：六分组左右滑动切换、播放页/歌词页跟手滑动（可关）、标题显示格式（文件名 / 歌名 / 歌手-歌名 / 歌名-歌手）、播放列表 / 播放源 / 专辑 / 歌手四页列表·卡片切换、进入播放队列与歌单自动定位当前曲并强调色
- **歌单**：播放页「编辑歌单」（列出全部播放列表，点按加入/移出），列表页长按多选批量管理；设置 / 歌单导出导入
- **歌词**：内嵌标签 / 同名 `.lrc` 读取，歌词页同步滚动高亮、点词跳转
- **后台播放**：返回桌面继续播放（Android 通知栏 5 键常驻；鸿蒙走系统 AVSession 媒体卡——通知栏/锁屏/播控中心；通知栏「停止/退出」或退出软件才真正停止）

## 技术栈

| 层级 | 技术 | 备注 |
|------|------|------|
| 前端 | Flutter / Dart ≥3.4 | **Linux + Android + Windows + HarmonyOS NEXT 四端**（`lib/` 全为跨平台 Dart；鸿蒙经三方分支 + `lib/platform/harmonyos/` 收口层接入，PoC 验收已通过） |
| 后端 | Spring Boot 3.4.4 / JDK 21 | REST API（仅认证 / 配对 / 状态同步） |
| 构建 | Maven | |
| 数据库 | MySQL 8.0 | 服务端；客户端另有独立 SQLite 轻量库 |
| 反向代理 | Nginx | 宿主机已有实例 |
| 容器 | Docker + Docker Compose | 仅后端容器化 |

> **平台开发原则**：Linux / Android / Windows / HarmonyOS NEXT 四平台同步开发、进度对齐，原因与验收口径见 [DEVELOPER.md「总体架构」](DEVELOPER.md#总体架构)。
> 各平台构建矩阵、音频后端接线（Android ExoPlayer / 桌面 libmpv / 鸿蒙 fvp）与所需构建机见 [DEVELOPER.md](DEVELOPER.md)。

## 快速开始

### 1. 初始化数据库

MySQL 只需创建数据库和账号；表结构由后端启动时 Flyway 自动创建/升级，不再需要手工执行 SQL：

```sql
CREATE DATABASE IF NOT EXISTS selfmusic
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'selfmusic_user'@'%' IDENTIFIED BY '换成你的密码';
GRANT ALL PRIVILEGES ON selfmusic.* TO 'selfmusic_user'@'%';
FLUSH PRIVILEGES;
```

> 账号名/密码要与 `.env` 的 `DB_USERNAME` / `DB_PASSWORD` 保持一致。
>
> 存量库直接启动新版后端即可：Flyway 会自动以 V1 为基线并补 V2/V3；
> V2 的 MODIFY 可重复执行，V3 会先检查列/索引是否存在；已手工执行过旧
> migration 的库也不会重复建列。

### 2. 配置环境变量

编辑 `.env` 模板，填入宿主机内网 IP 与 MySQL 密码：

```bash
# 必填：DB_HOST / DB_PASSWORD
# 可选：PAIRING_TOKEN —— 留空则首次启动随机生成并在启动日志(WARN)打印一次；
# 改动后重启生效，仅影响新设备（已配对设备不受影响）
# 可选：CACHE_MAX_MIB / CACHE_SONG_LIMIT —— 服务端缓存建议值（默认 5120 MiB / 200 首）；
# 每次启动覆盖写入 settings，客户端 follow_server 模式依据（客户端接线阶段 6 待做）
```

### 3. 启动后端

```bash
docker compose --env-file .env up -d --build backend-dev   # 日常开发，端口 18089
docker compose --env-file .env up -d --build backend       # 生产镜像，端口 18088

curl http://localhost:18089/api/v1/health   # {"status":"UP","service":"SelfMusic API",...}
```

### 4. 启动前端

```bash
cd frontend
flutter pub get
flutter run -d linux      # Linux 桌面（音频后端 libmpv 随包分发，无需系统装 mpv）
flutter run -d <设备id>   # Android（联调加 --dart-define=API_BASE_URL=http://<宿主IP>:18089）
```

> 仓库根目录另有 `run-linux.sh` / `run-android.sh` / `run-windows.bat` 快捷脚本。
> 本地直跑后端（`mvn spring-boot:run`）、Dart-define 联调地址、Windows / 鸿蒙构建机要求见 [DEVELOPER.md](DEVELOPER.md)。

### 5. 配置 Nginx（可选）

```bash
sudo cp nginx/selfmusic.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/selfmusic.conf /etc/nginx/sites-enabled/
sudo nginx -s reload
```

## 服务与端口

| 服务 | 宿主机端口 | 说明 |
|------|-----------|------|
| `backend-dev` | 18089 | **日常开发**：容器内 `spring-boot:run` 热重载，改 Java 免 build |
| `backend` | 18088 | 生产镜像（打包 jar），发布前验证 |
| 后端本地直跑 | 8080 | `mvn spring-boot:run -f backend/pom.xml`，不用 Docker 时 |

> 启动 / 停止 / 看日志的完整命令见 [DEVELOPER.md「后端开发」](DEVELOPER.md#后端开发)。

## 项目结构

```
selfmusic/
├── backend/                     # Spring Boot 后端（认证/配对 + 状态同步）
├── frontend/                    # Flutter 客户端（Linux/Android/Windows/ohos 壳工程 + 跨平台 lib/）
│   ├── lib/data/                # 播放源抽象 + SQLite 本地库 + 元数据解析
│   ├── lib/providers/           # 播放/曲库/歌单/导航/源管理状态
│   ├── lib/screens/             # 内容区 / 歌单 / 播放源 / 设置 / 播放页 / 配对
│   ├── third_party/             # vendored fork：fvp（ohos 平台声明 + 删视频依赖链）、audio_service（通知栏 5 键）
│   └── ohos/                    # 鸿蒙壳工程（build-profile.json5 含签名材料不入库，模板 .example）
├── backend/src/main/resources/db/migration/  # Flyway 版本化建表/迁移（服务端 schema 唯一事实源）
├── scripts/                     # 历史手工 SQL（已归档，新部署由 Flyway 接管）
├── nginx/selfmusic.conf         # 反向代理模板
├── docker-compose.yml           # backend + backend-dev 编排
├── .env                         # 环境变量模板（不入库）
├── run-linux.sh / run-android.sh / run-windows.bat   # 三端快速运行
├── build-ohos.ps1                                     # 鸿蒙 release 出包（三架构 / AGC 发布签名 .app）
├── DEVELOPER.md / settings.md
└── README.md
```

> 带注释的完整目录树、后端分层约定见 [DEVELOPER.md「项目结构」](DEVELOPER.md#项目结构)。

## 环境依赖

- Docker + Docker Compose、MySQL 8.0、Nginx（后端侧）
- JDK 21（宿主机编译用）、Flutter SDK（stable，Dart ≥3.4）
- Windows 出包需 Windows 机器 + VS 2022 C++ 桌面负载；鸿蒙需 DevEco Studio 与三方 Flutter 分支
- 根目录 `build-ohos.ps1` 等 `.ps1` 脚本若被执行策略拦下，先 `Unblock-File .\build-ohos.ps1`，或用 `powershell -ExecutionPolicy Bypass -File .\build-ohos.ps1 [hap]`
- 完整矩阵与搭建顺序见 [DEVELOPER.md「环境要求」](DEVELOPER.md#环境要求)
