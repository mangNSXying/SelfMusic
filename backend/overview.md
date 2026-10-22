# SelfMusic 后端

**去中心化的个人音乐服务 —— 服务端**：设备配对 · 多设备状态同步 · 无状态转码代理。

你的音乐文件始终留在自己的 WebDAV / SMB / 本地磁盘上：SelfMusic 客户端（Flutter 四端：Linux / Android / Windows / HarmonyOS NEXT）直连播放源，本服务端只负责让多台设备「对得上」——**不存储、不索引任何音乐**。

## 特性

- **设备配对**：单用户多设备；`PAIRING_TOKEN` 配对，access / refresh token 仅存哈希，设备可管理、可撤销
- **状态同步**：权重 / 收藏 / 歌单 / 播放源 / 断点续播跨设备收敛（事件流水 + 幂等去重 + 行级 LWW）
- **转码代理（可选）**：客户端播放源切到「服务端代理」后，由本服务回源（SFTP / SMB）并用内置 ffmpeg 实时转码下发；并发由 `TRANSCODE_MAX_CONCURRENCY` 门控，超限返回 429，客户端自动回落直连
- **无状态**：容器内不落任何持久数据（状态全在 MySQL），可随时重建 / 滚动升级

## 快速开始

> 前置：需自备 MySQL 8 数据库。只需建库建账号，表结构由后端启动时 Flyway 自动创建/升级。

**1. 建库建用户**

```sql
CREATE DATABASE selfmusic CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'selfmusic_user'@'%' IDENTIFIED BY '<数据库密码>';
GRANT ALL PRIVILEGES ON selfmusic.* TO 'selfmusic_user'@'%';
FLUSH PRIVILEGES;
```

> 不需要手工执行建表 SQL；启动容器后 Flyway 会自动执行 `db/migration` 下的迁移。

**2. 启动容器**

```yaml
# docker-compose.yml
services:
  selfmusic-backend:
    image: leeshamiko/selfmusic-backend:latest
    container_name: selfmusic-backend
    ports:
      - "18088:8080"                 # 宿主机端口按需修改
    environment:
      # {xx} 为.env中的变量，推荐使用.env管理
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT}
      DB_NAME: ${DB_NAME}
      DB_USERNAME: ${DB_USERNAME}
      DB_PASSWORD: ${DB_PASSWORD}
      # PAIRING_TOKEN: ${PAIRING_TOKEN:-} # 可选；留空则首次启动随机生成，并在启动日志 WARN 打印一次
      CACHE_MAX_MIB: ${CACHE_MAX_MIB:-5120}
      CACHE_SONG_LIMIT: ${CACHE_SONG_LIMIT:-200}
      TRANSCODE_MAX_CONCURRENCY: ${TRANSCODE_MAX_CONCURRENCY:-2}
      TZ: Asia/Shanghai
    restart: unless-stopped
```

```
# .env
# MySQL 连接配置
DB_HOST=localhost
DB_PORT=3306
DB_NAME=selfmusic
DB_USERNAME=user
DB_PASSWORD=password

# 配对密钥（可选，留空则首次启动随机生成；改动后重启生效，仅影响新设备）
PAIRING_TOKEN=

# 服务端缓存建议值（客户端 follow_server 模式的建议来源；单位：MiB / 首数；
# 每次启动覆盖 settings 表，改动后重启生效）
CACHE_MAX_MIB=5120
CACHE_SONG_LIMIT=200

# 无状态转码并发上限（只 env：1-32，默认 2；超限 429 客户端回落直连）
TRANSCODE_MAX_CONCURRENCY=2
```

```bash
docker compose up -d && docker compose logs -f
```

**3. 验证**

```bash
curl http://localhost:18088/api/v1/health
# {"status":"UP","service":"SelfMusic API","timestamp":"..."}
```

**4. 配对客户端**：打开 SelfMusic App → 设置 → 服务端，填入 `http://<主机地址>:18088` 与配对密钥（显式设置的 `PAIRING_TOKEN`，或首次启动日志中的随机值）。

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DB_HOST` | `localhost` | MySQL 地址（**必填**） |
| `DB_PORT` | `3306` | MySQL 端口 |
| `DB_NAME` | `selfmusic` | 数据库名 |
| `DB_USERNAME` | `user` | 数据库用户名 |
| `DB_PASSWORD` | `password` | 数据库密码（**必填**） |
| `PAIRING_TOKEN` | 首启随机生成 | 配对密钥；改动后重启生效，仅影响新配对设备 |
| `CACHE_MAX_MIB` | `5120` | 下发给客户端的缓存容量建议（MiB） |
| `CACHE_SONG_LIMIT` | `200` | 下发给客户端的缓存歌曲数建议 |
| `TRANSCODE_MAX_CONCURRENCY` | `2` | 转码并发上限（1–32），超限 429 |
| `TZ` | `Asia/Shanghai` | 建议 `Asia/Shanghai` |

## 接口速览

| 路径 | 认证 | 说明 |
|------|------|------|
| `GET /api/v1/health` | 匿名 | 健康检查 |
| `POST /api/v1/auth/pair` / `/refresh` | 匿名 | 设备配对 / 刷新令牌 |
| `GET /api/v1/meta/server` | Bearer | 版本、ffmpeg 可用性、转码水位、设备数 |
| 同步 / 歌单 / 设备管理 | Bearer | 完整契约见源码仓库 DEVELOPER.md「API 设计」 |

## 镜像信息

- 标签：`1.0.0`、`latest`
- 架构：`linux/amd64`
- 端口：容器内 `8080`
- 以非 root（UID 1000）运行；镜像已内置 ffmpeg
- 无数据卷：所有状态在 MySQL，容器可随时重建

## 许可 / 源码

- 许可证：MIT-0（MIT No Attribution）
- 源码与完整文档（部署 / API / 架构 / 客户端）：https://gitea.shamiko.site/shamiko/SelfMusic
