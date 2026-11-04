# OpenCC 词库（简繁显示）

本目录是 SelfMusic 的简繁显示词库，来自
[OpenCC](https://github.com/BYVoid/OpenCC) **ver.1.4.2**（Apache-2.0）。

| 文件 | 用途 | 大小 |
| --- | --- | --- |
| `TSCharacters.txt` | 繁体 → 简体：单字表 | ~102 KB |
| `TSPhrases.txt` | 繁体 → 简体：词组表（优先于单字） | ~9 KB |
| `STCharacters.txt` | 简体 → 繁体：单字表 | ~35 KB |
| `STPhrases.txt` | 简体 → 繁体：词组表（优先于单字） | ~985 KB |

## 为什么内置文本词库

- 项目覆盖 Android / Linux / Windows / OHOS，原生 OpenCC 在 OHOS 没有可用产物，
  也不能依赖 native assets 工具链，因此使用**纯 Dart 解析 + 文本词库**。
- 运行时只读 Flutter asset，不联网、不写盘。
- 启动后后台预热（搜索折叠始终需要），不阻塞首帧；「原文」模式只关闭展示转换，
  默认设置下也能简繁互搜。

## 更新步骤

1. 选定新的 OpenCC release tag（当前 `ver.1.4.2`）。
2. 从
   `https://raw.githubusercontent.com/BYVoid/OpenCC/<tag>/data/dictionary/<file>`
   重新下载上表四个文件，保持文件名不变。
3. 同步更新本 README 与 `LICENSE`。
4. 运行 `flutter test test/zh_variant_test.dart` 校验基础转换。

转换实现位于 `lib/utils/zh_variant.dart`：词组最长匹配优先，单字表兜底；
只影响展示，不写回数据库/音频标签。
