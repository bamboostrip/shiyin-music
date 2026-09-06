# 移动端歌单吸顶与播放页 QQ 音乐布局重构实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 优化歌单页面移动端吸顶圆角动态消除缺口，重构移动端播放页面为 QQ 音乐主流布局（顶栏指示器、右侧封面/左侧歌词滑动、大标题+爱心拇指区、横向功能栏、封面点击弹菜单、下拉退出手势）。

**Architecture:** 
- 歌单页在 `_StickyHeaderDelegate` 与 `_ListStickyBar` 中根据滚动偏移与吸顶状态动态计算 `topRadius`（16px 到 0px 平滑过渡，消除与平直 AppBar 的拼接缺口）；
- 播放页调整 `PageView` 页面顺序为 `[0: 歌词页, 1: 封面主页]`（初始进入 index 1，右滑至歌词页），顶栏移除音质与爱心并新增 `· —` 动态状态指示器；
- 封面页重构封面下方布局（大标题跑马灯、歌手+音质 Badge、右侧爱心、歌词预览、横向功能栏），为封面添加点击弹出菜单手势与下拉退出手势。

**Tech Stack:** Flutter / Dart, CustomScrollView, SliverPersistentHeader, PageView, GestureDetector, AnimatedBuilder

## Global Constraints
- 桌面端与车机横屏双拼模式（`isDesktopFormFactor || (landscape && ThemeController.instance.carModeEnabled)`）行为与布局完全不受影响。
- 遵循现有的设计 Token（`AppRadius`, `ColorScheme`, `Theme`）。
- 保持所有现有测试通过。

---

### Task 1: 歌单页面移动端吸顶动态平滑圆角（方案 A）

**Files:**
- Modify: `lib/ui/pages/playlist_detail_page.dart:2640-2710` (调整 `_ListStickyBar` 与 `_StickyHeaderDelegate`，支持动态计算 `topRadius`)
- Test: `test/ui/pages/playlist_detail_sticky_radius_test.dart`

**Interfaces:**
- `_ListStickyBar`: 增加可选参数 `double? topRadiusOverride` 或 `bool flatTop`。当 `topRadiusOverride` 传入时使用 `BorderRadius.vertical(top: Radius.circular(radius))`，当 `radius == 0` 时阴影自动清除。
- `_StickyHeaderDelegate`: 在 `build` 中接收 `shrinkOffset` / `overlapsContent`，结合 `_scrollController` 动态计算吸顶距离，传入平滑过渡的 `topRadius`。

- [ ] **Step 1: 编写失败测试**
创建 `test/ui/pages/playlist_detail_sticky_radius_test.dart`，测试 `_ListStickyBar` 在 `topRadiusOverride == 0` 时呈现直角与无阴影，在 `topRadiusOverride == 16` 时具有顶部圆角。

- [ ] **Step 2: 运行测试验证失败**
运行 `flutter test test/ui/pages/playlist_detail_sticky_radius_test.dart`，确认测试编译或断言失败。

- [ ] **Step 3: 编写最小实现代码**
在 `lib/ui/pages/playlist_detail_page.dart` 中：
1. `_ListStickyBar` 支持 `topRadiusOverride` 参数；
2. `_StickyHeaderDelegate` 结合滚动位移（`delta = _heroExpandedHeight - kToolbarHeight`）与 `overlapsContent` 动态计算 `topRadius`：
   - 当 `isDesktopFormFactor || overlapsContent || offset >= delta` 时为 `0.0`；
   - 当 `offset <= delta - 16` 时为 `AppRadius.lg` (16.0)；
   - 在 `delta - 16 < offset < delta` 时线性插值 `16.0 * (delta - offset) / 16.0`。
3. 动态阴影根据 `topRadius > 0` 决定显示。

- [ ] **Step 4: 运行测试验证通过**
运行 `flutter test test/ui/pages/playlist_detail_sticky_radius_test.dart`，确保通过。

- [ ] **Step 5: 提交代码**
`git add lib/ui/pages/playlist_detail_page.dart test/ui/pages/playlist_detail_sticky_radius_test.dart`
`git commit -m "feat: add dynamic top radius to playlist sticky header on mobile"`

---

### Task 2: 移动端播放页顶栏指示器与页面顺序（右滑看歌词）

**Files:**
- Modify: `lib/ui/player/player_top_bar.dart:15-98` (移除移动端音质与爱心，增加指示器支持)
- Modify: `lib/ui/pages/player_page.dart:200-310` (调整 PageView 为 `[歌词, 封面]`，initialPage: 1，联动指示器)
- Test: `test/ui/player/player_top_bar_indicator_test.dart`

**Interfaces:**
- `PlayerTopBarIndicator`: 新建组件或在 `TopBar` 中展示，接收 `currentPage`（0: 歌词, 1: 封面）。
  - Page 1（封面）：左 `·`（宽 4，圆角 2），右 `—`（宽 14，圆角 2）；
  - Page 0（歌词）：左 `—`（宽 14，圆角 2），右 `·`（宽 4，圆角 2）。
- `TopBar`: 移动端展示：左返回，中 `PlayerTopBarIndicator`，右更多菜单。

- [ ] **Step 1: 编写失败测试**
创建 `test/ui/player/player_top_bar_indicator_test.dart`，验证移动端顶栏不渲染右上角爱心和音质 pill，并正确渲染指示器组件在当前页为 0 和 1 时的形态。

- [ ] **Step 2: 运行测试验证失败**
运行 `flutter test test/ui/player/player_top_bar_indicator_test.dart`，确认失败。

