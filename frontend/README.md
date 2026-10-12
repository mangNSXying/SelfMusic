# SelfMusic 前端（Flutter）

跨平台客户端：Linux 桌面 + Android + Windows + HarmonyOS NEXT（`lib/` 全为可换主题自适应 Dart 代码；鸿蒙经三方分支 + 平台收口层接入，PoC 验收已通过）。
目录结构与职责注释见 [../DEVELOPER.md「项目结构」](../DEVELOPER.md#项目结构)，整体架构、数据模型与 API 契约见 [../DEVELOPER.md「总体架构」](../DEVELOPER.md#总体架构) 及「[数据模型](../DEVELOPER.md#数据模型)」。

## 运行

```bash
flutter pub get
flutter run -d linux                 # Linux 桌面（音频后端 media_kit，libmpv 随包分发）
flutter run -d <设备id>              # Android（后端联调加 --dart-define=API_BASE_URL=http://<宿主IP>:18089）
flutter run -d windows               # Windows 桌面（或仓库根 run-windows.bat）
```

## 常用命令

```bash
flutter analyze               # 静态检查
flutter test                  # 单元/组件测试
flutter build linux --debug   # Linux 出包（验证用 --release）
flutter build apk --debug     # Android 出包
flutter build windows --debug # Windows 出包
# 鸿蒙：需三方 ohos 分支 Flutter + DevEco 工具链，见 DEVELOPER.md「鸿蒙适配」；
#   debug：flutter build hap --debug；release 出包：仓库根 .\build-ohos.ps1 [hap]
```

## 改代码前必读

| 改动涉及 | 必看 |
|---------|------|
| 本地库表结构 / 任何写操作 | [DEVELOPER.md「客户端本地数据层（SQLite 写隔离）」](../DEVELOPER.md#客户端本地数据层sqlite-写隔离) —— 写必须走写隔离，读改写用 `op` |
| 扫描 / 元数据解析 | [DEVELOPER.md「客户端扫描与元数据」](../DEVELOPER.md#客户端扫描与元数据实现要点) —— 跨 isolate 只传可序列化参数 |
| 同步 / 缓存落盘 | [DEVELOPER.md「客户端同步与缓存批处理」](../DEVELOPER.md#客户端同步与缓存批处理) |
| 新增平台能力 | [DEVELOPER.md「平台收口层」](../DEVELOPER.md#平台收口层libplatform) —— 禁止在业务层写平台判断 |

设置项见 [../settings.md](../settings.md)。
