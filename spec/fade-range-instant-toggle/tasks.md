---
description: "任务清单：淡入淡出时长范围调整 + 播放/暂停按钮即时响应"
---

# Tasks: 淡入淡出时长范围调整 + 播放/暂停按钮即时响应

**Input**: Design documents from `D:\Users\shamiko\Documents\VScode\SelfMusic\spec\fade-range-instant-toggle\`（spec.md + plan.md 均已确认）
**Prerequisites**: plan.md（必需）、spec.md（用户故事 P1/P2/P3）

**Tests**: 本清单包含测试任务——依据已批准的 plan.md「测试交付契约」（`frontend/test/fade_toggle_test.dart` 与 `frontend/test/fade_range_settings_test.dart` 为设计交付物），测试任务置于各故事实现之前（先写、允许先失败）。

**Organization**: 任务按用户故事分组，可独立实现与验证。项目为 Flutter 工程（`frontend/`），鸿蒙侧 `.ets` 代码零改动。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行（不同文件、无未完成依赖）
- **[Story]**: 所属用户故事（US1/US2/US3）
- 路径均为仓库根相对路径

## Path Conventions

- 多项目仓库：Flutter 前端位于 `frontend/`（本特性全部改动），鸿蒙壳工程位于 `frontend/ohos/`（仅部署验证涉及）
- 任务中的文件路径均相对仓库根 `D:\Users\shamiko\Documents\VScode\SelfMusic\`
- Flutter 工具链：优先 PATH 中的 `flutter`；不可用时使用 `D:\Users\shamiko\Documents\Flutter\Harmony\bin\flutter.bat`（见 build-ohos.ps1）

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: 建立改动前基线，确认工具链可用

- [X] T001 基线验证：在 frontend/ 运行 `flutter analyze`（零 error 基线）与既有回归哨兵测试 `flutter test test/player_audio_config_test.dart test/play_lifecycle_test.dart test/mini_player_gesture_test.dart test/player_landscape_test.dart`，记录基线结果；若本机 `flutter` 不在 PATH，使用 build-ohos.ps1 中的工具链 `D:\Users\shamiko\Documents\Flutter\Harmony\bin\flutter.bat`（基线：analyze 0 error/2 info 既有；哨兵 mini_player_gesture 3/3 ✓、player_landscape 1/1 ✓、player_audio_config 0/3 与 play_lifecycle 0/4 为 Windows 环境既有失败——tearDown 删临时目录时 db-writer 子进程句柄未释放，errno=32，与代码逻辑无关）

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: 所有用户故事共同依赖的有效域收口与渐变基础设施重构

**⚠️ CRITICAL**: 本阶段完成后才能开始用户故事

- [X] T002 [P] 收敛淡入淡出时长有效域：`AppSettings.fadeDurationMs` 读取钳制到 [500, 2000]（`?? 2000` 默认值保持），同步更新该字段注释（"建议 1000~3000" → 有效域 [500, 2000]），文件：frontend/lib/data/local/app_settings.dart
- [X] T003 重构渐变基础设施：将 `_fadeIn`（Timer.periodic）与 `_fadeOutThenPause`（while + Future.delayed）合并为统一的可打断音量梯度引擎（16ms 周期单定时器、一律从 `player.volume` 当前值出发、`setVolume`/`pause` 平台调用异常静默吞掉、用 Completer 保持 `_fadeOutThenPause()` 可 await），本步**外部行为等价**（淡入听感不变、淡出仍等待至实际暂停），文件：frontend/lib/providers/player_provider.dart

**Checkpoint**: 有效域收口 + 可打断引擎就绪，用户故事可开始

---

## Phase 3: User Story 1 - 点击播放/暂停按钮立即翻转 (Priority: P1) 🎯 MVP

**Goal**: 点击按钮图标一帧内翻转目标态；淡出/淡入在后台完成，实际暂停发生在淡出结束
**Independent Test**: 淡入淡出开（2s）播放中点暂停→图标立即变播放、音乐约 2s 渐弱至停；点播放→图标立即变暂停、声音渐起

### Tests for User Story 1

- [X] T004 [US1] 新增即时翻转测试（先写，允许失败）：fade 开启（短时长如 500ms）点击暂停后 `provider.playing` 立即为 false 而底层 `provider.player.playing` 仍为 true，FakeAsync 推进至淡出完成后实际态变 false；fade 关闭时点击立即直切（目标态与实际态同步翻转），文件：frontend/test/fade_toggle_test.dart

### Implementation for User Story 1

- [X] T005 [US1] `playing` getter 升级为目标态语义：`_fadingPause ? false : player.playing`（provider 内部对实际态的既有判断保持直引 `player.playing` 不动），文件：frontend/lib/providers/player_provider.dart
- [X] T006 [US1] `toggle()` 暂停分支非阻塞化：立即置 `_fadingPause = true` 并同步 `notifyListeners()`，淡出改为不等待地后台启动；淡出完成回调中执行实际 `pause()`、音量复位 1.0、`_fadingPause = false`、再次 `notifyListeners()` 并 `_syncSystemMedia()`；播放分支维持 `play()` 不 await + 淡入，文件：frontend/lib/providers/player_provider.dart
- [X] T007 [P] [US1] 播放页两处大按钮数据源改造：竖屏（约 786-802 行）与横屏（约 1046-1062 行）的 `StreamBuilder<PlayerState>(stream: player.player.playerStateStream)` 改为监听 provider（ListenableBuilder/AnimatedBuilder + `player.playing`），图标、尺寸、tooltip 不变，文件：frontend/lib/screens/player_screen.dart
- [X] T008 [US1] 故事检查点：`flutter test test/fade_toggle_test.dart` 与回归哨兵（player_audio_config / play_lifecycle / mini_player_gesture / player_landscape）全部通过，文件：frontend/test/fade_toggle_test.dart

**Checkpoint**: US1 独立可交付——按钮即时响应 + 后台渐变（MVP）

---

## Phase 4: User Story 2 - 渐变进行中反向打断 (Priority: P2)

**Goal**: 淡出中再点击→取消暂停、音量从当前值平滑回升（引擎从未暂停）；淡入中再点击→从当前音量淡出暂停；连点奇偶一致
**Independent Test**: 播放中点暂停后 0.5s 内再点一次→按钮立即回播放中、音量从当前位置渐回而非静默重启

### Tests for User Story 2

- [X] T009 [US2] 增补反向打断测试（先写，允许失败）：淡出进行中再点→目标态立即回 true、底层引擎从未暂停、音量从当前值回升；淡入进行中再点→从当前音量淡出后实际暂停；2s 内多次快速交替点击→每次都响应且最终状态与点击奇偶性一致，文件：frontend/test/fade_toggle_test.dart

### Implementation for User Story 2

- [X] T010 [US2] 实现反向打断：删除 `toggle()` 入口的 `if (_fadingPause) return;` 守卫；暂停分支内 `_fadingPause` 已为 true 时→cancel 渐变、复位 `_fadingPause = false`、从当前音量淡入回升并 notify（不再次调用 `play()`）；播放分支在打断进行中淡出时→从当前音量淡入（真实暂停恢复维持归零淡入），文件：frontend/lib/providers/player_provider.dart
- [X] T011 [US2] 打断/清理路径补齐 Completer：`stopFromNotifier`、`shutdown`、`applyAudioConfig`、切歌装载等已有 cancel `_fadeTimer` 的路径，同步 complete 挂起的淡出 Future（complete 但不暂停），避免悬挂，文件：frontend/lib/providers/player_provider.dart
- [X] T012 [US2] 故事检查点：打断用例与 `flutter test test/fade_toggle_test.dart` 全部用例通过，文件：frontend/test/fade_toggle_test.dart

**Checkpoint**: US1 + US2 均独立可测，任意时刻点击均有响应

---

## Phase 5: User Story 3 - 淡入淡出时长范围 0.5~2s (Priority: P3)

**Goal**: 滑条范围 0.5~2.0s、0.1s 步进（16 档）、一位小数标签；越界旧值读取钳制；文档同步
**Independent Test**: 滑条拖动验证 min 0.5 / max 2.0；写 3000 读 2000；重启后设置保留

### Tests for User Story 3

- [X] T013 [P] [US3] 新增范围与钳制测试（先写，允许失败）：真实 LocalIndex 写 `fade_duration_ms=3000` 读 2000、写 500 读 500、写后重读一致；设置页滑条 min 0.5 / max 2.0 / divisions 15 / 标签一位小数，文件：frontend/test/fade_range_settings_test.dart

### Implementation for User Story 3

- [X] T014 [US3] 设置页滑条改造：`value` clamp(0.5, 2.0)、`min: 0.5`、`max: 2.0`、`divisions: 15`、label 一位小数、写入 `(v*1000).round()`，副标题时长显示逻辑不变，文件：frontend/lib/screens/settings_screen.dart
- [X] T015 [P] [US3] 文档同步：settings.md §3.2 淡入淡出行改为"0.5~2 s"、默认值按代码事实改为 2000 ms（修正既有"1000 ms"笔误），文件：settings.md
- [X] T016 [US3] 故事检查点：`flutter test test/fade_range_settings_test.dart` 通过，文件：frontend/test/fade_range_settings_test.dart

**Checkpoint**: 全部用户故事完成

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: 跨故事收口

- [X] T017 [P] 语义走查与注释收口：全库 grep 确认 `playing` getter 无新增误用（provider 内部实际态判断仍直引 `player.playing`）；核对 player_provider.dart 渐变段落注释与新行为一致（含 `_fadeOutThenPause` 的文档注释）；移除过时描述，文件：frontend/lib/providers/player_provider.dart

---

## Phase 7: Verification

<!-- verification_scope: build-only -->

**Purpose**: 编译、测试与部署验证（按用户选择：仅构建验证，不含 UI 验证）

- [X] T018 静态检查与全量测试：在 frontend/ 运行 `flutter analyze`（零 error）与 `flutter test` 全量通过，发现错误修复后重跑直至绿，文件：frontend/（验证 2026-10-04：analyze 0 error/2 既有 info；新增测试 9/9 绿；全量 58 个失败均为 Windows errno=32 环境类且经改动前后对照实验证实与特性无关、无新增失败）
- [X] T019 构建验证：使用 flutter-ohos 工具链（`D:\Users\shamiko\Documents\Flutter\Harmony\bin\flutter.bat`，见 build-ohos.ps1）在 frontend/ 构建 debug HAP（`flutter build hap --debug --target-arch=arm64`），修复编译错误直至成功，文件：frontend/build/ohos/（验证 2026-10-04：实际命令为 `flutter build hap --debug --target-platform ohos-arm64`——本机工具链无 `--target-arch` 选项，语义等价；构建成功，产物 frontend/build/ohos/hap/entry-default-signed.hap）
- [ ] T020 部署验证：将构建产物部署到已连接的鸿蒙设备/模拟器并确认可启动（优先 start_app；或 hdc 安装后启动）；无已连接设备/模拟器时在验证报告中明确注明原因与跳过证据，文件：frontend/ohos/（验证 2026-10-04：**跳过——无可用设备**：物理设备未连接（hdc 枚举 No active devices），4 个模拟器实例全部 stopped 且所需系统镜像 HarmonyOS 7.0.0(26.0.0) 未下载、启动失败，详见验证报告）

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: 无依赖，立即开始
- **Foundational (Phase 2)**: 依赖 Setup 完成——**阻塞所有用户故事**
- **User Stories (Phase 3–5)**: 均依赖 Foundational 完成
  - US1、US2 为同一函数族（toggle/渐变引擎）的递进改造，必须按 US1 → US2 顺序
  - US3 仅依赖 T002（有效域收口），可与 US1/US2 并行推进
- **Polish (Phase 6)**: 依赖全部用户故事完成
- **Verification (Phase 7)**: 依赖 Polish 完成（build-only 范围：构建 + 部署，无 UI 验证任务）

### User Story Dependencies

- **User Story 1 (P1)**: Foundational（T003 可打断引擎）后开始；无跨故事依赖
- **User Story 2 (P2)**: 依赖 US1 的非阻塞 toggle 落地（T006）——反向打断在其分支结构上实现；断点后仍独立可测
- **User Story 3 (P3)**: 依赖 T002 钳制；与 US1/US2 文件不相交，可全程并行

### Within Each User Story

- 测试任务先写（允许先失败）→ 实现 → 故事检查点（测试转绿）
- provider 语义（T005）先于 toggle 行为（T006）先于 UI 接线验证（T007/T008）

---

## ⚡ Parallel Execution Guide

| Phase | Tasks | Required Files | Execution Notes |
|-------|-------|----------------|-----------------|
| Foundational | T002 ∥ T003 | app_settings.dart ∥ player_provider.dart | 不同文件可并行；T003 为关键路径 |
| US1 内 | T007 ∥ T005/T006 | player_screen.dart ∥ player_provider.dart | 按钮接线与 provider 语义改造不同文件；T007 完成后需 T005 生效才体现即时翻转 |
| US3 整体 | T013/T014/T015 ∥ US1/US2 | settings_screen.dart、settings.md、fade_range_settings_test.dart | US3 仅依赖 T002，与 provider 侧工作完全并行 |
| Polish | T017 ∥ 无 | player_provider.dart | 单任务收口 |

## Parallel Example

```bash
# Foundational 两条线并行：
Task: T002 "AppSettings.fadeDurationMs 读取钳制 [500,2000]" → frontend/lib/data/local/app_settings.dart
Task: T003 "统一可打断音量梯度引擎（行为等价）"            → frontend/lib/providers/player_provider.dart

