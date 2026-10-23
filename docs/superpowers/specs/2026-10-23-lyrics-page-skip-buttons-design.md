# 歌词页切歌按钮与顶部间距收紧（issue #3）

日期：2026-10-23
分支：`feat/lyrics-skip-buttons`（自 main）
来源：https://github.com/bamboostrip/shiyin-music/issues/3

## 背景与问题

移动端竖屏播放页是 `PageView` 两页结构（封面页 / 歌词页）。歌词页底部栏
`LyricBottomBar` 目前只有：评论入口、[词] 字号、[译]/[音] 开关、圆形播放/暂停键
——**没有上一首/下一首**。用户看歌词听歌时想切歌，必须先横滑回封面页才能点到
切歌键。另外歌词页顶部（页点行 + 歌名头）留白偏大，挤占歌词可视区。

## 目标

1. 歌词页底部栏并入 上一首/下一首 按钮，单行排布，不新增行高。
2. 顶部间距温和收紧，约省 16px 给歌词区。

非目标：桌面/车机分栏布局（`LandscapePlayerContent`）左侧已有完整控制区，不动。

## 方案（用户已确认）

### 改动 1：`LyricBottomBar` 加切歌键（lib/ui/player/lyric_bottom_bar.dart）

- 新增 `_LyricSkipButton`：私有 StatelessWidget，`skip_previous_rounded` /
  `skip_next_rounded` 图标，白色 alpha 0.85，40×40 命中区（IconButton
  `padding: EdgeInsets.zero` 包 `SizedBox.square`），tooltip「上一首/下一首」，
  onPressed 直调 `player.previous()` / `player.next()`（与封面页 `Controls`
  同一 API）。
- 布局：`💬评论 | Spacer | [词][译][音] ◀ ⏯ ▶`——切歌键夹住现有圆形播放/暂停键。
- 防溢出（LayoutBuilder）：正常档 pill 间距 14、切歌键 40px/icon 26；
  紧凑档（可用宽度 < 380 且译音双 pill 在场）间距 10、切歌 icon 22。
  保证 320dp 窄屏「词+译+音+切歌三键」全开不溢出。

### 改动 2：顶部温和收紧

- `TopBar` 页点变体上下内边距 `fromLTRB(8, 8, 8, 6)` → `fromLTRB(8, 4, 8, 2)`
  （lib/ui/player/player_top_bar.dart；封面页共用此栏，同步微收，两页观感一致）。
- 歌词页标题头 `_buildHeader` 上边距 `fromLTRB(20, 6, 16, 8)` → `fromLTRB(20, 2, 16, 8)`
  （lib/ui/player/lyric_views.dart）。
- 合计约省 16px，歌词列表多显约一行。

## 测试

扩展 `test/ui/player/lyric_bottom_bar_test.dart`：

1. 渲染出上一首/下一首按钮（按 ValueKey 断言），点击分别触发
   `player.previous()` / `player.next()`（fake 控制器加计数断言）。
2. 320dp 窄 surface + 译音双 pill 全开渲染无溢出（依靠 Flutter test 的
   overflow 异常即失败语义）。

## 验证

- `flutter analyze`
- `flutter test test/ui/player/`

## 风险

- 底部栏变拥挤：已用紧凑档兜底；极端字体缩放场景由 IconButton 弹性约束吸收。
- TopBar 收紧影响封面页：封面页内容自适应（Spacer/弹性封面），4px 级别变化安全。
