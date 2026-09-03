# 时音 PC（Windows）桌面适配设计

- 日期：2026-09-04
- 分支：`feature/pc-desktop-adaptation`
- 状态：已与用户确认的设计（方案 A：统一代码库 + 桌面 Shell）

## 1. 背景与目标

时音当前以 Android 车机为主战场，`windows/` 目录与 `just_audio_windows` 已就绪，但桌面体验停留在"手机布局拉宽"：横向列表需要 Shift+滚轮才能滚动、无桌面级导航骨架、窗口尺寸不记忆、桌面歌词/托盘等桌面特性缺失。

**目标定位：完整桌面体验（QQ 音乐 PC 式结构）**，范围为 Windows 深度适配；macOS/Linux 保证能跑不崩即可，不做专项验证。

**硬性约束：**

1. 车机模式（横屏左分栏）与手机模式（悬浮胶囊底栏）的行为**一行不改**，零回归。
2. 本项目车机/平板均为 Android，PC 为 Windows——**形态判定用平台，密度判定用窗口宽度**，两层解耦，杜绝误判。
3. 页面级宽屏改动全部收敛在断点分支内，禁止散落 `Platform.isWindows` 判断到业务页面。

## 2. 设备判定

新增 `lib/ui/platform_form_factor.dart`（或并入现有 `adaptive_layout.dart`）：

```dart
/// 桌面形态：仅由操作系统决定，与窗口大小无关
const isDesktopFormFactor =
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
```

- `isDesktopFormFactor == true` → 桌面 Shell（侧栏 + 底部播放栏）。
- Android（手机/平板/车机）恒为 false → 走现有路径：车机横屏布局、宽 ≥720 的 NavigationRail 布局、窄屏胶囊底栏，全部保持现状。
- `carModeEnabled` 在桌面端强制视为关闭（布局锁定横屏等副作用一并屏蔽）。
- 现有 `app_shell.dart:176` 的 `useNavRail = width >= 720` 分支仅服务 Android 平板，保持不动；桌面 Shell 是与之并列的新通路。

## 3. 断点体系

扩展现有 `lib/ui/adaptive_layout.dart`，统一 Material 断点（逻辑像素宽度）：

| 名称 | 范围 | 用途 |
|---|---|---|
| compact | < 600 | 单列，横轨 |
| medium | 600–839 | 窄网格（歌单封面等 2 列） |
| expanded | 840–1199 | 3 列；**横轨转网格起点（仅桌面形态）** |
| large | 1200–1599 | 4 列网格 |
| expandedDesktop | ≥ 1600 | 5+ 列，上限按内容定 |

提供 `columnsForWidth(width, {min, max})` 之类的工具函数，页面不再各自写 `LayoutBuilder` 阈值（现有 `home_page` 内 1050/650、`rank_page` 内 600 等散点阈值不强制回改，仅在新改动涉及处顺手收敛）。

## 4. 桌面骨架（全新代码）

```
┌────────┬─────────────────────────────────┐
│  侧栏   │                                 │
│ 推荐    │         内容区                   │
│ 排行榜  │   （推荐流 / 歌单网格 / 电台…）    │
│ 电台    │                                 │
│ 我的音乐 │                                 │
│ 设置    ├─────────────────────────────────┤
│        │ 底部播放栏：封面 标题歌手 进度条    │
│        │ 播放/切歌 音量 队列 桌面歌词 开关   │
└────────┴─────────────────────────────────┘
```

新文件（`lib/ui/desktop/`）：

- `desktop_shell.dart` — 三段式骨架；`isDesktopFormFactor` 时在 `AppShell` 中替换现有布局选择。
- `desktop_nav_sidebar.dart` — 左侧导航。项：推荐 / 排行榜 / 电台 / 我的音乐 / 已下载 / 设置；当前项高亮，悬停反馈。
- `desktop_player_bar.dart` — 底部播放栏（高约 72–80）：封面+标题+歌手、播放/暂停/上一首/下一首、进度条（可拖拽）、音量滑杆、播放队列按钮、桌面歌词开关、封面点击进入全屏播放页。桌面模式下不再渲染悬浮 MiniPlayer。

**页面提升**：HomePage 内部"推荐/排行榜/电台"子 tab 状态提升（回调或轻量 controller），使侧栏可直接切换；保留 `_PersistentTabPane`（Offstage+TickerMode）保活机制。搜索入口为侧栏顶部搜索胶囊（与现有 `_SmartSearch` 样式一致），点击进入现有搜索页。

## 5. 页面适配：横轨 → 网格 + 滚轮横滚