# US3 与 US1/US2 并行（不同文件族）：
Task: T013/T014/T015（滑条 + 文档） → settings_screen.dart / settings.md / fade_range_settings_test.dart
Task: T004–T012（provider + 播放页按钮） → player_provider.dart / player_screen.dart / fade_toggle_test.dart
```

## Implementation Strategy

### MVP First (User Story 1 Only)

1. 完成 Phase 1: Setup（基线）
2. 完成 Phase 2: Foundational（**关键阻塞**：T002 有效域收口 + T003 可打断引擎）
3. 完成 Phase 3: US1（即时翻转 + 后台渐变）
4. **STOP and VALIDATE**: T008 检查点独立验证 US1
5. 可交付/演示（按钮即时响应即核心痛点解决）

### Incremental Delivery

1. Setup + Foundational → 基础就绪
2. + US1 → 独立验证 → MVP 交付
3. + US2 → 独立验证 → 交互完备（反向打断）
4. + US3 → 独立验证 → 范围/文档收口
5. Polish → 全库走查；Verification → 构建 + 部署（build-only）

---

## Notes

- [P] 任务 = 不同文件且无未完成依赖；同文件任务（如 T005/T006/T010/T011 均在 player_provider.dart）必须串行
- [Story] 标签映射到 spec.md 用户故事，保证可追溯
- 每个故事可独立完成与验证；故事检查点（T008/T012/T016）即独立验收口
- 测试先写、允许先失败；实现后必须转绿
- 每完成一个任务或逻辑组后提交（遵循仓库既有提交风格）
- 任何时刻可在检查点停下做独立验证
- 避免：模糊任务、同文件并行冲突、破坏故事独立性的跨故事依赖
- 验证阶段为 build-only（用户已选）：构建 + 部署，**不含** UI 验证任务

## Summary Report

- **总任务数**: 20（T001–T020）
- **按故事统计**: US1 = 5（T004–T008）；US2 = 4（T009–T012）；US3 = 4（T013–T016）；Setup = 1；Foundational = 2；Polish = 1；Verification = 3
- **并行机会**: T002∥T003；T007∥T005/T006；US3 整体与 US1/US2 并行（唯一前置 T002）
- **独立测试判据**: 每个故事均有独立测试文件/用例（US1/US2 共用 fade_toggle_test.dart 的分层用例，US3 用 fade_range_settings_test.dart），故事检查点任务（T008/T012/T016）可单独运行验证
- **建议 MVP 范围**: T001 → T002/T003 → US1（T004–T008）即交付核心价值（按钮即时响应）；US2 为体验完备、US3 为独立小改
- **关键路径**: T001 → T003 → T004 → T005 → T006 → T008 → T009 → T010 → T011 → T012 → T017 → T018 → T019 → T020
