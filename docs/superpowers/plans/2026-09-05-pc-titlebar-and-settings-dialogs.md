# PC 沉浸式标题栏与设置页桌面级弹窗实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:**
1. 隐藏 Windows 原生 Win32 标题栏，在 Flutter 内部实现与侧栏及应用主题无缝融合的沉浸式自定义标题栏（支持窗口拖动、双击最大化、精致窗口控制三键、显示播放中曲目）；
2. 将设置页中的「默认音质」、「字体大小」、「缓存管理」弹窗在 PC 桌面端改造为标准的桌面级居中 Dialog，彻底移除移动端滑动条与拖动手柄，并保证移动端/车机端体验完全不受影响。

**Architecture:**
- **标题栏层**：`DesktopWindow` 启用 `TitleBarStyle.hidden`；在 `lib/ui/desktop/desktop_title_bar.dart` 创建 `DesktopTitleBar`，左侧对齐侧栏 Logo，中间提供 `DragToMoveArea` 拖拽与双击最大化/还原并弱化显示曲名，右侧提供最小化、最大化/还原、关闭三键；`DesktopShell` 将其置于最顶层；
- **设置弹窗层**：按 `isDesktopFormFactor` 分流。在 PC 桌面端使用 `showDialog` 弹出固定宽度、圆角柔和、带右上角关闭按钮的桌面卡片；在移动端/车机端保持原样 `showModalBottomSheet`。

**Tech Stack:** Flutter / Dart, window_manager, desktop_shell, theme_controller.

---

## Global Constraints
- 严格遵循跨平台分流原则：移动端和车机端（`isDesktopFormFactor == false`）的 UI 与交互逻辑不得产生任何非预期改动；
- 标题栏右侧关闭按钮必须触发 `windowManager.close()`，以便与已有的“关闭时最小化到托盘/退出”逻辑完整对接；
- 每次修改后 `flutter analyze` 必须 0 错误 0 警告，相关自动化测试全部通过。

---

## File Structure

```
lib/
├── ui/
│   ├── desktop/
│   │   ├── desktop_window.dart        # [MODIFY] 设置 titleBarStyle: TitleBarStyle.hidden
│   │   ├── desktop_title_bar.dart     # [NEW] 沉浸式桌面标题栏组件（拖拽、控制按钮、曲目展示）
│   │   ├── desktop_sidebar.dart       # [MODIFY] 顶部 Logo 适配顶栏一体化
│   │   └── desktop_shell.dart         # [MODIFY] 最顶层引入 DesktopTitleBar
│   ├── pages/
│   │   └── settings_page.dart         # [MODIFY] 字体大小与缓存管理弹窗按 isDesktopFormFactor 分流为 Dialog
│   └── widgets/
│       └── audio_quality_sheet.dart   # [MODIFY] 音质选择弹窗按 isDesktopFormFactor 分流为 Dialog
test/
└── ui/
    ├── desktop/
    │   └── desktop_title_bar_test.dart# [NEW] 桌面标题栏组件测试
    └── pages/
        └── settings_desktop_dialog_test.dart # [NEW] 设置页桌面 Dialog 弹窗与移动端 BottomSheet 门控测试
```

---

## Tasks

### Task 1: 实现 PC 沉浸式自定义标题栏 (DesktopTitleBar)

**Files:**
- Modify: `lib/ui/desktop/desktop_window.dart`
- Create: `lib/ui/desktop/desktop_title_bar.dart`
- Modify: `lib/ui/desktop/desktop_sidebar.dart`
- Modify: `lib/ui/desktop/desktop_shell.dart`
- Test: `test/ui/desktop/desktop_title_bar_test.dart`

**Interfaces:**
- `DesktopTitleBar`: 接收 `PlayerController player`，高度固定 40px，横贯应用顶部；
  - 左侧（宽度 208px）：Logo 与「时音」标题（支持拖动）；
  - 中间：`DragToMoveArea` 区域，双击切换最大化/还原，居中优雅展示当前播放歌名歌手；
  - 右侧：Windows 窗口控制三键（最小化、最大化/还原、关闭），悬停带有现代 Windows 视觉反馈（关闭悬停为红底白字）。

- [ ] **Step 1: Write widget tests for DesktopTitleBar**
  在 `test/ui/desktop/desktop_title_bar_test.dart` 中编写测试：
  - 渲染 Logo、应用名「时音」；
  - 当前有播放歌曲时渲染 `歌曲名 - 歌手`；
  - 渲染最小化、最大化、关闭按钮并验证交互。
- [ ] **Step 2: Create DesktopTitleBar widget**
  创建 `lib/ui/desktop/desktop_title_bar.dart`，实现一体化顶栏、窗口控制按钮与拖动区域。
- [ ] **Step 3: Update DesktopWindow & DesktopShell**
  - 在 `lib/ui/desktop/desktop_window.dart` 设置 `titleBarStyle: TitleBarStyle.hidden`；
  - 在 `lib/ui/desktop/desktop_shell.dart` 将 `DesktopTitleBar` 作为最外层顶部通用栏；
  - 调整 `DesktopSidebar` 顶部留白，使其与顶栏 Logo 无缝衔接。
- [ ] **Step 4: Run tests & verify**
  运行 `flutter test test/ui/desktop/desktop_title_bar_test.dart` 确认测试通过。

---

### Task 2: 设置页与音质选择弹窗桌面化 (Desktop Dialog)

**Files:**
- Modify: `lib/ui/widgets/audio_quality_sheet.dart`
- Modify: `lib/ui/pages/settings_page.dart`
- Test: `test/ui/pages/settings_desktop_dialog_test.dart`

**Interfaces:**
- `showAudioQualitySheet`: `isDesktopFormFactor ? showDialog(...) : showModalBottomSheet(...)`
- `_selectFontScale`: `isDesktopFormFactor ? showDialog(...) : showModalBottomSheet(...)`
- `_showCacheManagement`: `isDesktopFormFactor ? showDialog(...) : showModalBottomSheet(...)`

- [ ] **Step 1: Write tests for desktop dialog vs mobile bottom sheet**
  在 `test/ui/pages/settings_desktop_dialog_test.dart` 中测试：
  - `isDesktopFormFactor = true` 时，音质、字号、缓存弹窗使用 `Dialog` 且无 `showDragHandle`；
  - `isDesktopFormFactor = false` 时，保持 `ModalBottomSheet` 展现。
- [ ] **Step 2: Adapt showAudioQualitySheet for desktop**
  在 `lib/ui/widgets/audio_quality_sheet.dart` 实现桌面居中 Dialog 样式（宽 400px，右上角关闭按钮，单点即选即关）。
- [ ] **Step 3: Adapt _selectFontScale & _showCacheManagement for desktop**
  在 `lib/ui/pages/settings_page.dart`：
  - `_selectFontScale`: 桌面端使用居中 Dialog（宽 380px）；
  - `_showCacheManagement`: 桌面端使用居中 Dialog（宽 520px，带标题栏、关闭 X、缓存明细与清理操作）。
- [ ] **Step 4: Run tests & verify**
  运行 `flutter test test/ui/pages/settings_desktop_dialog_test.dart` 确认通过。

---

### Task 3: 全量回归与代码静态检查

**Files:**
- All files

- [ ] **Step 1: Run full test suite**
  执行 `flutter test` 确认全库测试通过。
- [ ] **Step 2: Run flutter analyze**
  执行 `flutter analyze` 确认 0 warnings / 0 errors。
- [ ] **Step 3: Update walkthrough**
  更新 `walkthrough.md` 记录实现成果与对比效果。
