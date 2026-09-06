# 移动端播放页交互式跟手下拉退出与底层保活路由（QQ音乐同款）实现方案

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现移动端播放页从屏幕底部向上滑入覆盖全屏，在封面页或顶栏向下拉动时整个播放页（包含毛玻璃背景、顶栏、卡片）1:1 跟手向下平移并动态带出顶部 12px 圆角，实时显露出底层的上一个页面（主页/歌单页）；松手根据距离阈值弹性回弹或平滑滑出退出。

**Architecture:** 
1. **路由层**：封装 `PlayerPageRoute`（继承自 `PageRouteBuilder`），设置 `opaque: false` 确保底层路由在全屏展示时持续渲染保活；入场/退场采用自底向上/向下的 `SlideTransition`（300ms/250ms）；
2. **手势与容器层**：将下拉阻尼手势由 `PosterPlayerPage` 的局部内容列提升至 `PlayerPage` 最外层容器，使用 `Transform.translate(offset: Offset(0, _dragDistance))` 驱动整个页面平移，外覆 `ClipRRect(borderRadius: BorderRadius.vertical(top: Radius.circular(_dragDistance > 0 ? 12 : 0)))`；
3. **松手与动效衔接**：未达 80px 阈值松手由 `AnimationController` 以 `easeOutCubic` 曲线快速回弹；超过阈值或快速下甩则由控制器以 `easeInCubic` 顺势滑出屏幕底部并执行 `Navigator.pop()`。

**Tech Stack:** Flutter Framework (`PageRouteBuilder`, `SlideTransition`, `AnimationController`, `Transform.translate`, `ClipRRect`, `GestureDetector`)。

## Global Constraints

- **PC 桌面端与车机横屏双拼模式完全不受影响**：`isDesktopFormFactor || (landscape && ThemeController.instance.carModeEnabled)` 时维持桌面现有转场与布局。
- **歌词页手势隔离**：歌词页的垂直滑动属于歌词列表滚动，不触发整页下拉；仅封面页空白/封面区域及顶栏区域触发下拉手势。
- **横向切页不受影响**：左右横滑切歌词由 `PageView` 保持原有逻辑，水平手势与垂直下拉手势互不冲突。
- **语义与崩溃防护**：保留外层 `ExcludeSemantics`，避免 Windows AXTree 竞态崩溃。
- **所有现有测试通过**。

---

## Tasks

### Task 1: 实现移动端专属半透明弹出路由 `PlayerPageRoute`

**Files:**
- Create: `lib/ui/player/player_route.dart`
- Test: `test/ui/player/player_route_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class PlayerPageRoute<T> extends PageRouteBuilder<T> {
    PlayerPageRoute({required WidgetBuilder builder});
    static Future<T?> open<T>(
      BuildContext context, {
      required PlayerController player,
      required AuthController auth,
    });
  }
  ```

- [ ] **Step 1: Write the failing test** in `test/ui/player/player_route_test.dart`
- [ ] **Step 2: Run test to verify it fails** (`flutter test test/ui/player/player_route_test.dart`)
- [ ] **Step 3: Implement minimal code** in `lib/ui/player/player_route.dart`
- [ ] **Step 4: Run test to verify it passes** (`flutter test test/ui/player/player_route_test.dart`)
- [ ] **Step 5: Commit** (`feat: add PlayerPageRoute with non-opaque bottom slide transition`)

---

### Task 2: 将下拉手势与平移提升至 `PlayerPage` 顶层整页容器

**Files:**
- Modify: `lib/ui/pages/player_page.dart`
- Modify: `lib/ui/player/poster_player.dart`
- Modify: `lib/ui/player/player_top_bar.dart`
- Test: `test/ui/player/poster_player_gestures_test.dart`
- Test: `test/ui/player/player_pull_down_dismiss_test.dart`

**Interfaces:**
- Consumes: `PlayerPageRoute` from Task 1
- Produces:
  `PlayerPage` 最外层容器响应垂直下拉，`Transform.translate(offset: Offset(0, _dragDistance))` 带着背景、顶栏和卡片整体下移，并动态带有 `ClipRRect(borderRadius: BorderRadius.vertical(top: Radius.circular(_dragDistance > 0 ? 12 : 0)))`。

- [ ] **Step 1: Write the failing test** in `test/ui/player/player_pull_down_dismiss_test.dart`
- [ ] **Step 2: Run test to verify it fails** (`flutter test test/ui/player/player_pull_down_dismiss_test.dart`)
- [ ] **Step 3: Implement minimal code** in `lib/ui/pages/player_page.dart`, `lib/ui/player/poster_player.dart`, `lib/ui/player/player_top_bar.dart`
- [ ] **Step 4: Run test to verify it passes** (`flutter test test/ui/player/player_pull_down_dismiss_test.dart` and `test/ui/player/poster_player_gestures_test.dart`)
- [ ] **Step 5: Commit** (`feat: move pull down translation to full player page container with dynamic top radius`)

---

### Task 3: 路由入口统一接入与完整回归

**Files:**
- Modify: `lib/ui/widgets/mini_player.dart`
- Modify: `lib/ui/pages/app_shell.dart`
- Test: `test/ui/player/player_pull_down_dismiss_test.dart`

- [ ] **Step 1: Write integration test** verifying opening via MiniPlayer uses PlayerPageRoute
- [ ] **Step 2: Run test to verify it fails**
- [ ] **Step 3: Implement minimal code** in `mini_player.dart` and `app_shell.dart`
- [ ] **Step 4: Run test to verify it passes**
- [ ] **Step 5: Commit** (`feat: wire PlayerPageRoute into mini player and app shell`)

---

## Verification Plan

### Automated Tests
- `flutter test test/ui/player/player_route_test.dart`
- `flutter test test/ui/player/poster_player_gestures_test.dart`
- `flutter test test/ui/player/player_pull_down_dismiss_test.dart`
- `flutter test test/ui/`
- `flutter analyze`
