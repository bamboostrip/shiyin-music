# PC 体验修复 · 第二轮（用户反馈 4 项）

来源：用户在 feature/pc-desktop-adaptation 分支实测后反馈。BASE = 50ca235。

## Global Constraints（对所有任务生效）

- **不得破坏移动端**：行为改动必须限定在桌面分支（`isDesktopFormFactor`，`lib/ui/form_factor.dart:19-20`）或桌面歌词等 PC 专属代码路径；移动端复用的组件签名只允许新增**可选**参数，默认行为不变。移动端分支代码（如 `AppHorizontalRail` 路径、底部弹窗）保持原样。
- **桌面歌词技术栈**：子窗 = desktop_multi_window 0.2.x + window_manager（`windows/runner/main.cpp:30-47` 已为子窗补注册 WindowManagerPlugin）；**禁止**在子窗调用 `setSkipTaskbar`（原生调用会杀进程，见 `lib/ui/desktop/lyrics_overlay_window.dart:121-124` 注释）。
- **桌面歌词锁定的产品基准 = QQ 音乐 PC 版**：锁定后窗口对鼠标**完全穿透**，不显示任何工具栏 / hover 卡片 / 边框（歌词文字常显）；解锁入口在主程序（托盘菜单 + 设置页），不在歌词窗内。
- **歌曲操作菜单 PC 规格**（沿用第一轮计划 Task 6）：菜单宽 200~220px、每项高 36~40px、左侧 18px 图标 + 右侧 13px 文字、悬停高亮、点击后关闭并触发 action；本轮新增要求 = **锚定在触发点附近**（右键位置 / ... 按钮下方），屏幕边缘自动翻转，不居中。
- **专辑区 PC 基准 = QQ 音乐 PC 歌手页**：网格布局（多行多列，随宽度自适应列数），不做横向轨道。
- **组件体量**：新增 UI 逻辑优先放独立文件；不要让已超大的页面文件（artist_detail_page / playlist_detail_page）继续明显膨胀，新增块尽量抽组件文件。
- **验证门槛**：每任务 `flutter analyze` 0 issues + 相关测试通过 + 提交（格式 `fix(pc): ...` / `feat(pc): ...`，中文主题，风格与现有提交一致）。

---

## Task 1: 桌面歌词推送就绪门控（根治 MissingPluginException）

**现象**：日志 `[桌面歌词主窗] updateLyric 推送失败（子窗未就绪可能）: MissingPluginException(No implementation found for method updateLyric on channel mixin.one/flutter_multi_window_channel)`。桌面歌词窗口最终能正常显示（有 overlayReady 补发兜底），但异常日志是真实竞态噪音，且冷启动第一次推送必失败。

**根因**（已勘探确认）：
- 主窗 `lib/services/windows_desktop_lyrics_bridge.dart` 的 `_pushLyric()`（约 :181-198）直接 `DesktopMultiWindow.invokeMethod(windowId, 'updateLyric', ...)`；
- 子窗 `lib/ui/desktop/lyrics_overlay_window.dart` 要等 window_manager 样式设置、位置恢复完成后才 `DesktopMultiWindow.setMethodHandler`（约 :163-185）；在此之前主窗任何 invoke 都抛 MissingPluginException；
- 现有兜底：子窗就绪后 `invokeMethod(0, 'overlayReady')`，主窗 handler（bridge :208-215）补发缓存歌词+settings；`windowClosed` 回调置 `_visible=false`。

**要求**：
1. 在 `WindowsDesktopLyricsBridge` 增加 `_overlayReady` 门控：
   - `updateLyrics()` 等推送路径**永远先更新缓存**（`_current/_next/_isPlaying`），但只有 `_overlayReady == true` 才真正 invoke；未就绪时静默跳过（最多 debugPrint）。
   - `overlayReady` handler：先置 `_overlayReady = true`，再执行现有补发逻辑（缓存歌词 + settings）。
   - `windowClosed` 回调：`_overlayReady = false`。
   - 任何重建子窗的路径（`show()` / `_enqueue` 里 createWindow）在创建前重置 `_overlayReady = false`，确保重建后的新引擎等待新一轮握手；注意 hide→show 复用旧窗口时不要误重置导致歌词不再刷新（先读懂 show/hide 的串行队列 `_enqueue` :64-74 再动手）。
