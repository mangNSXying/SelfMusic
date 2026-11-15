# just_audio_media_kit vendored fork（SelfMusic 补丁）

`just_audio_media_kit` 2.1.0 的本地副本。桌面均衡器需要 mpv `af` 滤镜，
但上游把内部 `Player` 完全私有化，外部无法拿到句柄。

## 改动清单（相对 2.1.0）

- `lib/mediakit_player.dart`
  - 新增 `Player get player => _player;`，暴露内部 `media_kit` Player。
  - 装载批次隔离：`load()` 每次自增 `_loadGeneration`，被新批次接管的旧批次
    立即返回且**不再改写** `_mediaOpened` / `_loadCompleter` 等共享状态。
    just_audio 0.9.x 不会中断并发 `setUrl`，旧曲的 buffering 事件会把新曲的
    装载提前判成功，表现为「UI 切歌、声音还是旧曲」。
  - `load()` 统一以 `play: false` 打开，打开完成后按 `_playing` 的最新意图
    补发 play/pause：装载期间到达的播/停请求不再被 `open` 内部的 `pause=true`
    吞掉。
  - `play()` / `pause()` 去掉 `_mediaOpened` 门控，装载中也能把意图落到 mpv。
  - `open` 期间错过 ready/buffering 事件、或装载中报错时补完成 `_loadCompleter`，
    避免 `load` 只能靠上层 15s 装载看门狗超时收场。
- `lib/just_audio_media_kit.dart`
  - 构造函数记录 `static JustAudioMediaKit? instance`；
  - 新增 `MediaKitPlayer? get activePlayer`（应用单播放器场景取最近创建的实例）；
  - `export 'mediakit_player.dart' show MediaKitPlayer;`。

## 依赖接入

`frontend/pubspec.yaml`：

```yaml
dependency_overrides:
  just_audio_media_kit:
    path: third_party/just_audio_media_kit
```

## 升级步骤

1. 用 pub.dev 对应新版本替换 `lib/`、`pubspec.yaml`、`LICENSE`、`README.md`、`CHANGELOG.md`。
2. 重新应用上面的三处改动。
3. 运行 `flutter pub get`，确认依赖指向本目录。