- [ ] **Step 3: 编写最小实现代码**
1. 在 `player_top_bar.dart` 中实现 `PlayerPageIndicator`，支持宽度平滑过渡动画；
2. 在 `TopBar` 中判断是否为移动端竖屏：移除爱心与音质 pill，将居中标题替换为 `PlayerPageIndicator`（桌面端与车机保留原样式）；
3. 在 `player_page.dart` 中调整 `PageView`：
   - 子页面顺序设为 `[LyricPlayerPage(key: ...), PosterPlayerPage(key: ...)]`；
   - `_pageController = PageController(initialPage: 1)`；
   - 将 `_page` 传入 `TopBar`。

- [ ] **Step 4: 运行测试验证通过**
运行 `flutter test test/ui/player/player_top_bar_indicator_test.dart`，确保通过。

- [ ] **Step 5: 提交代码**
`git add lib/ui/player/player_top_bar.dart lib/ui/pages/player_page.dart test/ui/player/player_top_bar_indicator_test.dart`
`git commit -m "feat: add top bar page indicator and reverse page order for mobile player"`

---

### Task 3: 移动端封面页 QQ 音乐布局重构（大标题 + 爱心 + 歌词预览 + 快捷操作栏）

**Files:**
- Modify: `lib/ui/player/poster_player.dart` (重构封面下方各元素布局)
- Test: `test/ui/player/poster_player_layout_test.dart`

**Interfaces:**
- `PosterSongInfoRow`:
  - 左侧：标题 Text / Marquee + 歌手 Text（点击调用 `onArtistTap`）+ `PlayerAudioQualityPill(compact: true)`；
  - 右侧：爱心按钮（`likeAuth.isLiked(song)`，点击调用 `likeAuth.toggleLike(song)`）。
- `PosterActionRail`:
  - 水平排列：`[➕ 收藏到歌单]`, `[🎵 音效 / ⏰ 定时]`, `[⬇ 下载]`, `[💬 评论]`。
- `PosterLyricPreview`:
  - 简化为单行/双行清晰预览，点击触发 `onLyricTap`（调用 `pageController.animateToPage(0, ...)`）。

- [ ] **Step 1: 编写失败测试**
创建 `test/ui/player/poster_player_layout_test.dart`，验证 `PosterPlayerPage` 下方存在歌曲标题、歌手、音质 tag、爱心按钮以及 4 个功能图标。

- [ ] **Step 2: 运行测试验证失败**
运行 `flutter test test/ui/player/poster_player_layout_test.dart`，确认失败。

- [ ] **Step 3: 编写最小实现代码**
在 `poster_player.dart` 中：
1. 组合 `PosterSongInfoRow`（大字号标题 + 歌手 + 音质小 pill + 右侧爱心按钮）；
2. 组合 `PosterActionRail`（包含加歌单、音效/定时、下载、评论）；
3. 歌词预览行增加点击跳转到第 0 页（歌词页）的回调；
4. 整体弹性排布，确保在不同手机屏幕高宽下自适应不溢出。

- [ ] **Step 4: 运行测试验证通过**
运行 `flutter test test/ui/player/poster_player_layout_test.dart`，确保通过。

- [ ] **Step 5: 提交代码**
`git add lib/ui/player/poster_player.dart test/ui/player/poster_player_layout_test.dart`
`git commit -m "feat: redesign poster player layout matching qq music mobile style"`

---

### Task 4: 专辑封面点击弹出详情菜单 & 下拉手势退出播放页

**Files:**
- Modify: `lib/ui/player/poster_player.dart`
- Modify: `lib/ui/pages/player_page.dart`
- Test: `test/ui/player/poster_player_gestures_test.dart`

**Interfaces:**
- 封面点击：外层包装 `GestureDetector`，`onTap` 调用现有歌曲详情菜单（即 `_showMoreSheet` / `showSongActionSheet`）。
- 下拉手势退出：在 `PosterPlayerPage` 增加垂直拖拽手势检测：
  - `onVerticalDragUpdate`: 若 `delta.dy > 0` 且无向上拖拽，记录下拉位移；
  - `onVerticalDragEnd`: 若垂直位移 > 80 或速度 > 800，调用 `Navigator.of(context).maybePop()`。

- [ ] **Step 1: 编写失败测试**
创建 `test/ui/player/poster_player_gestures_test.dart`，测试点击封面触发回调，以及垂直下拉手势触发退出回调。

- [ ] **Step 2: 运行测试验证失败**
运行 `flutter test test/ui/player/poster_player_gestures_test.dart`，确认失败。

- [ ] **Step 3: 编写最小实现代码**
1. 封装下拉退出手势感知器；
2. 给封面添加点击事件唤出详情菜单；
3. 联动 `player_page.dart`。

- [ ] **Step 4: 运行测试验证通过**
运行 `flutter test test/ui/player/poster_player_gestures_test.dart`，确保通过。

- [ ] **Step 5: 提交代码**
`git add lib/ui/player/poster_player.dart lib/ui/pages/player_page.dart test/ui/player/poster_player_gestures_test.dart`
`git commit -m "feat: add cover tap sheet and pull-down to dismiss gesture in player page"`

---

### Task 5: 综合联调与全量回归测试

**Files:**
- Test: 所有相关测试以及 `flutter test`

- [ ] **Step 1: 运行全量测试**
运行 `flutter test`，确保歌单、桌面端、车机模式、播放页的所有已有测试均通过，无破坏性改动。

- [ ] **Step 2: 提交最终集成**
`git status` 确认工作区干净。
