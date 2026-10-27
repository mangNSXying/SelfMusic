# SelfMusic Online Music Sidecar（L1）

给 SelfMusic 客户端提供“在线搜索 + 下载入库”的独立 Python 服务。它基于
[musicdl](https://github.com/CharlesPikachu/musicdl)，但 **不把 musicdl 或任何
第三方解析地址/直链暴露给客户端**：

```text
App ──搜索(SSE)/任务轮询──▶ sidecar ──▶ musicdl ──▶ 各音乐平台
App ◀──校验后的音频文件───── sidecar
App ──uploadFile/scanSource──▶ 曲库（WebDAV/SMB/本地）
```

L1 不提供在线流播放；下载完成后由 App 上传到现有播放源并触发扫描。

## 特性

- 逐源 SSE 搜索，慢源不阻塞快源；
- 搜索结果只返回 `track_token`，上游直链/headers/cookies 留在 sidecar；
- 下载后 `ffprobe` + `ffmpeg` 解码校验，拒绝坏帧/截断/格式伪装；
- 自动写标签、内嵌歌词/封面、同名 `.lrc`；
- 任务进度、token 过期、临时文件 TTL 清理；
- Bearer token 鉴权，健康检查，Docker 镜像。

## 运行

```bash
cd online-music
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env
# 编辑 .env，至少设置 ONLINE_MUSIC_TOKEN
set -a; . ./.env; set +a
python app.py
```

需要系统安装 `ffmpeg`（包含 `ffprobe`）。首次启动会在
`ONLINE_MUSIC_STATE_DIR` 下创建 `token`（未显式配置时）。

### 单元测试

```bash
PYTHONPATH=. python -m unittest discover -s tests -v
```

自签名 HTTPS 需在 App「设置 → 服务端 → 网络与安全」开启「信任自签名证书」；
更稳妥的做法仍是内网 HTTP + 防火墙限制，跨网访问用有效证书的 nginx/Tailscale。

### Docker

```bash
docker build -t selfmusic-online-music .
docker run -d --name selfmusic-online-music \
  -p 127.0.0.1:18090:18090 \
  -e ONLINE_MUSIC_TOKEN='换成你的 token' \
  -v "$PWD/state:/data" \
  selfmusic-online-music
```

镜像内以 UID 1000 运行；bind mount 的 `state/` 若属主不同，需要
`sudo chown -R 1000:1000 state`，或用
`--user "$(id -u):$(id -g)"` 运行（确保目录可写）。

不要直接暴露到公网。建议交给 nginx 加 HTTPS：

```nginx
location /online/ {
    proxy_pass http://127.0.0.1:18090/;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_read_timeout 600s;
    proxy_send_timeout 600s;
    client_max_body_size 0;
}
```

客户端里的 sidecar 地址就填 `https://你的域名/online`。

## 客户端配置

在 SelfMusic 的「设置 → 在线音乐」中填写：

- Sidecar 地址：例如 `http://192.168.1.20:18090` 或 `https://host/online`
- Token：与 `ONLINE_MUSIC_TOKEN` 一致
- 音乐源：QQ/酷我/咪咕（默认）
- 目标播放源与目录：选择一个支持写入的 WebDAV/SMB/本地源

然后从顶栏的云朵图标进入「在线搜索」。

## API

所有 `/v1/*` 接口都需要：

```http
Authorization: Bearer <token>
```

### `GET /healthz`

无需鉴权，返回版本、源、ffmpeg 状态。

### `GET /v1/sources`

```json
{"sources":[{"id":"QQMusicClient","label":"QQ音乐","default":true}]}
```

### `GET /v1/search?q=晴天&sources=QQMusicClient,KuwoMusicClient&limit=10`

SSE：

```text
event: source_start
data: {"source":"QQMusicClient","source_label":"QQ音乐"}

event: result
data: {"track_token":"…","source":"QQMusicClient","source_label":"QQ音乐",
       "title":"晴天","artist":"周杰伦","album":"叶惠美","duration_s":269,
       "ext":"flac","size_bytes":178320000,"lossless":true,"has_lyric":true}

event: source_done
data: {"source":"QQMusicClient","count":1,"timed_out":false}

event: done
data: {"count":1}
```

### `POST /v1/fetch`

```json
{"track_token":"…"}
```

返回 job：

```json
{"job_id":"…","status":"queued","progress":0.0}
```

轮询 `GET /v1/fetch/{job_id}`，`status` 依次为
`queued → downloading → verifying → ready`（或 `error`）。

### `GET /v1/fetch/{job_id}/file`

下载校验完成的音频文件。

### `GET /v1/fetch/{job_id}/lyric`

返回同名 `.lrc` 文本；没有则 404。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `ONLINE_MUSIC_HOST` | `0.0.0.0` | 监听地址 |
| `ONLINE_MUSIC_PORT` | `18090` | 监听端口 |
| `ONLINE_MUSIC_TOKEN` | 自动生成 | 客户端 Bearer token |
| `ONLINE_MUSIC_SOURCES` | `QQMusicClient,KuwoMusicClient,MiguMusicClient` | 源列表 |
| `ONLINE_MUSIC_STATE_DIR` | `./state` | token/临时文件目录 |
| `ONLINE_MUSIC_SEARCH_TIMEOUT_SEC` | `30` | 单源搜索超时 |
| `ONLINE_MUSIC_TOKEN_TTL_MIN` | `30` | 搜索结果 token TTL |
| `ONLINE_MUSIC_JOB_TTL_MIN` | `30` | 下载任务/文件 TTL |
| `ONLINE_MUSIC_MAX_FETCHES` | `2` | 并发下载任务数 |
| `ONLINE_MUSIC_MAX_RESULTS_PER_SOURCE` | `10` | 单源结果上限（最大 10） |

## 已知限制

- 依赖 musicdl 及第三方解析接口，平台接口变动时可能失效；版本已锁定，
  升级前先跑一次真实搜索/下载回归。
- 主要平台下载属于灰色地带；请只下载你有权访问的内容，不要对外提供服务。
- 不要启用 Apple/TIDAL/SoundCloud 等带 DRM/额外二进制的源。
- musicdl 使用 PolyForm Noncommercial 1.0.0；本 sidecar 只适合个人自托管，
  不要随 SelfMusic 发布包分发，也不要发布包含 musicdl 的公共镜像。
- L1 不提供在线播放/断点续传；下载文件在 TTL 后清理，App 应尽快取回。
