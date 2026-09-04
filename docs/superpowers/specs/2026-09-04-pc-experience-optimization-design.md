# PC 端体验与歌单布局优化设计方案

## 1. 目标与背景

时音在 PC 桌面端适配后，基础功能（托盘常驻、多窗口桌面歌词、网格横轨、桌面播放栏等）已打通，但存在以下几处影响体验的细节：
1. **排查日志冗余**：此前为排查多窗口桌面歌词和歌单解析插入的大量 `debugPrint` 依然在控制台刷屏。
2. **桌面歌词缺乏现代感**：悬浮窗由于未开启 Win32 透明通道且使用全黑底框，呈现为"傻大黑粗的大黑框"，需重构为现代 PC 播放器主流的纯净透明悬浮字（QQ 音乐风格），仅在鼠标悬停时显现磨砂控制卡片。
3. **PC "我的"页面缺少鼠标悬浮反馈**：快捷磁贴与歌单卡片无手型光标（pointer cursor）及 hover 动效。
4. **PC 歌单详情页歌曲展示密度过低**：单行高达 80px+ 的膨胀大卡片导致 1080P 屏幕一屏仅能展示 4 首歌曲，右侧空间极度浪费。需针对 PC 桌面端升级为专业级紧凑表格视图（Table View），大幅提高空间利用率与信息密度（一屏 14~16 首）。

> **核心原则**：所有视觉与交互改造严格限制在 PC 桌面端（`isDesktopFormFactor` / Windows 平台专用实现），严禁影响 Android 手机与车机端的原有体验。

---

## 2. 详细设计

### 2.1 调试日志清理

- **清理范围**：
  - `lib/services/music_api.dart`：移除 `_debugPlaylistLogObject`（以及其中的 `raw response`、`raw item fields`、`parsed item fields` 打印逻辑），保留必要的生产错误捕获。
  - `lib/services/windows_desktop_lyrics_bridge.dart`：移除 `[桌面歌词主窗] createWindow 开始`、`[桌面歌词主窗] setFrame ok` 等 verbose 过程日志，只保留异常日志。
  - `lib/ui/desktop/lyrics_overlay_window.dart`：移除 `[1/9]` 至 `[9/9]` 启动阶段日志及参数 dump。
  - `lib/controllers/player_controller.dart`：移除 `[时音][桌面歌词] show=... result=...` 等日志。

---

### 2.2 桌面歌词（风格 2：纯净透明悬浮字幕）

- **真透明支持**：
  - 子窗口初始化过程调用 `await windowManager.setBackgroundColor(Colors.transparent)`，开启透明渐变/无底色通道。
  - 悬浮窗尺寸调优为宽 780px、高 88px（更精致收敛，避免过高遮挡屏幕）。
- **无悬停常态（Pure Floating Lyrics）**：
  - 背景完全透明（`Colors.transparent`，0 底色、0 边框）。
  - 主歌词居中高亮渲染（白字 + 双层文字阴影 `blurRadius: 6` & `14`），副歌词/翻译按 60% 透明度渲染。
- **悬停状态（Hovered Toolbar & Acrylic Bar）**：
  - 鼠标悬停进入时，平滑淡入现代半透暗调毛玻璃背景（`rgba(20, 24, 35, 0.72)` + 圆角 16px + 细微描边 `rgba(255, 255, 255, 0.1)`）。
  - 顶部浮现微型操作条：
    - **播放控制**：【上一曲】、【播放 / 暂停】、【下一曲】（通过多窗口通道 `DesktopMultiWindow.invokeMethod(0, 'controlPlayback', action)` 通知主窗 `player` 控制器执行）。
    - **锁定 / 穿透**：点击锁定后，窗口开启鼠标穿透（`windowManager.setIgnoreMouseEvents(true)`），不遮挡桌面操作。
    - **关闭**：优雅退出桌面歌词。
  - 悬停区域作为可拖拽区域（`DragToMoveArea`），方便用户随时调整摆放位置。

