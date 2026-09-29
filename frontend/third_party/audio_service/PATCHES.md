# audio_service vendored fork（SelfMusic 补丁）

`audio_service` 0.18.19 的本地副本，用于 Android 通知栏自研 5 键
（上一首/播放·暂停/下一首/播放模式/退出软件）。

## 为什么 fork

audio_service 原版只在通知里渲染「原生动作」（play/pause/skipToPrevious/skipToNext…），
`MediaControl.customAction` 的自定义动作只进 MediaSession 自定义动作列表，**不会**
变成手机通知上的按钮（Android Auto/TV/Watch 才能看到）。因此「播放模式」「退出软件」
两个自定义键在手机上永远出不来。

## 改动清单（相对 0.18.19）

- `android/src/main/java/com/ryanheise/audioservice/AudioService.java`
  - `buildNotification()`：把 `customActions` 逐条 `builder.addAction()` 追加为通知按钮
    （图标/文案来自 `PlaybackStateCompat.CustomAction`），紧跟在原生按钮之后，
    槽位 3/4（收起视图 `compactActionIndices [0,1,2]` 只取前三个，展开视图出全 5 键）。
  - 新增 `buildCustomActionPendingIntent()`：PendingIntent 走
    `MediaButtonReceiver.ACTION_CUSTOM`，名字/额外参数随 extra 携带，
    requestCode 用动作名哈希、`FLAG_UPDATE_CURRENT`。
  - 新增 `handleCustomAction()`：与 `MediaSessionCallback.onCustomAction` 同分发
    （STOP/FF/REWIND 特判兼容 SDK>=33 的动作映射），其余落 `listener.onCustomAction`
    → Dart handler 的 `customAction` 回调。
- `android/src/main/java/com/ryanheise/audioservice/MediaButtonReceiver.java`
  - 新增 `ACTION_CUSTOM` / `EXTRA_CUSTOM_NAME` / `EXTRA_CUSTOM_EXTRAS`，
    `onReceive` 直接派发到 `AudioService.handleCustomAction`（不经 media 会话 keycode 路由）。

## 依赖接入

`frontend/pubspec.yaml` 用 `dependency_overrides` 指到本目录：

```yaml
dependency_overrides:
  audio_service:
    path: third_party/audio_service
```

## 升级步骤

1. 替换本目录文件为 pub.dev 对应新版本（`dart pub cache add audio_service --version <新版>` 后复制，删除 `example/`、`test/`）。
2. 重新应用上面的两处改动（`buildNotification` + 两个新方法 + `MediaButtonReceiver`）。
3. `cd frontend && flutter pub get` 确认仍指到本 fork（`flutter pub deps | grep audio_service`）。