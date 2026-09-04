# PC 端体验与歌单布局优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 清理排查阶段冗余调试日志，重构 Windows 桌面歌词为纯净透明悬浮字与悬停播控条，补全 PC \"我的\"页面 Hover 与手型光标交互，并将 PC 歌单详情页升级为高密度专业表格列表（Table View）。

**Architecture:** 
- 日志清理集中于 `music_api.dart`、`windows_desktop_lyrics_bridge.dart`、`lyrics_overlay_window.dart` 及 `player_controller.dart`。
- 桌面歌词基于 `windowManager.setBackgroundColor(Colors.transparent)` 解锁真透明通道，常态无底色（0 框线），悬停淡入半透磨砂浮岛与播控按钮，经多窗口信道向主窗派发 `controlPlayback`。
- PC 我的页面为快捷磁贴及歌单卡片追加 `MouseRegion(cursor: SystemMouseCursors.click)`、Hover 动效与 `Material` 承载。
- PC 歌单详情页在 `isDesktopFormFactor` 下使用 `_DesktopSongTableView`，以 44px 紧凑表头+表格行呈现序号、歌名、歌手、专辑、时长/悬浮操作，双击播放，一屏容量从 4 首提升至 14~16 首。

**Tech Stack:** Flutter (Desktop Windows), desktop_multi_window, window_manager, Material 3, just_audio.

## Global Constraints

- 所有视觉与布局改动必须通过 `isDesktopFormFactor` 或 Windows 专用文件（`windows_desktop_lyrics_bridge.dart`、`lyrics_overlay_window.dart`）实现，严格禁止影响 Android 手机与车机端体验。
- 全程保持 `flutter analyze` 零 warning/error。
- 确保全部既有测试用例保持 PASS。

---

### Task 1: 调试日志清理

**Files:**
- Modify: `lib/services/music_api.dart`
- Modify: `lib/services/windows_desktop_lyrics_bridge.dart`
- Modify: `lib/ui/desktop/lyrics_overlay_window.dart`
- Modify: `lib/controllers/player_controller.dart`

**Interfaces:**
- Consumes: 既有 API 与日志打印位置
- Produces: 干净的控制台输出，移除排查期大 JSON dump 及 step 日志

- [ ] **Step 1: 清理 `music_api.dart` 中的冗余 JSON dump 逻辑**

移除 `_debugPlaylistLogObject`、`_debugArtistLogObject` 及相关调用点（`userPlaylists` 中的 `raw response`、`raw item fields`、`parsed item fields`）。

- [ ] **Step 2: 清理 `windows_desktop_lyrics_bridge.dart` 中的步骤日志**

移除 `[桌面歌词主窗] createWindow 开始`、`setFrame ok`、`主显示器尺寸 ...` 等 verbose 过程打印，仅在 catch 块中保留异常诊断。

- [ ] **Step 3: 清理 `lyrics_overlay_window.dart` 中的步骤日志**

移除 `[桌面歌词悬浮窗] [1/9]` 至 `[9/9]` 的启动日志与参数调试打印。

- [ ] **Step 4: 清理 `player_controller.dart` 中的桌面歌词临时日志**

移除 `[时音][桌面歌词] show=... result=...` 与 `[时音][桌面歌词] 已开启 ...` 日志。

- [ ] **Step 5: 验证与提交**

运行：`flutter analyze`
Expected: 0 issues
运行：`flutter test test/services/music_api_test.dart`（如有）或核心用例
Git commit: `git commit -am "chore: 清理桌面歌词与歌单解析排查日志"`

---

### Task 2: PC \"我的\"页面 Hover 与光标反馈

**Files:**
- Modify: `lib/ui/pages/library_page.dart`

**Interfaces:**
- Consumes: `_QuickHubTile`、`_PlaylistGroup`、`_PlaylistRow`、`_CollapsibleSection`
- Produces: 具有手型光标与高亮 Hover 动效的桌面端交互体验

- [ ] **Step 1: 重构 `_QuickHubTile` 支持 Hover 与手型光标**

将 `GestureDetector` 包装 `MouseRegion(cursor: SystemMouseCursors.click)`，并监听 `onEnter` / `onExit` 维护 `_isHovered` 状态。
悬停时：
- 缩放平滑维持微浮（或 `scale: 1.015`）
- 背景色在深色模式下叠加 `Colors.white.withOpacity(0.08)`，浅色模式下加深微光阴影
- 边框色微亮高光

- [ ] **Step 2: 重构 `_PlaylistRow` 与 `_PlaylistGroup` 支持桌面 Hover 与手型光标**

在 `_PlaylistGroup` 的网格卡片和列表项中，确保 `InkWell` 外层有 `Material` 组件承载水波纹，外层包裹 `MouseRegion(cursor: SystemMouseCursors.click)`；
在 `_PlaylistRow` 中增加 `_isHovered` 状态，悬停时底色切换为高亮色（`colorScheme.surfaceContainerHigh` 或 `Colors.white.withOpacity(0.08)`）。

- [ ] **Step 3: 优化新建歌单、排序等图标按钮手型光标**

确保折叠头及各操作按钮拥有明确的鼠标光标与 Tooltip。

- [ ] **Step 4: 验证与提交**

运行：`flutter analyze`
Expected: 0 issues
Git commit: `git commit -am "feat(pc): 我的页面快捷磁贴与歌单卡片追加 Hover 与光标反馈"`

---

### Task 3: 桌面歌词现代化重构（纯净透明悬浮字与悬停播控条）

