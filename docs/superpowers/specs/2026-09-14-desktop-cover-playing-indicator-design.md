# PC 歌曲封面播放状态音波指示与暂停/继续交互设计规范

## 1. 背景与目标
在 PC 桌面端，用户在歌曲封面悬停（hover）时可以快捷播放。然而存在两个体验缺陷：
1. **状态不感知**：歌曲已经在播放时，hover 封面仍然显示播放按钮（三角图标），未能直观反映当前歌曲正在播放的状态；
2. **交互行为不合理**：对正在播放的歌曲再次点击封面播放按钮，会从头重新起播，而非符合用户心智的「暂停」；暂停后再点击也容易从头播放而非「继续」。

本方案优化 PC 端歌曲封面在播放中的展示样式（4 根跳动白色音波柱 + 半透明遮罩），并实现点击智能在「播放 / 暂停 / 继续」之间切换。同时**严格保证移动端与车机端逻辑 100% 零侵入与零副作用**。

---

## 2. 详细设计与交互状态机

### 2.1 状态矩阵
定义歌曲针对播放器的三种状态：
1. **正在播放态 (`isCurrent && isPlaying`)**：
   - **常态（无 hover）**：封面叠加半透明黑色遮罩（`Colors.black38`），正中展示 4 根垂直圆角白色的跳动音频柱；
   - **Hover 态**：保持半透明遮罩与跳动音频柱，光标设为 `SystemMouseCursors.click`，Tooltip 为「暂停」；
   - **点击行为**：触发 `onPause`（调用 `player.pause()`），直接暂停播放，保留当前播放进度。
2. **当前歌曲暂停态 (`isCurrent && !isPlaying`)**：
   - **常态（无 hover）**：普通封面，无遮罩与音波；
   - **Hover 态**：半透明黑底遮罩 + 原有圆形播放按钮，Tooltip 为「继续播放」；
   - **点击行为**：触发 `onResume`（调用 `player.play()`），从当前进度恢复播放，不重新从 0 秒起播。
3. **非当前歌曲态 (`!isCurrent`)**：
   - **常态（无 hover）**：普通封面；
   - **Hover 态**：半透明黑底遮罩 + 原有圆形播放按钮，Tooltip 为「播放」；
   - **点击行为**：触发 `onPlay`，将该歌曲入队并起播。

### 2.2 4 根白色跳动音波组件 (`PlayingVisualizerBar` / `NowPlayingBadge` 增强)
- 结构：4 根圆角矩形条（RRect），颜色为白色（`Colors.white`）；
- 动画特性：
  - 动态计算 4 根柱子的高度百分比，各具独立相位与振幅（约在 0.25 到 0.95 之间）；
  - 当 `playing: true` 时，`AnimationController` 往复循环（周期 ~680ms）；
  - 当 `playing: false` 时，平滑停在初始静态高度；
- 布局：居中于封面中，尺寸适配 36x36 / 48x48 封面。

### 2.3 `CoverPlayOverlay` 组件升级
- 新增属性：
  ```dart
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  ```
- 平台安全保证：
  ```dart
  if (!widget.enabled) {
    return widget.cover;
  }
  ```
  移动端与车机端设置 `enabled: false`，直接返回原始 `cover` 控件，不创建任何 `MouseRegion`、不运行动画、零开销。

### 2.4 业务接入点适配
1. **`DesktopSongTableRow`**：
   - 封面传入 `isCurrent: active`、`isPlaying: player.isPlaying`、`onPause: () => player.pause()`、`onResume: () => player.play()`；
   - 行右侧悬浮小按钮列（140px）：正在播放时显示 `Icons.pause_rounded`（Tooltip: 暂停），点击暂停；其它情况显示 `Icons.play_arrow_rounded`，点击继续或播放。
2. **`HomeSongRow`**：
   - 在 PC 端（`isDesktop: true`）同样将当前播放状态与暂停/恢复回调注入 `CoverPlayOverlay`。
   - 移动端保持 `enabled: false`。

---

## 3. 验证与回归计划
- **桌面端验证**：
  1. 打开歌单列表或搜索结果，鼠标未 hover 时观察正在播放的歌曲：封面居中展示 4 根跳动白条 + 半透明蒙层；
  2. 鼠标 hover 到正在播放的歌曲封面上：鼠标变成手型，提示「暂停」，点击歌曲立即暂停；
  3. 暂停后，封面恢复原图；鼠标再次 hover 时展示圆形播放按钮，点击后平滑继续播放（进度不丢失）；
  4. 检查行右侧操作区悬浮按钮，是否同步切换为「暂停」；
  5. 检查非当前播放歌曲的 hover 播放功能依然正常。
- **移动端与车机端回归**：
  - 验证移动端和车机端歌曲列表渲染与点击播放，确认无任何视觉与交互变更。
