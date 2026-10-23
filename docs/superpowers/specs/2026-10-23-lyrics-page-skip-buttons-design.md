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
2. 顶部间距温和收紧，约省 12px 给歌词区（页点行 8 + 标题头 4）。

非目标：桌面/车机分栏布局（`LandscapePlayerContent`）左侧已有完整控制区，不动。

## 方案（用户已确认）

### 改动 1：`LyricBottomBar` 加切歌键（lib/ui/player/lyric_bottom_bar.dart）

- 新增 `_LyricSkipButton`：私有 StatelessWidget，`skip_previous_rounded` /
  `skip_next_rounded` 图标，白色 alpha 0.85，40×40 命中区（IconButton
  `padding: EdgeInsets.zero` 包 `SizedBox.square`），tooltip「上一首/下一首」，
  onPressed 直调 `player.previous()` / `player.next()`（与封面页 `Controls`
  同一 API）。
- 布局：`💬评论 | Spacer | [词][译][音] ◀ ⏯ ▶`——切歌键夹住现有圆形播放/暂停键。
- 防溢出（LayoutBuilder 三档 + 极窄兜底）：
  - 正常档（可用宽度 ≥380）：pill 间距 14、切歌键 40×40 / icon 26、水平边距 16
  - 紧凑档（340~379）：pill 间距 10、切歌键 36×36 / icon 22、水平边距 16
  - 超紧凑档（<340）：pill 间距 8、切歌键 32×32 / icon 20、水平边距 12
  - 三档只看可用宽度，不依赖译/音 pill 是否在场。320dp「词+译+音+切歌三键」
    全开恰余 6px（原版关闭态在 320dp 余 56px）。切歌键 40/36/32 均小于
    Material 48dp 最小点击目标，属紧凑取舍（同栏药丸 34×30、播放键 40×40
    也是既有尺寸）。老实现的安全下限是 314dp：<314dp（分屏/小窗/折叠屏外屏/
    超大系统显示尺寸）会 RenderFlex 溢出；现右组外层改 `Expanded + Align +
    FittedBox(scaleDown)` 兜底——正常宽度不缩放、与原布局像素级一致，极窄
    宽度整组等比缩小而不是把「下一首」裁出屏幕。

### 改动 2：顶部温和收紧

- `TopBar` 页点变体上下内边距 `fromLTRB(8, 8, 8, 6)` → `fromLTRB(8, 4, 8, 2)`
  （lib/ui/player/player_top_bar.dart；封面页共用此栏，同步微收，两页观感一致）。
- 歌词页标题头 `_buildHeader` 上边距 `fromLTRB(20, 6, 16, 8)` → `fromLTRB(20, 2, 16, 8)`
  （lib/ui/player/lyric_views.dart）。
- 合计约省 12px（页点行 8 + 标题头 4）；按歌词行高约 26~33px 计不足整行，
  属温和收紧而非「多显一行」。

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

- 底部栏变拥挤：已用紧凑档 + FittedBox 兜底；系统字体缩放到 2.0 以上时
  药丸内文字会溢出 34×30 固定容器、on/off 角标会压到相邻药丸（既有观感
  问题，与切歌键无关）；切歌键 icon 是固定尺寸，不随字体缩放。
- TopBar 收紧影响封面页：封面页内容自适应（Spacer/弹性封面），4px 级别变化安全。

## 修订（2026-10-23，用户真机预览后反馈）

用户预览后反馈切歌键常驻「不好看」：改为**设置门控、默认关闭**。

- 新增 `PlayerController.lyricPageSkipButtonsEnabled`（默认 false，键
  `settings.lyric_page_skip_buttons`，`setLyricPageSkipButtonsEnabled` 落盘），
  设置入口在 设置-播放-「歌词页切歌键」（移动端瓦片，桌面分栏不显示）。
- `LyricBottomBar` 增 `showSkipButtons` 参数（默认 false）：关闭时完整还原
  原版常量间距；开启时才走三档防溢出布局。
- `LyricPlayerPage` 从 `player.lyricPageSkipButtonsEnabled` 接线；
  controller notifyListeners 使设置返回后底栏即时显隐。
- 顶部间距收紧不受影响，保持生效。提交 c056c53。

## 修订 2（2026-10-23，代码评审后修复）

- **窄宽兜底**：三档布局在 `<314dp` 必溢出（314dp 恰好放满、313dp 溢出
  1px、300dp 溢出 14px；关闭设置的原版下限是 264dp）。右组外层改为
  `Expanded + Align + FittedBox(scaleDown)`，极窄宽度整组等比缩小而不是
  把「下一首」裁出屏幕；正常宽度不缩放、与原布局像素级一致。回归用例
  覆盖 280/300/313/314/320/340/360/379/380/412dp，并断言正常档位尺寸
  与「下一首」完整在屏内。
- **顶部收紧数值勘误**：实际省 12px（页点行 8 + 标题头 4），原文「16px」
  与「多显约一行」均不成立，已在「目标」与「改动 2」段落改正。
- **三档表写实**：触发条件只看可用宽度（不依赖译/音 pill 在场）；补录
  `<340` 第三档；命中区写实为 40/36/32（低于 Material 48dp，属紧凑取舍）；
  字体缩放不再声称「由 IconButton 弹性约束吸收」。
- **「即时显隐」机制说明**：依赖 `PlayerController.notifyListeners` +
  `PlayerPage` 的 `AnimatedBuilder(player)` 重建；当前导航形态下设置页与
  播放页不会并存，用户感知为「下次进入播放页即读取最新值」，而非在播放页
  上实时切换。
- **补测试**：设置瓦片桌面/移动/FORCE_MOBILE 门控与点击写回、PlayerPage
  级开关即时显隐与切歌调用、prefs 默认值/启动恢复/落盘幂等 round-trip。
- **已知限制**：车机/PC 横屏分栏布局没有 `LyricBottomBar`，该设置在这些
  形态下不生效（修订 3 起直接隐藏瓦片；手机横屏非车机模式仍走 PageView，
  生效）。

## 修订 3（2026-10-23，产品口径收窄）

- 该设置只服务手机/平板形态：**PC（`isDesktopFormFactor`）与车机（车机
  模式 `carModeEnabled` 或车机设备 `isAutomotiveDevice`）隐藏「歌词页
  切歌键」瓦片**，从入口层面消除「看得到但无效」——车机横屏走分栏布局、
  没有移动端歌词页底栏，PC 更是没有移动端歌词页。
- 可见性由 `SettingsPage` 计算后传入 `PlaybackSettingsSection`
  （`showLyricPageSkipButtons`），并随 `ThemeController` 通知即时显隐：
  开启车机模式瓦片消失，关闭后（或换回手机形态）瓦片恢复；已持久化的
  开关值保留，不受可见性影响。
- 手机/平板（移动端形态）仍展示；`FORCE_MOBILE` 调试预览按移动端口径
  展示，属调试通道预期行为。
