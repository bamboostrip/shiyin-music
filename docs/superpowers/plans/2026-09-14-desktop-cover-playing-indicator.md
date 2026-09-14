# PC 歌曲封面播放状态音波指示与暂停/继续交互实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 PC 桌面端歌曲封面和悬浮操作栏实现播放状态感知：正在播放时展示 4 根跳动白色音波，点击暂停；暂停态点击继续播放，非当前歌曲点击起播。移动端与车机端严格 0 侵入。

**Architecture:** 
1. 增强 `NowPlayingBadge` 支持 `barCount: 4` 参数，绘制 4 根跳动白色圆角音波柱；
2. 升级 `CoverPlayOverlay`，内置状态矩阵（正在播放、当前暂停、非当前歌曲），根据状态自适应渲染蒙层、音波或圆形播放按钮，并分发 `onPause`/`onResume`/`onPlay` 回调；`enabled: false` 时直接返回原始封面保证移动/车机隔离；
3. 将 `DesktopSongTableRow` 与 `HomeSongRow` 接入新的播放状态与回调，并联动表格行右侧悬浮播放图标。

**Tech Stack:** Flutter, Dart, CustomPainter, AnimationController.

## Global Constraints
- 平台隔离：`enabled: false` 时必须直接返回 `widget.cover`，不得挂载任何 `MouseRegion` 或手势；
- 状态一致：正在播放点击必须暂停（`player.pause()`），暂停点击必须恢复进度（`player.play()`），不得重新从 0 秒加载；
- 样式还原：4 根白条垂直居中，白色半透明圆角，与 QQ 音乐截图视觉一致。

---

### Task 1: 增强 `NowPlayingBadge` 支持 4 根音波柱与自定义尺寸/比例

**Files:**
- Modify: `lib/ui/widgets/now_playing_badge.dart`
- Test: `test/ui/widgets/now_playing_badge_test.dart`

**Interfaces:**
- Consumes: `NowPlayingBadge` existing props (`active`, `playing`, `color`, `size`)
- Produces: `NowPlayingBadge` with `int barCount = 3` (default 3, supports 4)

- [ ] **Step 1: 编写测试用例**

创建 `test/ui/widgets/now_playing_badge_test.dart`：
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/now_playing_badge.dart';