**Files:**
- Modify: `lib/ui/desktop/lyrics_overlay_window.dart`
- Modify: `lib/services/windows_desktop_lyrics_bridge.dart`

**Interfaces:**
- Consumes: `windowManager.setBackgroundColor(Colors.transparent)`, `desktop_multi_window`
- Produces: 纯净无底色透明悬浮歌词、悬停淡入半透毛玻璃播控卡片、多窗口播控联动

- [ ] **Step 1: 启用子窗口真透明通道并优化尺寸**

在 `lyrics_overlay_window.dart` 的 `runLyricsOverlayWindow` 中：
调用 `await windowManager.setBackgroundColor(Colors.transparent);`
窗口默认尺寸调整为宽 780、高 88（`overlayWidth = 780`、`overlayHeight = 88`）。

- [ ] **Step 2: 重构 `_LyricsOverlayHome` 视觉与交互**

常态（`!_hovering`）：
- 整体背景完全透明（`Colors.transparent`，无 border、无 shadow、无黑色矩形底盒）。
- 歌词文本使用高清晰白字 + 强阴影（`Shadow(blurRadius: 6, ...)` 与 `Shadow(blurRadius: 14, ...)`），副歌词 60% 透明度。

悬停状态（`_hovering`）：
- 平滑淡入现代半透暗调卡片（`Color(0xB8141823)`，圆角 16px，边框 `Colors.white.withOpacity(0.12)`）。
- 浮现精致操作栏：
  - 【上一首】（Icon: `Icons.skip_previous_rounded`）
  - 【播放 / 暂停】（Icon 根据 `model.isPlaying` 显示 `Icons.pause_rounded` 或 `Icons.play_arrow_rounded`）
  - 【下一首】（Icon: `Icons.skip_next_rounded`）
  - 【锁定/穿透】（Icon: `Icons.lock_outline_rounded`）
  - 【关闭】（Icon: `Icons.close_rounded`）
- 播控按钮点击时调用 `DesktopMultiWindow.invokeMethod(0, 'controlPlayback', actionName)`。

- [ ] **Step 3: 在 `windows_desktop_lyrics_bridge.dart` 接收并处理播控指令**

在主窗的 `DesktopMultiWindow.setMethodHandler` 中新增对 `controlPlayback` 的监听：
- `'previous'`: 触发关联控制器或回调执行上一曲
- `'togglePlay'`: 触发播放/暂停切换
- `'next'`: 触发下一曲

- [ ] **Step 4: 验证与提交**

运行：`flutter analyze`
Expected: 0 issues
Git commit: `git commit -am "feat(pc): 桌面歌词真透明悬浮字与悬停播控条重构"`

---

### Task 4: PC 歌单详情页高密度专业表格列表（Table View）

**Files:**
- Modify: `lib/ui/pages/playlist_detail_page.dart`

**Interfaces:**
- Consumes: `isDesktopFormFactor`, `Song`（title, artist, albumName, duration, coverUrl）, `_filteredSongs`
- Produces: 桌面端 44px 专业表格列表，支持双击播放、悬停快捷操作、多选对齐

- [ ] **Step 1: 设计并实现桌面专业表格行组件 `_DesktopSongTableRow`**

行高固定为 44px。
包含列：
1. **序号 / 勾选**（固定宽 52px，居中）：
   - 常规：显示 `01`、`02` 格式序号；若当前正在播放则显示主题色波形或正在播放标。
   - 选择模式（`selecting`）：显示圆形复选框。
2. **歌曲标题**（自适应 `Expanded(flex: 4)`）：
   - 包含歌名、VIP/SQ/高解析度微标签；双击整行播放，单击高亮。
3. **歌手**（自适应 `Expanded(flex: 3)`）：
   - 歌手名文本，鼠标悬停变色提示可点击，点击跳转歌手详情。
4. **专辑**（自适应 `Expanded(flex: 3)`）：
   - 展示 `song.albumName ?? '-'`，浅色文本。
5. **时长 / 悬浮操作**（固定宽 140px，居右）：
   - 默认显示 `mm:ss` 格式时长。
   - 鼠标悬停（Hover）时淡入快捷操作组：【播放】【收藏】【加入歌单】【更多】。

- [ ] **Step 2: 设计并实现桌面表头 `_DesktopSongTableHeader`**

表头固定列：`#`、`歌曲`、`歌手`、`专辑`、`时长`。
与下方各列宽度精准对齐，使用浅灰色小字号。

- [ ] **Step 3: 在 `PlaylistDetailPage` 中按 `isDesktopFormFactor` 分流**

在 `SliverPadding` 区域：
- 若 `isDesktopFormFactor == true`：渲染表头和 `_DesktopSongTableRow` 列表。
- 若 `!isDesktopFormFactor`：保留既有的移动端卡片列表（`_SongRow`）。

- [ ] **Step 4: 验证与提交**

运行：`flutter analyze`
Expected: 0 issues
运行相关测试：`flutter test test/ui/pages/`
Git commit: `git commit -am "feat(pc): 歌单详情页 PC 端专业表格列表（Table View）适配"`

---

### Task 5: 全量测试与集成回归验证

**Files:**
- Test suite: `test/`

- [ ] **Step 1: 运行全量测试套件**

运行：`flutter test`
Expected: 所有测试通过。

- [ ] **Step 2: 运行代码静态检查**

运行：`flutter analyze`
Expected: 0 warning / 0 error。

- [ ] **Step 3: 整理改动与输出 Walkthrough**

更新 walkthrough.md，总结优化内容与验证结果。