2. `_pushLyric` 保留 catch 作为最后防线，日志降级为 debugPrint 级别措辞（不再是 error 样式的"推送失败"）。
3. 若 bridge 可测（现有测试 `test/ui/desktop/desktop_lyrics_test.dart`），补一条行为测试：overlayReady 之前的 updateLyrics 不 invoke 通道；overlayReady 之后补发缓存。若桥接静态依赖难以注入，说明原因并以现有测试全绿 + analyze 为准。

**验收**：analyze 0 issues；桌面歌词相关测试全绿；冷启动不再出现 MissingPluginException 日志路径（代码层面可论证）。

---

## Task 2: 桌面歌词锁定语义 = QQ 音乐式全穿透 + 主窗解锁

**现象**：锁定后仍能 hover 出工具栏并点 X 关闭；hover 出现黑色磨砂卡片（用户称"黑框"）。

**根因**（已勘探确认）：
- `clickThrough = locked && settings.passthrough`（`lyrics_overlay_window.dart:379-381`）：只开 `locked` 不开 `passthrough` 时窗口不穿透，hover 工具栏照常出现；锁定的实际效果只有 `draggable = !locked`（:410）。
- 子窗锁定按钮（:585-597）只改子窗本地 model，**不回传主窗持久化** → 主窗设置页状态不同步。
- `_applyPassthrough()`（:220-228）= `setIgnoreMouseEvents(locked && passthrough)`。

**调研结论（QQ 音乐 PC 基准）**：锁定后工具栏完全消失、窗口完全穿透（歌词纯文字常显），解锁靠主程序托盘右键菜单 / 设置页；锁定态任何依赖 hover 的窗内 UI 都不可能工作（穿透后收不到鼠标事件）。

**要求**：
1. **locked ⇒ 强制穿透**：`_applyPassthrough` 改为只看 `settings.locked`（旧的 `passthrough` 字段保留解析以兼容已持久化 JSON，但 UI 语义上锁定即穿透）。解锁（locked=false）恢复 `setIgnoreMouseEvents(false)`。
2. **锁定态渲染纯歌词**：`build()` 在 locked 时走独立的最简 widget 子树——只有歌词文字（含必要文字阴影），**无 MouseRegion、无工具栏、无容器背景/边框/hover 卡片**；非 locked 才渲染现有 hover+工具栏树。穿透后本收不到鼠标事件，独立子树是为了杜绝过渡帧残留任何 hover UI。
3. **锁定操作同步到主窗**：子窗工具栏锁定按钮改为 `DesktopMultiWindow.invokeMethod(0, 'setLyricsLocked', bool)`；主窗 bridge 新增 handler：更新 `DesktopLyricsService` 的设置并按设置页现有持久化路径落盘，然后把新 settings 推送给子窗（若现有只有 overlayReady 时补发 settings，没有运行中推送，就新增 `applySettings` 推送方法），子窗收到后应用（重建 + 重设穿透）。子窗不再本地直改锁定状态。注意检查 service 是否为 ChangeNotifier/有通知机制，保证设置页 UI 跟着刷新。
4. **解锁入口（主窗侧，参照 QQ 音乐）**：
   - 设置页 `lib/ui/pages/desktop_lyrics_settings_page.dart`（锁定开关约 :120-130）：保留并更新文案为"锁定后桌面歌词鼠标穿透，可在托盘或此处解锁"；若存在独立的"鼠标穿透"开关且语义已被锁定吸收，则移除该开关 UI（保持对旧持久化字段的兼容解析）。桌面歌词未显示时锁定开关应置灰或合理处理（跟随现有页面逻辑判断）。
   - 托盘 `lib/ui/desktop/tray.dart`：右键菜单新增「解锁桌面歌词」项（仅当桌面歌词可见且锁定时可用；若托盘是 checkable 风格则用「锁定桌面歌词」勾选项）。跟随现有托盘菜单实现模式。
