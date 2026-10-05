# Implementation Plan: 淡入淡出时长范围调整 + 播放/暂停按钮即时响应

**Input**: Feature specification from `D:\Users\shamiko\Documents\VScode\SelfMusic\spec\fade-range-instant-toggle\spec.md`

## Summary

在既有 Flutter 音乐播放器（Provider + just_audio）上做两项增量修改：（1）淡入淡出时长设置的有效域从 1~3s 收敛为 0.5~2s（滑条改造 + 读取钳制 + 文档同步）；（2）把播放/暂停按钮从"等淡出结束才翻转"改为"点击立即翻转"——在 PlayerProvider 中引入**目标状态（pending-pause）语义**，`toggle()` 不再阻塞等待渐变，音频渐变由统一的可打断音量梯度引擎在后台完成，渐变中再次点击反向打断。不新建任何业务文件，仅修改 5 个源文件 + 新增测试。

## Technical Context

**Language/Version**: Dart 3 / Flutter（frontend/ 子项目，含 Android/OHOS/Windows/Web 多端目标）  
**Primary Dependencies**: just_audio（音频播放、软件音量渐变）、provider（ChangeNotifier 状态分发）、sqlite3（LocalIndex 设置存储）  
**State Management**: Provider（ChangeNotifier）——既有架构，增量修改不引入新状态框架  
**Storage**: LocalIndex 键值表（`fade_enabled` / `fade_duration_ms`，字符串化整数）  
**Testing**: flutter_test；既有模式为"真实 LocalIndex + 真实 AudioPlayer 实例"（见 `frontend/test/player_audio_config_test.dart`）  
**Target Platform**: Android / OHOS / Windows / Web（淡入淡出为软件音量渐变，全平台一致）  
**Project Type**: 移动/桌面音乐播放器（Flutter 前端 + 后端服务）  
**Performance Goals**: 按钮点击→图标翻转 ≤100ms（同步 notifyListeners，实际一帧内）；渐变周期维持 16ms  
**Constraints**: 渐变体验不变（平滑无爆音）；非按钮路径行为不变；通知栏/媒体中心状态以实际播放状态为准  
**Scale/Scope**: 修改 5 个源文件 + 1 个文档文件 + 新增约 2 个测试文件；无数据库迁移、无新依赖  
**ArkTS 面**: 本特性不触及任何 `.ets`/ArkUI 代码（`frontend/ohos/entry/.../AvSessionBridge.ets` 等鸿蒙桥接的行为由 Dart 侧 `_syncSystemMedia()` 时机决定，本次保持不变）

## Project Structure

### Documentation (this feature)

```text
D:\Users\shamiko\Documents\VScode\SelfMusic\spec\fade-range-instant-toggle\
├── spec.md              # 需求规格（已确认）
├── plan.md              # 本文件
└── tasks.md             # 任务拆解（下一阶段生成）
```

### Source Code (repository root)

```text
D:\Users\shamiko\Documents\VScode\SelfMusic\
├── settings.md                                              # [修改] §3.2 淡入淡出行：范围 1~3s → 0.5~2s，默认值对齐代码（2000ms）
└── frontend\
    ├── lib\
    │   ├── data\local\app_settings.dart                     # [修改] fadeDurationMs 读取钳制 [500,2000]；注释同步
    │   ├── providers\player_provider.dart                   # [修改] 核心：目标状态语义 + 非阻塞 toggle + 可打断渐变引擎
    │   ├── screens\settings_screen.dart                     # [修改] 滑条 0.5~2.0s / divisions 15 / clamp
    │   ├── screens\player_screen.dart                       # [修改] 竖屏+横屏两处大按钮改订阅 provider 状态
    │   └── layout\mini_player_bar.dart                      # [不改] 已用 context.watch + player.playing，语义升级后自动生效
    └── test\
        ├── fade_toggle_test.dart                            # [新增] 即时翻转/反向打断/连点一致性/设置钳制
        └── fade_range_settings_test.dart                    # [新增] 滑条范围与档位（widget 测试）
```

**Structure Decision**: 遵循既有项目架构（Flutter + Provider，业务逻辑集中在 `PlayerProvider`，UI 只读 provider）。本特性为纯增量修改，不引入 MVVM/新目录/新文件分层，不迁移状态管理；新增文件仅限测试。播放页按钮当前直接订阅 `player.player.playerStateStream`（原始音频引擎流），需改为订阅 provider 的目标状态——这是本次唯一一处 UI 数据源调整。

