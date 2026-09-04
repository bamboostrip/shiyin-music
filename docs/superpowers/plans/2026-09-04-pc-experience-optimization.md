# PC 端体验与歌单布局优化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 彻底消除桌面歌词外部多余框线与双层嵌套，将歌曲操作菜单升级为 PC 桌面级下拉列表，并将排行榜详情页与歌手详情页在 PC 桌面端升级为高密度专业表格列表与紧凑横排头部。

**Architecture:**
- 桌面歌词通过 `windowManager.setAsFrameless()` 与 `windowManager.setHasShadow(false)` 消除 Win32 DWM 外层轮廓与阴影，移除内部边距实现真正无外框纯浮动字幕与单层磨砂操作浮岛。
- `showSongActionSheet` 在 `isDesktopFormFactor` 下使用紧凑的桌面上下文菜单（垂直排列，每行 36px），拦截车机 2x2 磁贴。
- `RankDetailPage` 与 `ArtistDetailPage` 针对 `isDesktopFormFactor` 引入紧凑横排头部与 44px 专业歌曲表格列表，支持双击播放与悬停操作，充分利用宽屏展示。

**Tech Stack:** Flutter (Desktop Windows), window_manager, Material 3, just_audio.

## Global Constraints

- 所有视觉与布局改动必须通过 `isDesktopFormFactor` 或 Windows 专用文件实现，严格禁止影响 Android 手机与车机端体验。
- 全程保持 `flutter analyze` 零 warning/error。
- 确保全部既有测试用例保持 PASS。

---

### Task 1: 调试日志清理（已完成）
commit: `039257b`

### Task 2: PC "我的"页面 Hover 与光标反馈（已完成）
commit: `a05fa97`

### Task 3: 桌面歌词真透明与悬停播控条（已完成）
commit: `35feb1d`

### Task 4: PC 歌单详情页高密度专业表格列表（已完成）
commit: `cfbfeeb`

---

### Task 5: 桌面歌词消除多余外框与双层盒模型

**Files:**
- Modify: `lib/ui/desktop/lyrics_overlay_window.dart`

**Interfaces:**
- Consumes: `windowManager.setAsFrameless()`, `windowManager.setHasShadow(false)`
- Produces: 彻底消除 Windows 11 DWM 窗口外层轮廓线，消除内缩边距造成的双层框

- [ ] **Step 1: Win32 底层无边框与无阴影配置**

在 `runLyricsOverlayWindow` 中：
```dart
await windowManager.setAsFrameless();
await windowManager.setHasShadow(false);
```

- [ ] **Step 2: 消除内部多余 padding 与双层盒模型**

在 `_LyricsOverlayHomeState.build` 中：
- 移除 `Padding(horizontal: 6, vertical: 4)`，直接让卡片贴合悬浮窗；
- 常态（`!_hovering`）：
  - 边框为 `Border.all(color: Colors.transparent, width: 0)` 或 `null`；
  - 彻底没有外框线，纯文字浮动于桌面。
- 悬停（`_hovering`）：
  - 单层半透磨砂卡片（`Color(0xC8141823)`，圆角 16px，微弱高光边框 `Colors.white.withValues(alpha: 0.10)`），右上角微型播控栏紧凑排布。

- [ ] **Step 3: 验证与提交**

运行：`flutter analyze`
运行：`flutter test test/ui/desktop/desktop_lyrics_test.dart`
Git commit: `git commit -am "fix(pc): 桌面歌词消除外层多余轮廓与双层框线"`

---

### Task 6: 歌曲操作弹窗 PC 桌面级菜单改造

**Files:**
- Modify: `lib/ui/widgets/song_action_sheets.dart`

**Interfaces:**
- Consumes: `isDesktopFormFactor`, `SongSheetAction`
- Produces: PC 桌面端点击歌曲 `...` 弹出紧凑垂直上下文菜单，彻底告别车机 2x2 巨大磁贴