5. show/hide、窗口重建路径上穿透状态要与应用设置保持一致（不会出现隐藏后恢复时穿透状态错乱）。
6. **运行时验证点**：确认 `windowManager.setIgnoreMouseEvents` 在子窗内确实作用于子窗 HWND（main.cpp 已为子窗注册 WindowManagerPlugin，子窗已成功使用过 setAsFrameless 等）。若实测/查证后确认无效，回退方案：在 `windows/runner` C++ 里经 `DesktopMultiWindowSetWindowCreatedCallback` 拿子窗 `GetAncestor(view->GetNativeWindow(), GA_ROOT)`，加一个小 MethodChannel 切换 `WS_EX_TRANSPARENT|WS_EX_LAYERED`。报告里写明实际走的是哪条路径与依据。真机验证留给用户，报告需给出手动验证步骤清单。

**测试**：更新/扩展 `test/ui/desktop/desktop_lyrics_test.dart`：locked 子树不含工具栏/hover 组件；settings 兼容旧字段；锁定→主窗 handler→回推链路的可测部分。analyze 0 issues，相关测试全绿。

---

## Task 3: 歌曲操作弹窗锚定到触发位置（PC）

**现象**：PC 上右键歌曲行或点行尾 `...` 按钮，操作菜单出现在屏幕正中，不符合 PC 上下文菜单习惯（用户截图确认）。

**根因**（已勘探确认）：桌面分支 `_showDesktopSongActionMenu`（`lib/ui/widgets/song_action_sheets.dart` 约 :536-552）用 `showDialog` + `Dialog`/`Center`（约 :579-583）→ 居中；入口 `showSongActionSheet`（:31-42）签名无坐标；调用链里 `onMore` 是 `VoidCallback`，右键位置（`onSecondaryTapDown` 的 globalPosition，`playlist_detail_page.dart` 约 :3474）在传递中丢失。调用点约 13 处（artist_detail_page.dart:275/512、playlist_detail_page.dart:1665、rank_page.dart:993/1552、首页"母带音质·精选"行等——请 grep `showSongActionSheet` 全量确认）。

**要求**：
1. `showSongActionSheet` 新增可选参数 `Offset? anchor`（全局坐标）。移动端分支**完全忽略**该参数（底部弹窗不变）；PC 分支：`anchor != null` → 走锚定路由，否则维持现有居中 dialog 兜底。
2. 新建 `lib/ui/widgets/desktop_anchored_menu.dart`：通用 PC 锚定菜单路由。
   - API 建议：`Future<T?> showDesktopAnchoredMenu({required BuildContext context, required Offset anchor, required Size menuSize, required WidgetBuilder builder})`（或等价形式），内部用自定义 PopupRoute/GeneralDialog：全屏透明 barrier（点击空白处关闭 + Esc 关闭）+ 按锚点定位的菜单 Material。
   - **定位策略抽成纯函数**（如 `Rect placeAnchoredMenu({required Offset anchor, required Size menuSize, required Size screenSize})`）便于单测：默认锚点为菜单左上角参考点，右/下溢出时向左/上翻转，屏幕四周留 ≥8px 边距。
   - 菜单外观规格沿用 Global Constraints（宽 200~220 等）；菜单内容 widget 复用 song_action_sheets.dart 现有桌面菜单条目构建（不要复制一份条目代码）。
   - 同时导出小工具 `Offset anchorBelow(BuildContext ctx)`（取 RenderBox 底边中点的全局坐标）供 `...` 按钮调用点复用。