void main() {
  testWidgets('NowPlayingBadge renders with 3 bars by default and 4 bars when specified', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: NowPlayingBadge(
            active: true,
            playing: true,
            color: Colors.white,
            barCount: 4,
          ),
        ),
      ),
    );
    expect(find.byType(NowPlayingBadge), findsOneWidget);
    expect(find.byType(CustomPaint), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

运行: `flutter test test/ui/widgets/now_playing_badge_test.dart`
预期: 编译失败（`barCount` 参数未定义）

- [ ] **Step 3: 修改 `lib/ui/widgets/now_playing_badge.dart` 实现 `barCount` 支持**

在 `NowPlayingBadge` 构造函数增加 `this.barCount = 3`，并在 `_NowPlayingPainter` 中根据 `barCount` 动态计算 3 柱或 4 柱的高度与位置：
```dart
class NowPlayingBadge extends StatefulWidget {
  const NowPlayingBadge({
    super.key,
    required this.active,
    required this.playing,
    required this.color,
    this.size = 18,
    this.barCount = 3,
  });

  final bool active;
  final bool playing;
  final Color color;
  final double size;
  final int barCount;
...
```

`_NowPlayingPainter` 中支持 4 柱计算：
```dart
class _NowPlayingPainter extends CustomPainter {
  const _NowPlayingPainter({
    required this.progress,
    required this.color,
    this.barCount = 3,
  });

  final double progress;
  final Color color;
  final int barCount;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final count = barCount;
    // 总宽分为 count 个柱子 + (count - 1) 个间距，间距取柱宽的 50%
    final barWidth = size.width / (count + (count - 1) * 0.5);
    final gap = barWidth * 0.5;

    final List<double> values;
    if (count == 4) {
      values = [
        .32 + .48 * progress,
        .88 - .45 * progress,
        .45 + .50 * (1 - (progress - .5).abs() * 2),
        .35 + .35 * (progress > .5 ? 1 - progress : progress) * 2,
      ];
    } else {
      values = [
        .42 + .36 * progress,
        .72 - .28 * progress,
        .48 + .44 * (1 - (progress - .5).abs() * 2),
      ];
    }

    for (var i = 0; i < values.length; i++) {
      final height = size.height * values[i].clamp(.25, .95);
      final left = i * (barWidth + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - height, barWidth, height),
        Radius.circular(barWidth / 2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _NowPlayingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.color != color ||
        oldDelegate.barCount != barCount;
  }
}
```

- [ ] **Step 4: 运行测试验证通过**

运行: `flutter test test/ui/widgets/now_playing_badge_test.dart`
预期: 测试通过

- [ ] **Step 5: 提交代码**

```bash
git add lib/ui/widgets/now_playing_badge.dart test/ui/widgets/now_playing_badge_test.dart
git commit -m "feat: support 4-bar mode in NowPlayingBadge"
```

---

### Task 2: 升级 `CoverPlayOverlay` 支持播放态音波展示与点击暂停/继续

**Files:**
- Modify: `lib/ui/widgets/cover_play_overlay.dart`
- Test: `test/ui/widgets/cover_play_overlay_test.dart`

**Interfaces:**
- Consumes: `NowPlayingBadge` with `barCount: 4`
- Produces: `CoverPlayOverlay` with `isCurrent`, `isPlaying`, `onPause`, `onResume`

- [ ] **Step 1: 编写测试用例**

创建 `test/ui/widgets/cover_play_overlay_test.dart`，覆盖：
1. `enabled: false` 纯封面渲染；
2. `isCurrent: true, isPlaying: true` 时展示 4 根音波且点击触发 `onPause`；
3. `isCurrent: true, isPlaying: false` 时点击触发 `onResume`；
4. `isCurrent: false` 时点击触发 `onPlay`。

- [ ] **Step 2: 运行测试验证失败**

运行: `flutter test test/ui/widgets/cover_play_overlay_test.dart`
预期: 编译失败（缺少属性）

- [ ] **Step 3: 修改 `CoverPlayOverlay` 实现状态机与交互**

在 `lib/ui/widgets/cover_play_overlay.dart`：
1. 增加属性：
   ```dart
   final bool isCurrent;
   final bool isPlaying;
   final VoidCallback? onPause;
   final VoidCallback? onResume;
   ```
2. 保持头部守卫：
   ```dart
   if (!widget.enabled) {
     return widget.cover;
   }
   ```
3. 构建音波态与播放按钮态：
   - 当 `isCurrent && isPlaying`：
     - 蒙层常驻显示（`darkenOnHover` 或 `isCurrent && isPlaying`）；
     - 居中展示 `NowPlayingBadge(active: true, playing: true, color: Colors.white, size: 16, barCount: 4)`；
     - hover 时光标为 click，Tooltip 显示「暂停」，点击触发 `widget.onPause ?? widget.onPlay`；
   - 当 `isCurrent && !isPlaying`：
     - 常态普通封面，hover 浮现圆形播放按钮，Tooltip「继续播放」，点击触发 `widget.onResume ?? widget.onPlay`；
   - 当 `!isCurrent`：
     - 常态普通封面，hover 浮现圆形播放按钮，Tooltip「播放」，点击触发 `widget.onPlay`。

- [ ] **Step 4: 运行测试验证通过**

运行: `flutter test test/ui/widgets/cover_play_overlay_test.dart`
预期: 所有测试用例 PASS

- [ ] **Step 5: 提交代码**

```bash
git add lib/ui/widgets/cover_play_overlay.dart test/ui/widgets/cover_play_overlay_test.dart
git commit -m "feat: support playing visualizer and pause/resume in CoverPlayOverlay"
```

---

### Task 3: 在 `DesktopSongTableRow` 中接入封面状态与悬浮操作栏联动

**Files:**
- Modify: `lib/ui/widgets/desktop_song_table_row.dart`

**Interfaces:**
- Consumes: `CoverPlayOverlay` (`isCurrent`, `isPlaying`, `onPause`, `onResume`)
- Produces: PC 歌曲表格行的封面与右侧悬浮按钮同步联动播放/暂停

- [ ] **Step 1: 修改封面 `CoverPlayOverlay` 调用参数**

在 `lib/ui/widgets/desktop_song_table_row.dart`：
```dart
CoverPlayOverlay(
  enabled: true,
  isHovered: !selecting && _hovering && widget.showHoverActions,
  isCurrent: active,
  isPlaying: active && player.isPlaying,
  onPause: () => player.pause(),
  onResume: () => player.play(),
  borderRadius: 4,
  buttonSize: 26,
  iconSize: 18,
  buttonColor: Colors.black54,
  iconColor: Colors.white,
  onPlay: widget.onPlay,
  cover: Artwork(
    url: song.coverUrl,
    size: 36,
    borderRadius: 4,
  ),
),
```

- [ ] **Step 2: 修改右侧悬浮小按钮联动播放/暂停**

在 `lib/ui/widgets/desktop_song_table_row.dart` 的悬浮操作列（140px）：
```dart
final isCurrentPlaying = active && player.isPlaying;
_DesktopRowIconButton(
  icon: isCurrentPlaying
      ? Icons.pause_rounded
      : Icons.play_arrow_rounded,
  tooltip: isCurrentPlaying
      ? '暂停'
      : (active ? '继续播放' : '播放'),
  onTap: () {
    if (isCurrentPlaying) {
      player.pause();
    } else if (active) {
      player.play();
    } else {
      widget.onPlay();
    }
  },
),
```

- [ ] **Step 3: 运行自动化测试与静态分析**

运行: `flutter analyze lib/ui/widgets/desktop_song_table_row.dart`
预期: 0 errors

- [ ] **Step 4: 提交代码**

```bash
git add lib/ui/widgets/desktop_song_table_row.dart
git commit -m "feat: link DesktopSongTableRow cover and hover buttons to play/pause state"
```

---

### Task 4: 在 `HomeSongRow` 中接入 PC 封面播放/暂停状态

**Files:**
- Modify: `lib/ui/widgets/home_song_row.dart`

**Interfaces:**
- Consumes: `CoverPlayOverlay` (`isCurrent`, `isPlaying`, `onPause`, `onResume`)
- Produces: 首页歌曲行封面状态支持

- [ ] **Step 1: 修改 `HomeSongRow` 封面的 `CoverPlayOverlay`**

在 `lib/ui/widgets/home_song_row.dart`：
```dart
CoverPlayOverlay(
  enabled: isDesktop,
  isHovered: _hovered,
  isCurrent: active,
  isPlaying: active && widget.player.isPlaying,
  onPause: () => widget.player.pause(),
  onResume: () => widget.player.play(),
  borderRadius: coverRadius,
  buttonSize: isDesktop ? 28 : 32,
  iconSize: isDesktop ? 18 : 22,
  buttonColor: Colors.black54,
  iconColor: Colors.white,
  onPlay: () => widget.onPlay(widget.song, widget.queue),
  cover: Artwork(
    url: widget.song.coverUrl,
    size: coverSize,
    borderRadius: coverRadius,
  ),
),
```

- [ ] **Step 2: 运行自动化测试与静态分析**

运行: `flutter analyze lib/ui/widgets/home_song_row.dart`
预期: 0 errors

- [ ] **Step 3: 提交代码**

```bash
git add lib/ui/widgets/home_song_row.dart
git commit -m "feat: link HomeSongRow cover to play/pause state on desktop"
```

---

### Task 5: 全局测试验证与回归确认

**Files:**
- Test: All touched tests

- [ ] **Step 1: 运行全量 widget 测试**

运行: `flutter test test/ui/widgets/`
预期: 全部通过

- [ ] **Step 2: 运行整体 flutter analyze**

运行: `flutter analyze`
预期: 无引入的新 issue

- [ ] **Step 3: 验证提交**

```bash
git status
```
确保工作区整洁。