- [ ] **Step 1: 在 `showSongActionSheet` 中追加桌面端判断**

在 `showSongActionSheet` 顶部：
```dart
if (isDesktopFormFactor) {
  return _showDesktopSongActionMenu(context: context, song: song, actions: actions);
}
```

- [ ] **Step 2: 实现 `_showDesktopSongActionMenu` 桌面级紧凑菜单**

实现现代 PC 桌面级弹窗/菜单：
- 宽度约 200~220px，垂直紧凑排列操作项；
- 每项高度 36~40px，左侧微型图标（18px），右侧清晰文字（13px，如【下一首播放】、【添加到歌单】、【查看歌手】、【下载】等）；
- 鼠标悬停支持平滑高亮背景与手型光标；
- 点击后自动关闭并触发对应 `action.onTap()`。

- [ ] **Step 3: 验证与提交**

运行：`flutter analyze`
Git commit: `git commit -am "feat(pc): 歌曲操作弹窗适配 PC 桌面级紧凑菜单"`

---

### Task 7: 排行榜详情页（RankDetailPage）PC 桌面端布局适配

**Files:**
- Modify: `lib/ui/pages/rank_page.dart`

**Interfaces:**
- Consumes: `isDesktopFormFactor`, `RankCategory`, `_songs`
- Produces: PC 桌面端排行榜紧凑横排头部与 44px 专业歌曲表格列表（对齐歌单页）

- [ ] **Step 1: 排行榜头部在 PC 端紧凑横排化**

当 `isDesktopFormFactor == true` 时：
- 左侧显示 120px 榜单封面（圆角 16px，微阴影）；
- 右侧展示榜单名称（大字号）、歌曲数与【播放全部】主按钮；
- 高度收窄至 220px 以内，消除移动端全宽拉伸背景。

- [ ] **Step 2: 歌曲列表在 PC 端适配 44px 专业表格列表**

当 `isDesktopFormFactor == true` 时：
- 表头：`#`、`歌曲`、`歌手`、`专辑`、`时长`；
- 数据行：行高 44px（`SliverFixedExtentList`），显示两位序号/音波、歌名、歌手（点击跳转）、专辑名、时长/悬停快捷操作组（播放、收藏心形、加歌单、更多菜单）；
- 支持单击选中，双击整行直接播放。

- [ ] **Step 3: 验证与提交**

运行：`flutter analyze`
Git commit: `git commit -am "feat(pc): 排行榜详情页 PC 端专业表格列表与紧凑头部适配"`

---

### Task 8: 歌手详情页（ArtistDetailPage）PC 桌面端界面优化

**Files:**
- Modify: `lib/ui/pages/artist_detail_page.dart`

**Interfaces:**
- Consumes: `isDesktopFormFactor`, `ArtistDetail`, `_songs`, `_albums`
- Produces: PC 桌面端歌手紧凑横排头与热门歌曲 44px 专业表格列表

- [ ] **Step 1: 歌手头部在 PC 端紧凑横排化**

当 `isDesktopFormFactor == true` 时：
- 左侧显示 120px 圆形/圆角歌手大头像；
- 右侧展示歌手名、单曲总数、专辑总数，以及【播放热门歌曲】主按钮；
- 消除移动端大图拉伸。

- [ ] **Step 2: 热门歌曲列表在 PC 端适配 44px 专业表格列表**

当 `isDesktopFormFactor == true` 时：
- 渲染 44px 专业歌曲表格列表，支持对齐显示专辑与时长；
- 支持双击直接播放、悬停快捷操作。

- [ ] **Step 3: 验证与提交**

运行：`flutter analyze`
Git commit: `git commit -am "feat(pc): 歌手详情页 PC 端专业表格列表与紧凑头部优化"`

---

### Task 9: 全量回归与测试验证

**Files:**
- Test suite: `test/`

- [ ] **Step 1: 运行全量自动化测试**
- [ ] **Step 2: 运行代码静态检查**
- [ ] **Step 3: 更新 Walkthrough**
