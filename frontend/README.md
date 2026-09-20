# SelfMusic 前端（Flutter）

跨平台客户端：Linux 桌面 + Android 同步开发，`lib/` 全为可换主题自适应 Dart 代码（Windows / 鸿蒙计划中）。

## 运行

```bash
sudo apt install -y mpv libmpv-dev   # Linux 桌面音频后端（仅首次）
flutter pub get
flutter run -d linux                 # Linux 桌面
flutter run -d <设备id>              # Android（后端联调加 --dart-define=API_BASE_URL=http://<宿主IP>:18089）
```

## 常用命令

```bash
flutter analyze               # 静态检查
flutter test                  # 单元/组件测试
flutter build linux --debug   # Linux 出包（验证用 --release）
flutter build apk --debug     # Android 出包
```

## 目录

```
lib/
├── main.dart               入口 + Provider 装配（含 AudioService 通知/后台播放门控注册）
├── theme/                  可配置主题（app_theme / theme_provider）
├── layout/                 app_shell / sidebar / top_bar（搜索追焦） / queue_panel（自动定位当前曲） / mini_player_bar
├── providers/              player / library / navigation / playlists / direct_source_manager / auth
├── services/               ApiClient（懒刷新拦截器）/ AuthService / ServerSettings
├── data/                   sources（Source 抽象层）/ local（audio_metadata + local_index + 各封装）
├── models/                 Song / Album / Artist
├── utils/                  duration_format / song_title_format / lrc_parser
├── widgets/                SongTile / CoverThumb / lyrics_view / add_to_playlist（加入·编辑歌单）/ view_mode_toggle 等
└── screens/                library / playlists_view / sources / source_browse_view / settings / player / pairing
```

架构与设计见根目录 [DESIGN.md](../DESIGN.md)，开发流程见 [DEVELOPER.md](../DEVELOPER.md)，设置体系见 [settings.md](../settings.md)。