- `AppHorizontalRail` 升级为自适应：**仅桌面形态且宽 ≥840（expanded 起）**渲染为 `Wrap`/`GridView`，列数按断点；非桌面形态（手机/平板/车机）行为与现状完全一致，落实零回归约束。
- 滚轮横滚处理对横轨全平台生效（触屏无滚轮，天然无副作用）。
- 保留横轨的场景（窄窗、EQ 滑杆、搜索分类条等）统一加滚轮横滚：`Listener` 捕获 `PointerScrollEvent` → `ScrollController.jumpTo`（带动画可选），Shift+滚轮行为不变。
- `rank_page`、`search_page` 的零散横向 ListView 逐个接入同一套横滚处理与网格转换。
- 网格卡片补齐 `MouseRegion` 手型光标与悬停高亮（横轨已有基础）。

## 6. 窗口管理（新增依赖 `window_manager`）

- 最小尺寸 960×600（保证桌面骨架成立），默认 1280×800，标题"时音"。
- 记忆上次窗口大小与位置（本地持久化），启动恢复；提供"重置窗口"入口（设置页）。
- `windows/runner/main.cpp` 的 1280×720 硬编码保留为首帧兜底，不做 runner 层定制。

## 7. 桌面歌词（解锁 Android-only → Windows）

- `desktop_lyrics_service.dart` 的 `isSupportedPlatform` 增加 Windows。
- 采用 `desktop_multi_window`：独立无边框、始终置顶、可拖动、可锁定的小窗（单行卡拉OK式歌词）。
- 主窗→歌词窗经 method channel 推送当前歌词行；歌词窗不初始化 Rust 引擎，仅渲染文本。
- 入口：底部播放栏开关 + 播放页按钮；设置页提供字号/锁定行为配置。

## 8. 托盘与后台常驻（新增依赖 `system_tray`）

- 关闭按钮默认**最小化到托盘**（音乐不间断）；托盘菜单：显示/隐藏主窗、播放/暂停、上一首、下一首、退出。
- 设置页新增"关闭时最小化到托盘"开关，关闭后点 X 直接退出。
- 与 `window_manager` 的 `setPreventClose` 协同实现拦截。

## 9. 快捷键补全与 Android-only 降级

- 已有 `AppShortcutScope`（空格播放/暂停、←→切歌、输入框聚焦时不拦截）。新增：↑↓ 音量、Ctrl+F 聚焦搜索、Ctrl+1/2/3 切换侧栏主项、Enter 进入播放页。
- Android-only 功能（蓝牙歌词、超级歌词、音频特效 EQ、设备信息、应用自更新）在桌面端逐一确认：入口隐藏或置灰并提示"暂不支持"，不得崩溃。EQ 若 `just_audio_windows` 原生可支持则列为后续项，本轮不承诺。

## 10. 测试与验收

- 每个子任务完成：`flutter analyze` 零新告警 + `flutter test` 通过 + 三形态自检（窄窗 <600 模拟手机、≥1150 超宽 + carMode 模拟车机、默认 1280×800 桌面 Shell）。
- 子任务硬约束写进派发提示：**禁止修改窄屏/车机路径代码**；涉及共享组件时须给出三形态对照说明。
- 验收标准：不按 Shift 仅滚轮即可横向滚动所有横轨；Windows 关窗后托盘常驻且播放不断；桌面歌词置顶显示且可锁定；车机/手机形态截图对比适配前无差异。

## 11. 任务分解（供实施计划展开）

| # | 任务 | 依赖 |
|---|---|---|
| 1 | 基础设施：平台判定 + 断点工具 + window_manager（最小/记忆尺寸） | — |
| 2 | 桌面骨架：desktop_shell + 侧栏 + 底栏播放栏 + 页面提升 | 1 |
| 3 | 横轨网格化 + 滚轮横滚（AppHorizontalRail 改造 + 各页接入） | 1 |
| 4 | 快捷键补全 + Android-only 降级清单 | 2 |
| 5 | 桌面歌词 Windows 解锁 | 2（入口）、1 |
| 6 | 托盘常驻 | 1 |

任务 3 可与 2 并行；5、6 相对独立。执行采用子代理驱动开发（每任务独立派发以控制上下文长度）。

## 12. 后备方案

若桌面 Shell 最终效果不满意，备选升级路径为方案 B（`lib/ui/desktop/` 下独立 PC 页面套件）。骨架组件、断点体系、窗口/托盘/歌词基础设施在两案间完全复用，切换成本已在本方案中最小化。
