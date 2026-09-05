# PC音质快捷切换、未播试听高潮修复与歌手/歌单页动态全量加载实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复未播放时试听高潮跳回 0 秒 Bug，增加 PC 底部播放条与播放详情页的直接音质切换徽标，将歌手页改造为【精选单曲】与【所有专辑】Tab 切换，并实现歌手页与歌单页动态全量静默预加载。

**Architecture:**
1. `PlayerController.playSong` 扩充 `initialPosition` 与 `preserveClimax` 支持，在 idle 状态试听高潮时直接从高潮点加载播放；
2. `DesktopPlayerBar` 进度条与音量之间增加音质徽标按钮，点击弹出桌面音质 Dialog；`PlayerPage` 歌曲信息与控制区同步提供音质徽标；
3. `ArtistDetailPage` 引入粘性 TabBar 分流单曲与专辑；
4. `ArtistDetailPage` 与 `PlaylistDetailPage` 在首屏完成后开启后台静默累进预加载管道，动态刷新歌曲计数，保障长列表与搜索丝滑流畅。

**Tech Stack:** Flutter 3, Dart, Provider / ChangeNotifier, WindowManager, CustomScrollView / Slivers.

---

### Task 1: 修复未播放时“试听高潮”弹回 0 秒 Bug

**Files:**
- Modify: `lib/controllers/player_controller.dart`
- Create: `test/controllers/player_climax_idle_test.dart`

**Interfaces:**
- `PlayerController.playSong`:
  ```dart
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool isRetry = false,
    Duration? initialPosition,
    bool preserveClimax = false,
  });
  ```
- `PlayerController.playClimaxPreview()`: 在 `idle` 状态下使用 `initialPosition: climax.startTime` 初始化音频引擎并保持 `_climaxEndTime`。

- [ ] **Step 1: Write failing test in `test/controllers/player_climax_idle_test.dart`**
  验证在 `audioPlayer.processingState == ProcessingState.idle` 时调用 `playClimaxPreview()`：
  - 成功返回 `true`；
  - 音频引擎从 `climax.startTime` 开始起播；
  - `_climaxEndTime` 与 `climax` 不被清空为 null。
- [ ] **Step 2: Run test to verify failure**
  运行 `flutter test test/controllers/player_climax_idle_test.dart` 确认失败（Red）。
- [ ] **Step 3: Implement in `lib/controllers/player_controller.dart`**
  - 在 `playSong` 中接收 `initialPosition` 和 `preserveClimax` 参数；
  - 当 `preserveClimax == false` 时才重置 `_climaxEndTime` 与 `climax`；
  - 在 `_audioHandler.loadSong` 后，若 `initialPosition != null`，先 `seek(initialPosition)` 再调用 `play()`；
  - 在 `playClimaxPreview()` 中对 `idle` 状态进行特殊处理。
- [ ] **Step 4: Run test to verify pass**
  运行 `flutter test test/controllers/player_climax_idle_test.dart` 确认通过（Green）。

---

### Task 2: PC 快捷音质切换（底部播放栏 DesktopPlayerBar 与播放详情页）

**Files:**
- Modify: `lib/ui/desktop/desktop_player_bar.dart`
- Modify: `lib/ui/pages/player_page.dart`
- Test: `test/ui/desktop/desktop_player_bar_test.dart`

**Interfaces:**
- `DesktopPlayerBar`: 在 `_ProgressBar` 右侧添加 `_AudioQualityBadge`：
  - 鼠标悬停变亮，显示当前音质 Badge（如 `无损` / `高品` / `标准`）；
  - 点击调用 `showAudioQualitySheet`，选择后调用 `player.setAudioQuality(quality, reloadCurrent: true)`。
- `PlayerPage`: 在歌曲标题下方或控制栏区域显式渲染音质小胶囊，点击同样唤起 `showAudioQualitySheet`。

- [ ] **Step 1: Write widget test in `test/ui/desktop/desktop_player_bar_test.dart`**
  - 验证播放栏中渲染当前音质 Badge（如 `标准` / `无损`）；
  - 验证点击音质 Badge 会调用切换逻辑。
- [ ] **Step 2: Run test to verify failure**
  运行 `flutter test test/ui/desktop/desktop_player_bar_test.dart` 确认失败。