---

### 2.3 PC "我的"页面（LibraryPage）Hover 与光标反馈

- **4 核心快捷磁贴（收藏、最近、本地、已下载）**：
  - 将原始 `GestureDetector` 改为带 `MouseRegion(cursor: SystemMouseCursors.click)`。
  - 增加 Hover 动效：
    - 鼠标悬停时，底色增加微亮覆盖层（深色模式 `Colors.white.withOpacity(0.08)` / 浅色模式微亮且阴影层次加强）。
    - 边框色变亮增强边界感。
    - 轻微平滑缩放反馈（`scale: 1.02`）。
- **歌单卡片（`_PlaylistRow` in `_PlaylistGroup`）**：
  - 确保内部 `InkWell` 正确包含在 `Material` 树中。
  - 包装 `MouseRegion(cursor: SystemMouseCursors.click)`，鼠标悬停时高亮卡片背景色，鼠标离开平滑恢复。
- **操作按钮**：
  - "新建歌单" `+` 按钮、"排序" 按钮、折叠分组标题栏统一配置手型光标与操作高亮。

---

### 2.4 PC 歌单详情页（方案 A：现代 PC 专业表格列表）

- **布局分流**：
  - 当 `isDesktopFormFactor == true` 时，歌曲列表渲染为专业表格视图 `_DesktopSongTableView`；
  - 移动端保持原本的大卡片列表不变。
- **表格列分布**：
  - `# / 勾选框`：固定宽 48px，居中。非选择模式下显示序号（正在播放的歌曲显示动态音频波形图标）；选择模式下显示圆形复选框。
  - `歌曲标题`：自适应（权重 `flex: 4`），展示歌曲主标题，包含音质标签（SQ/Hi-Res/VIP 等微胶囊标）。
  - `歌手`：自适应（权重 `flex: 3`），展示歌手名，悬停支持变色下划线反馈，点击可直接跳转歌手主页。
  - `专辑`：自适应（权重 `flex: 3`），展示 `song.albumName`（为空显示 `-`）。
  - `时长 / 悬浮操作`：固定宽 140px，居右。
    - **常规状态**：展示歌曲时长 `mm:ss`。
    - **鼠标悬停状态**：时长平滑替换为快捷操作图标组：【立即播放】、【喜欢/收藏】、【添加到歌单】、【更多菜单】。
- **行高与展示密度**：
  - 每行高度严格控制在 **44px**，去掉庞大的卡片间距。
  - 屏幕一屏可直接呈现 **14~16 首歌曲**（展示容量提升 3~4 倍）。
  - 支持**双击整行直接播放**，单击行高亮选中。
  - 正在播放的曲目：整行标题与序号使用主题色高亮。
- **表头（Header Row）**：
  - 在列表顶部固定一行表头：`#`、`歌曲`、`歌手`、`专辑`、`时长`，文字小字号半透（`colorScheme.onSurfaceVariant`），规整对齐下方各列。

---

## 3. 验证方案

1. **静态代码分析**：运行 `flutter analyze`，确保无任何新增 warning 或 error。
2. **测试用例运行**：运行既有测试套件，保证旧逻辑（尤其是 `player_controller`、`library_page`、`playlist_detail_page` 等核心流）全部保持通过。
3. **功能验证**：
   - 检查控制台输出，确认启动与切换歌单时不再有大段 JSON 与 verbose 步骤日志刷屏。
   - 验证 PC 桌面歌词真透明悬浮字：无黑框，文字高对比清晰，鼠标移入浮现磨砂操作条，上一首/下一首/暂停/锁定/关闭操作正常。
   - 验证 PC "我的"页面：快捷卡片、歌单卡片具有明确的 pointer 手型光标与高亮 Hover 效果。
   - 验证 PC 歌单详情页：表格形式展示歌曲，显示序号、标题、歌手、专辑、时长，一屏清晰容纳十几首歌，双击播放，悬停快捷操作有效。