3. 调用点改造（全部 PC 可达路径）：
   - `...` 按钮：`onPressed: () => showSongActionSheet(..., anchor: anchorBelow(context))`。
   - 右键：表格行 `InkWell.onSecondaryTap` → 改用 `onSecondaryTapDown` 拿 `details.globalPosition`；行组件回调签名以**新增可选参数**方式传递位置（如 `void Function(Offset globalPos)? onSecondaryMore`），保持旧 `onMore` 兼容，更新 `DesktopSongTableRow` 全部使用点（playlist_detail_page、rank_page、artist_detail_page 等）。
   - 逐个 grep 调用点，PC 界面上全部传 anchor。
4. 菜单弹出后若窗口尺寸变化/滚动，不做跟随（关闭重开即可接受），但 barrier 必须覆盖全屏且 ESC 可关。

**测试**：为 `placeAnchoredMenu` 纯函数写单测（右下翻转、贴边距、正常居中偏移）；analyze 0 issues；现有相关测试全绿。

---

## Task 4: 歌手页专辑 PC 网格化 + 横向轨道滚轮放行

**现象**：PC 歌手详情页专辑区横向滚动，鼠标滚轮滚不动；且用户质疑横向轨道不符合 PC 习惯（基准：QQ 音乐 PC 歌手页为网格）。

**根因**（已勘探确认）：
- `lib/ui/pages/artist_detail_page.dart` `_ArtistAlbumSection`（约 :704-763）：PC 分支 `SizedBox(height:168)` + `HorizontalWheelScroll` 包横向 `ListView.separated`（:726-745）；移动端 `AppHorizontalRail`（:752）。
- `lib/ui/widgets/horizontal_wheel_scroll.dart` `_scrollOnWheel`（约 :60-71）守卫 `if (position.maxScrollExtent <= 0) return;`——事件已被 Listener 注册消费，直接 return 后**既不滚动也不放行**，父级纵向滚动收不到；内容不超宽的专辑区因此完全"吃"掉滚轮。内容可滚时到边缘同样卡住。

**要求**：
1. **专辑区 PC 网格化**：PC 分支改为响应式网格（QQ 音乐风格）：
   - 优先用 Sliver 体系（`SliverLayoutBuilder`/`SliverGrid`，视页面现有 sliver 结构定）；列数 = `(可用宽 / ~168).clamp(4, 8)`。
   - 卡片内容沿用现卡片：方形圆角封面 + 专辑名（1~2 行省略）+ 发行日期；点击行为（进专辑页）不变；section 标题（"专辑 20"）样式不变。
   - 专辑网格抽到独立文件（如 `lib/ui/widgets/album_grid.dart`，平台中立；PC 用网格、移动端保持原 `AppHorizontalRail` 分支不动），控制 artist_detail_page 体量。
2. **horizontal_wheel_scroll 滚轮放行修复**（组件保留，排行榜详情页等其他使用点受益）：
   - 不可滚动（`maxScrollExtent <= 0`）或已到目标方向边缘（`delta > 0 && offset >= max - ε` / `delta < 0 && offset <= ε`）时，不吞事件：把滚轮转发给外层纵向 Scrollable —— `Scrollable.maybeOf(context)?.position.pointerScroll(event.scrollDelta.dy)`（注意用能取到外层 Scrollable 的 context；组件内层 context 可能查不到，需要用组件外部传入的祖先 context 或合适查找方式）。
   - 可滚方向上行为保持现状。grep `HorizontalWheelScroll` 全部使用点，确认无回归。
3. 移动端路径零改动。

**测试**：列数计算抽纯函数并加单测；滚轮放行逻辑若可抽纯函数（判断"是否消费/转发"）也加单测；analyze 0 issues；现有测试全绿。

---

## 执行顺序与依赖

Task 1 → Task 2（同文件，串行）；Task 3 → Task 4（artist_detail_page 交叠，串行）。四个任务由控制器逐个派发实现子代理 + 审查子代理；全部完成后做整分支最终审查（base = 50ca235）与 `flutter analyze` / 全量测试验证。