- [ ] **Step 3: Implement in `lib/ui/desktop/desktop_player_bar.dart` and `lib/ui/pages/player_page.dart`**
  - 在 `DesktopPlayerBar` 中构建 `_AudioQualityBadge` 并嵌入到进度条与音量条之间；
  - 在 `PlayerPage` 标题下方或副标题行添加可点击的音质胶囊。
- [ ] **Step 4: Run test to verify pass**
  运行 `flutter test test/ui/desktop/desktop_player_bar_test.dart` 确认通过。

---

### Task 3: 歌手详情页结构重构（Tab 标签页分流 & 动态计数）

**Files:**
- Modify: `lib/ui/pages/artist_detail_page.dart`
- Create: `test/ui/pages/artist_detail_tab_test.dart`

**Interfaces:**
- `ArtistDetailPage`:
  - 顶部 Hero 展示动态数量（`已加载 X 首热门单曲 · Y 张专辑` 或 `共 X 首热门单曲 · Y 张专辑`）；
  - SliverPersistentHeader 粘性 TabBar：`精选单曲` 与 `所有专辑`；
  - 默认选中 `精选单曲`，首屏直达歌曲列表；
  - 切换到 `所有专辑` 时展示专辑网格。

- [ ] **Step 1: Write widget test in `test/ui/pages/artist_detail_tab_test.dart`**
  - 测试默认进入呈现「精选单曲」，歌曲列表排在上方，不被专辑遮挡；
  - 测试点击「所有专辑」Tab 切换展示专辑网格。
- [ ] **Step 2: Run test to verify failure**
  运行 `flutter test test/ui/pages/artist_detail_tab_test.dart` 确认失败。
- [ ] **Step 3: Implement Tab structure in `lib/ui/pages/artist_detail_page.dart`**
  - 增加 Tab 状态（`_activeTab: _ArtistTab.songs / _ArtistTab.albums`）；
  - 实现粘性 TabBar Sliver；
  - 按当前激活 Tab 条件渲染歌曲列表或专辑网格。
- [ ] **Step 4: Run test to verify pass**
  运行 `flutter test test/ui/pages/artist_detail_tab_test.dart` 确认通过。

---

### Task 4: 歌手页与歌单页动态全量静默预加载

**Files:**
- Modify: `lib/ui/pages/artist_detail_page.dart`
- Modify: `lib/ui/pages/playlist_detail_page.dart`
- Create: `test/ui/pages/playlist_detail_preload_test.dart`

**Interfaces:**
- `ArtistDetailPage._startProgressiveLoading`: 首屏 30 首渲染后，后台无感持续拉取剩余分页，动态累加并刷新计数。
- `PlaylistDetailPage._loadInitial`: 首屏 50 首渲染后，若未满全量，在 post frame 自动触发 `_loadAllSongs(silent: true)`。

- [ ] **Step 1: Write test in `test/ui/pages/playlist_detail_preload_test.dart`**
  - 验证首屏加载完成后自动触发后台静默补全；
  - 验证歌手页分页加载后动态计数递增。
- [ ] **Step 2: Run test to verify failure**
  运行 `flutter test test/ui/pages/playlist_detail_preload_test.dart` 确认失败。
- [ ] **Step 3: Implement progressive preloading**
  - 在 `ArtistDetailPage` 实现 `_startProgressiveLoading()`；
  - 在 `PlaylistDetailPage` 的 `_loadInitial()` 成功分支触发 `_loadAllSongs(silent: true)`。
- [ ] **Step 4: Run test to verify pass**
  运行 `flutter test test/ui/pages/playlist_detail_preload_test.dart` 确认通过。

---

### Task 5: 全量回归与代码静态检查

**Files:**
- All touched files

- [ ] **Step 1: Run full test suite**
  执行 `flutter test` 确保 325+ 项测试全部通过。
- [ ] **Step 2: Run flutter analyze**
  执行 `flutter analyze` 确保 0 warnings / 0 errors。
- [ ] **Step 3: Update walkthrough artifact**
  更新 `walkthrough.md` 详细记录开发与验证结果。
- [ ] **Step 4: Commit changes to git**
  按照规范提交。