## Complexity Tracking

（无宪法违规——不新增项目、不引入新框架、不新建业务目录）

## Research & Decisions

### RD-01 目标状态语义放在 `playing` getter 内部，而非新增独立字段

- **Decision**: `PlayerProvider.playing` 的语义升级为"界面/目标状态"：存在 pending-pause（`_fadingPause == true`）时返回 false，否则返回实际 `player.playing`。**不新增** `uiPlaying` 之类的平行 getter。
- **Rationale**: 全库审计后，该 getter 的外部消费方仅 `mini_player_bar.dart` 一处（watch 驱动，语义升级后自动获得即时翻转）；provider 内部对实际状态的判断（睡眠定时、断点保存、续播重建、`toggle` 分支等 5 处）全部直接引用底层 `player.playing`，不受 getter 语义变化影响。单一 getter 避免了两套"playing"并存导致的误用。
- **Alternatives considered**: 新增 `uiPlaying` getter 并让 UI 全部改用——被否决：留下旧 `playing` 这个"陷阱"给未来调用方；且现有唯一调用方反正要改语义，成本相同。

### RD-02 `toggle()` 改为非阻塞 + 渐变后台化

- **Decision**: `toggle()` 的暂停分支不再 `await _fadeOutThenPause()`：先置 `_fadingPause = true` 并同步 `notifyListeners()`（图标一帧内翻转），随后**不等待**地启动淡出引擎；实际 `pause()` 发生在淡出完成回调中，完成后复位 `_fadingPause`、再次 `notifyListeners()` 并 `_syncSystemMedia()`。播放分支维持现状（`play()` 本就不 await），但在打断淡出的场景从当前音量回升。方法签名保持 `Future<void>` 不变。
- **Rationale**: 消除"点击后按钮卡住整个淡出时长"的直接原因（await 渐变循环）；`_syncSystemMedia` 留在实际状态变化后调用，与规格假设（通知栏状态以实际播放为准）一致。
- **Alternatives considered**: 让 `toggle` 提前调用 `_syncSystemMedia()` 让通知栏也即时翻转——被否决：通知栏/AVSession 是系统级 UI，报"已暂停"但仍有声音反而矛盾，且规格已将其列为保持现状。

### RD-03 统一的可打断音量梯度引擎（Timer.periodic）

- **Decision**: 把现有两套渐变实现（`_fadeIn` 的 `Timer.periodic` 与 `_fadeOutThenPause` 的 while + `Future.delayed` 循环）合并为一个内部梯度引擎：单定时器（16ms 周期）驱动，属性含方向、起始音量、起始时刻、时长、完成回调；每次 tick 按elapsed 计算目标音量并 `setVolume`（平台调用失败静默吞掉，保证 headless 测试与平台异常不炸）。**所有渐变一律从 `player.volume` 当前值出发**（淡出不再预设 setVolume(1.0)，淡入仅在"从真实暂停恢复"时才归零起步），反向打断时自然形成"从当前音量平滑过渡"。`_fadeOutThenPause()` 保留为可 await 的入口：内部用 Completer，实际暂停完成时 complete；被反向打断时 complete 但不暂停。睡眠定时（`player_provider.dart:428`）与通知栏暂停（`:1968`）继续 await 它，行为不变。
- **Rationale**: while 循环无法被打断（只能靠 `_fadingPause` 守卫丢弃点击），Timer.periodic 模型天然支持"cancel + 反向重启"；从当前音量出发消除了打断瞬间的音量跳变（原淡出前置 setVolume(1.0) 在打断场景会造成爆音）。
- **Alternatives considered**: 保留 while 循环并加中断标志位轮询——被否决：两套渐变并存、打断时序难推理；用 `AnimationController` 驱动——被否决：引入 vsync 依赖，provider 层不便挂载。

### RD-04 反向打断的分支判定

