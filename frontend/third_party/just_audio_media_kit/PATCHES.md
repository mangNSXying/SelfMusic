# just_audio_media_kit vendored fork（SelfMusic 补丁）

`just_audio_media_kit` 2.1.0 的本地副本。桌面均衡器需要 mpv `af` 滤镜，
但上游把内部 `Player` 完全私有化，外部无法拿到句柄。

## 改动清单（相对 2.1.0）

- `lib/mediakit_player.dart`
  - 新增 `Player get player => _player;`，暴露内部 `media_kit` Player。
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