- **Decision**: `toggle()` 入口删除 `if (_fadingPause) return;` 守卫。暂停分支内：`_fadingPause` 已为 true → 反向（cancel 渐变、`_fadingPause = false`、从当前音量淡入回升、notify；**不**再次调用 `play()`，引擎本就还在播）；否则启动淡出。播放分支内：仅当打断进行中的淡出时用"从当前音量淡入"，从真实暂停恢复维持"归零后淡入"（淡出完成时音量已复位 1.0，归零再升才是既有听感）。
- **Rationale**: 淡出期间引擎 `playing` 仍为 true，分支天然落在"暂停目标"下，只需用 `_fadingPause` 区分"再次暂停"还是"反悔恢复"；淡入期间点击则正常落入淡出分支并从当前音量下降——两个方向对称。
- **Alternatives considered**: 维持"渐变期间忽略点击"——被否决：用户已在需求澄清中选定反向打断；且按钮即时翻转后再忽略点击会出现"图标变了却点不动"的新割裂。

### RD-05 时长范围与越界值策略

- **Decision**: `AppSettings.fadeDurationMs` 读取时钳制到 [500, 2000]（`?? 2000` 默认值保持）；设置页滑条 `min: 0.5, max: 2.0, divisions: 15`（0.1s 步进、16 档），显示值 clamp(0.5, 2.0)，标签维持一位小数格式。历史越界存储（如 3000ms）不做迁移，读取即钳制，用户下次拖动自然写回合法值。
- **Rationale**: 钳制在读取口统一收口，滑条/UI/渐变引擎三者自动一致，无需迁移脚本；0.1s 步进与新范围匹配且与既有"一位小数"显示格式对齐。
- **Alternatives considered**: 启动时一次性迁移越界值——被否决：为极少数旧值引入一次性写入逻辑不值得。

### RD-06 文档默认值对齐

- **Decision**: `settings.md` §3.2 淡入淡出行除范围外，默认值按代码事实写作"2000 ms"（现文档写"1000 ms"，与 `app_settings.dart` 的 `?? 2000` 不符，属既有笔误，本次一并修正）。
- **Rationale**: 文档与代码矛盾会误导后续开发；规格 FR-009 要求文档同步。
- **Alternatives considered**: 只改范围不动默认值描述——被否决：留着已知错误不符合规格意图。

### RD-07 测试策略（真实 Timer + 真实 AudioPlayer 的可行性）

- **Decision**: 新增测试沿用项目既有"真实实例"模式：真实 `AudioPlayer`（无源状态下 play/pause/setVolume 的平台异常由 RD-03 的静默守卫兜住）+ `testWidgets` 的 FakeAsync（`tester.pump(Duration)` 推进 16ms tick 与渐变时长）。断言三层：①点击后 `provider.playing`（目标态）立即翻转；②淡出完成前底层 `provider.player.playing` 仍为 true、完成后为 false；③打断后引擎从未暂停且目标态立即回正。设置钳制用真实 LocalIndex 直测 getter；滑条用 widget 测试断言 min/max/divisions/label。
- **Rationale**: 与仓库现有 `player_audio_config_test.dart` 等保持同构，不引入 mock 框架；FakeAsync 下 Timer.periodic 可精确推进，无真实睡眠等待。
- **Alternatives considered**: 注入假播放器接口——被否决：provider 深度耦合 just_audio 具体类型，为小特性开抽象口子得不偿失。

## Data Model

### 持久化实体（既有，收敛有效域）

| 键 | 类型 | 有效域 | 默认 | 说明 |
|----|------|--------|------|------|
| `fade_enabled` | '1'/'0' | — | '1' | 淡入淡出开关，不变 |
| `fade_duration_ms` | int（字符串化） | **[500, 2000]**（读取钳制） | 2000 | 渐变时长；越界值（如旧版 3000）读取时取最近边界 |

### 运行时状态（PlayerProvider 内部）

| 字段 | 类型 | 语义 |
|------|------|------|
| `_fadingPause` | bool | **pending-pause 意图位**：true = 用户/系统已请求暂停、实际 `pause()` 尚未执行（淡出进行中）。对外经由 `playing` getter 表达为目标态"已暂停" |
| `_fadeTimer` | Timer? | 梯度引擎定时器（16ms 周期），cancel 即打断 |
| 梯度上下文（方向/起始音量/起始时刻/时长/完成回调） | 引擎内部 | 单一活跃渐变，新渐变启动前必先 cancel 旧的 |
| fade-out 的 Completer | 内部 | `_fadeOutThenPause()` 返回的 Future：实际暂停完成或被打断时 complete |

### 状态迁移（目标态 vs 实际态）

```text
[实际=playing, 目标=playing] --点击暂停--> [实际=playing, 目标=paused] --淡出完成--> [实际=paused, 目标=paused]
       ↑                                        |
       └──────────── 渐变中再点击（反向打断）──────┘（引擎从未暂停，音量从当前值回升）

[实际=paused, 目标=paused] --点击播放--> [实际=playing, 目标=playing]（音量归零后淡入）
[淡入进行中=实际playing/目标playing] --点击暂停--> 从当前音量淡出 → 实际=paused
```

- 淡入淡出关闭时不存在中间态：目标态与实际态同步翻转（现状不变）。
- 非按钮路径（睡眠定时/通知栏暂停）复用同一条 pending-pause 迁移，仅不要求"按钮即时"（它们本就以实际暂停完成为准）。

## Contracts & Interfaces

### 对外契约变更

| 接口 | 变更 | 消费方影响 |
|------|------|-----------|
| `PlayerProvider.playing` (getter) | 语义：实际态 → **目标态**（`_fadingPause ? false : player.playing`） | `mini_player_bar.dart:210,213` 自动获得即时翻转（watch 已就位）；无其他外部消费方 |
| `PlayerProvider.toggle()` | 行为：不再阻塞至渐变结束；渐变中点击=反向打断；签名 `Future<void>` 不变 | 调用方（播放页两处按钮、迷你条）无需改调用方式 |
| `AppSettings.fadeDurationMs` (getter) | 读取钳制 [500, 2000] | 滑条与渐变引擎自动一致；越界旧值自动收敛 |
| `_fadeOutThenPause()`（内部） | 返回时机不变（实际暂停完成时），新增"被打断即完成（不暂停）" | 睡眠定时 `:428`、`pauseFromNotifier` `:1968` 语义保持 |
| `resumeFromNotifier` / `pauseFromNotifier` / `stopFromNotifier` / `shutdown` / `applyAudioConfig` | 清理路径需在 cancel 渐变的同时 complete 挂起的 Completer，避免悬挂 Future | 行为不变，防御性补齐 |

### UI 数据源调整（播放页两处大按钮）

- `player_screen.dart:786-802`（竖屏）与 `:1046-1062`（横屏）：`StreamBuilder<PlayerState>(stream: player.player.playerStateStream)` 改为监听 provider（`ListenableBuilder`/`AnimatedBuilder` + `player.playing`），图标分支与尺寸样式不变。

### 设置滑条契约（settings_screen.dart）

- `value: (fadeDurationMs / 1000).clamp(0.5, 2.0)`；`min: 0.5`；`max: 2.0`；`divisions: 15`；`label` 一位小数（如"1.2 秒"）；写入 `(v * 1000).round()`。

### 不变式（验收锚点）

1. 任意时刻点击按钮都有响应，目标态立即翻转；无被忽略的点击窗口。
2. 渐变期间 `provider.playing`（目标态）与 `provider.player.playing`（实际态）允许不一致，除此之外两者恒一致。
3. 实际 `pause()` 只发生在淡出完成（或淡出被切歌/停止/重建路径取消）时。
4. 音量渐变曲线连续，任何打断点都不出现音量跳变。

### 测试交付契约

| 测试文件 | 覆盖 | 关键断言 |
|---------|------|---------|
| `frontend/test/fade_toggle_test.dart` | US1/US2：即时翻转、淡出后真停、反向打断、连点奇偶一致、fade 关闭直切 | 点击后目标态同步翻转；FakeAsync 推进至淡出完成前后实际态分别为 true/false；打断后引擎未暂停；`setVolume`/`pause` 平台异常不外溢 |
| `frontend/test/fade_range_settings_test.dart` | US3：滑条范围/档位/标签、读取钳制、持久化往返 | 滑条 min 0.5 / max 2.0 / divisions 15；LocalIndex 写 3000 读 2000、写 500 读 500；写后重读一致 |

回归面：`player_audio_config_test.dart`、`play_lifecycle_test.dart`、`mini_player_gesture_test.dart`、`player_landscape_test.dart` 必须保持通过（`playing` 语义升级与按钮数据源改动的回归哨兵）。
