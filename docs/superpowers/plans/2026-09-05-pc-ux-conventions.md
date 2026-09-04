# PC 桌面交互习惯对齐 · 第三轮（审计驱动）

来源：对 feature/pc-desktop-adaptation 全分支的两轮只读审计（全局层 + 页面层）与主流 PC 音乐软件（QQ音乐/网易云/Spotify）联网调研。BASE = 8e4abfb。

## Global Constraints（对所有任务生效）

- **不得破坏移动端与车机端**：多数页面是三端共用单文件，一切行为改动必须 `isDesktopFormFactor` 门控（车机/移动端该值恒为 false，行为保持逐字节不变）；共享签名只加可选参数。
- **新依赖白名单**：仅允许 `local_notifier` 与 `launch_at_startup`（Windows 支持良好）。若实现中发现白名单依赖不可用，降级为不引入并说明，不得自行引入其他依赖。
- **键盘改动双端隔离**：AppShortcutScope 在双端共用外壳挂载（app_shell.dart），桌面/移动端使用不同快捷键表时必须按 `isDesktopFormFactor` 选择，移动端快捷键表保持现状。
- 复用已有 PC 组件与 token（desktop_anchored_menu 的锚定路由/定位纯函数、design_tokens、AppTheme），不复制粘贴；新增 UI 优先独立文件，超大文件（artist/playlist/search page）只减不增或增量抽文件。
- 验证门槛：每任务 `flutter analyze` 0 issues + 相关测试通过 + 全量 `flutter test` 提交前跑一次；提交信息 `feat(pc): ...` / `fix(pc): ...` 中文主题。
- 主流基准（调研结论）：单击选中/双击播放/右键菜单；进度条点击+拖拽+悬停时间气泡；音量滚轮微调；队列=锚定弹层或右侧面板；细滚动条 hover 加深；窗口标题显示"歌名 - 歌手"；下载完成有系统通知；无限滚动。

---

## Task 1: 键盘快捷键重整 + 侧栏键盘可达 + IME 守卫

**动机**（审计 P0/P1/P2）：←/→ 被绑成上一首/下一首（app_shell.dart:717-724），全应用无 seek 快捷键，违反 PC 播放器惯例；侧栏导航项/搜索胶囊是 GestureDetector，Tab 不可达、无焦点环（desktop_sidebar.dart:123,196-197）；Ctrl+4/5/6 未绑定（desktop_shell.dart:162-167 只有 1-3）；搜索提交无 IME composing 防御（search_page.dart:280,413）。

**要求**：
1. 桌面端快捷键表改为：←/→ = 快退/快进 ±5 秒（seek 相对当前进度，clamp 到 0..时长）；Ctrl+←/→ = 上一首/下一首。空格=播放/暂停、↑/↓=音量 ±5%、Ctrl+F、Enter 保持。**移动端快捷键表逐字节保持现状**（含 ←/→ 切歌）。
2. 空格退让：当焦点在可滚动区域内（非输入框/按钮）时，空格交给滚动（翻页），不再触发播放暂停。实现放 keyboard_focus_guard.dart 的守卫逻辑里，桌面端生效即可（移动端无此快捷键场景可不动）。
3. 侧栏导航项与搜索胶囊改为可键盘聚焦（FocusableActionDetector 或 InkWell），Tab 可达、Enter/Space 激活、保留现有 hover 样式并显示焦点环；Tab 顺序 = 侧栏自上而下。
4. 补 Ctrl+4/5/6 → 我的音乐/已下载/设置（与 desktop_shell 现有 1-3 同机制，同步侧栏高亮）。
5. 搜索提交（search_page.dart onSubmitted 路径）加 IME 防御：`value.composing != TextRange.empty` 时忽略提交（三端生效但纯防御，无行为风险）。
6. 测试：桌面/移动快捷键表映射的纯函数测试（←/→ 两端语义不同、Ctrl 组合、空格退让判定函数）；IME 守卫纯函数测试。

---

## Task 2: 桌面播放条控制增强（播放模式/音量/进度气泡）

**动机**（审计 P0/P1/P2）：底栏无播放模式（随机/单曲/列表循环）按钮，只能进全屏播放页切（desktop_player_bar.dart:116-186）；音量图标不可交互，无点击静音、无滚轮调音量（:307-315）；进度条悬停无时间预览气泡（:233-266）。主流基准：模式切换在底栏、音量图标滚轮/点击静音、进度条悬停气泡。

**要求**：
1. 播放模式按钮加到底栏（"下一首"按钮旁），复用 player_page 现有播放模式枚举与切换逻辑（Icons.repeat/shuffle 的现有语义），图标随模式变化，tooltip 显示当前模式（"列表循环/随机播放/单曲循环"，含"点击切换"提示），与全屏页状态同步（同一 controller 字段）。
2. 音量图标：点击 = 静音/取消静音（记忆静音前音量）；图标区域滚轮 ±5%（clamp 0..100），图标随静音状态换图标（volume_off/volume_down/up）；音量条拖拽保持。
3. 进度条悬停：MouseRegion 跟踪悬停位置，上方小气泡显示该位置对应时间（mm:ss），跟随移动、离开消失；拖拽中不显示悬停气泡（拖拽本身已有反馈）。
4. 新增逻辑（静音记忆、滚轮步进、悬停位置→时间的换算）抽可测纯函数/小控制器并加单测；widget 测试覆盖模式按钮点击切换、音量图标点击静音。
5. 只改桌面播放条分支；移动端 MiniPlayer/car 面板零改动。

---

## Task 3: 播放队列 PC 锚定面板

**动机**（审计 P1）：桌面端播放队列仍是移动端 `showModalBottomSheet` 底部抽屉（queue_sheet.dart:16-19，入口 desktop_player_bar.dart:183）。主流基准：网易云为底栏按钮锚定弹层。

**要求**：
1. 新建 `lib/ui/widgets/desktop_queue_panel.dart`：队列锚定弹层。点击播放条队列按钮，在按钮上方弹出（右对齐按钮；`placeAnchoredMenu` 的定位纯函数思路可复用/扩展，锚点语义=面板底边参考点，需处理窗口边界钳制：宽 ~360、高 ~480，四周留 ≥12px）。
2. 全屏半透明 barrier 点击关闭 + Esc 关闭（沿用 desktop_anchored_menu 的路由模式，可抽公共基类/工具，不要复制粘贴 barrier 逻辑）。
3. 面板内容：标题行（"播放队列 N 首" + 收起按钮）+ 可滚动列表；行 = 序号或"正在播放"指示（音量/音符动画图标可选，静态高亮即可）、歌名-歌手、时长；当前播放行高亮；点击行=切到该首（行为对齐现有 queue_sheet 的点击语义，读取同一 PlayerController API）；行 hover 高亮。不发明 queue_sheet 没有的功能（如清空队列），controller 没有的 API 不新增。
4. 桌面队列按钮改调新面板；移动端/car 的 queue_sheet 调用路径零改动。
5. 测试：面板打开/关闭/Esc、点击行触发 play、当前行高亮、边界钳制纯函数测试。

---

## Task 4: 系统集成（下载通知/窗口标题/最大化记忆/托盘项/开机自启/设置项门控）

**动机**（审计 P0/P1/P2）：下载完成无任何系统通知（download_service.dart:221）；窗口标题恒为"时音"不随歌曲；最大化状态不记忆（desktop_window.dart:268-276）；托盘无桌面歌词开关（desktop_tray.dart:87-92）；无 OS 开机自启；移动端专属设置项暴露在桌面（settings_page.dart:279-286,340-360）。

**要求**：
1. 引入 `local_notifier`（白名单）：桌面入口初始化；单曲下载完成时弹 Windows 通知"下载完成"+歌名，点击通知把主窗带到前台。批量下载按任务完成一次性通知（不要每曲一弹刷屏）。仅桌面路径。
2. 窗口标题随播放：监听 PlayerController 当前歌曲，`windowManager.setTitle('歌名 - 歌手 - 时音')`，无播放时回"时音"（格式抽纯函数+单测）。桌面歌词子窗的 setTitle 不受影响。
3. 最大化状态记忆：监听 onWindowMaximize/onWindowUnmaximize 持久化标记，启动恢复 bounds 后按标记还原最大化（desktop_window.dart 现有几何记忆机制内扩展）。
4. 托盘菜单加「桌面歌词」勾选项（跟随可见状态，点击切换显示/隐藏），沿用现有 setEnable/刷新模式。
5. 引入 `launch_at_startup`（白名单）：设置页「桌面」分组加「开机自启」开关（默认关），切换即 register/unregister；应用级自动播放开关保持独立。仅桌面显示。
6. 设置页桌面端隐藏移动专属项：「连接新音频设备自动播放」「后台打断机制」「增加听歌时长」三组按 `!isDesktopFormFactor` 门控（移动端原样）。
7. 测试：标题格式、静音记忆等纯函数；通知/自启经接口抽象后可测调用；设置项可见性 widget 测试（桌面隐藏、移动端显示）。

---

## Task 5: 桌面主题层（细滚动条/轻快转场/tooltip 统一）

**动机**（审计 P0/P1/P2）：桌面路由仍用移动端 Material Zoom 转场（无 pageTransitionsTheme，push 点 desktop_shell.dart:117,119、desktop_player_bar.dart:35）；全项目无 Scrollbar 主题定制，表格/页面全是默认 8px 宽灰条；tooltip waitDuration 三处不一致（300ms/500ms/0ms）。

**要求**：
1. AppTheme 按 `isDesktopFormFactor` 条件注入 `scrollbarTheme`：细条（~6px）、圆角、常态半透明浅色、hover 加粗加深、minimumSize 提高避免闪烁；移动端主题不变。
2. `pageTransitionsTheme` 桌面平台配轻快转场（fade，约 150-200ms；可用现成 builder 或自定义 PageTransitionsBuilder），移动端保持 Flutter 默认。
3. `tooltipTheme` 桌面统一 waitDuration（~500ms）为 token（design_tokens.dart 加常量）；playlist_detail_page.dart:3754、library_page.dart:939 等手动覆盖的桌面组件改用 token（这些是桌面专属组件，可改）；移动端不加 waitDuration。
4. 测试：AppTheme 在桌面/移动两种 form factor 下断言 scrollbarTheme/tooltip 差异、pageTransitions 差异（现有主题测试若存在则扩展）。

---

## Task 6: 列表 PC 化（搜索结果/已下载表格化 + 行语义统一 + 截断 tooltip）

**动机**（审计 P1/P2）：搜索结果仍是移动卡片式单击即播（search_page.dart:1361-1363，无时长列/无双击语义）；已下载页未表格化（downloaded_songs_page.dart:115-144）；首页歌曲行单击即播与表格"单击选中/双击播放"不一致（home_page.dart:1318-1320）；表格长歌名/专辑截断后悬停无完整提示（playlist_detail_page.dart:3541-3598）。DesktopSongTableRow 已被 rank/artist/playlist 三页复用但定义在 playlist_detail_page.dart:3354。

**要求**：
1. 把 `DesktopSongTableRow` 及其行内图标按钮抽到 `lib/ui/widgets/desktop_song_table_row.dart`（含现有全部能力：双击播放、右键 onSecondaryMore、hover 操作列、tooltip），playlist/rank/artist 三页改 import，行为零变化。
2. 搜索结果页桌面分支：复用该表格组件（列：歌曲/歌手/专辑/时长，取该行模型已有字段），双击播放、右键操作菜单接 `showSongActionSheet(anchor:)`；移动端/car 结果卡片不动。
3. 已下载页桌面分支：同样表格化（保留现有删除/下载态操作能力，接进行内操作或右键菜单），移动端不动。
4. 首页 `_HomeSongRow` 桌面分支：单击改为不触发播放（选中态可省略），双击播放；移动端/car 单击播放保持。
5. 表格中截断的歌名/专辑 Text 包 Tooltip（maxLines 截断处才显示完整提示）。
6. 测试：现有桌面表格测试迁移后全绿；搜索/已下载桌面分支渲染表格的 widget 测试；首页行桌面双击播放/单击不播的 widget 测试。

---

## Task 7: 首页与封面卡片桌面细节（去下拉刷新 + hover 播放按钮）

**动机**（审计 P1/P2）：首页保留移动端下拉刷新手势（home_page.dart:408-411 RefreshIndicator 全页生效）；封面/歌单卡片 hover 无播放按钮浮现（album_grid.dart:101-133、home_page.dart:1791-1878）。主流基准：PC 无下拉刷新，封面 hover 浮现播放按钮（Spotify/网易云）。

**要求**：
1. 首页桌面分支去掉 RefreshIndicator（滚动物理也改为桌面常规），在页头合适位置加刷新 IconButton（复用下拉刷新现有的数据重载逻辑），带 tooltip"刷新"；移动端/car 下拉刷新原样。
2. 封面卡片 hover 播放按钮：hover 时封面浮现半透明蒙层 + 圆形播放按钮（右下角或居中），点击=直接播放（不跳页），卡片本体单击行为不变。
3. **落地范围先调查再实施**：检查 PlayerController 是否已有"播放整个歌单/专辑/榜单"的现成 API（如首页 `_TopSongCard`、歌单卡当前单击行为背后调用了什么）。有现成 API 的卡片全部实现；需要新增网络流程才能播的（如专辑需先拉曲目列表）只在已有类似流程可复用时实现，否则跳过并在报告说明（宁缺毋滥，不加假按钮）。album_grid 为 PC 专属组件可直接改；home 卡片蒙层必须 `isDesktopFormFactor` 门控。
4. 测试：刷新按钮触发重载、RefreshIndicator 仅移动端存在；hover 蒙层出现/点击播放（对已实现卡片）；移动端无蒙层。

---

## 执行顺序

Task 1 → 2 → 3 → 4 → 5 → 6 → 7（2/3 同文件串行；1 与全局键盘相关先行）。每任务实现子代理 + 审查子代理；全部完成后整分支终审（base = 8e4abfb）+ analyze + 全量测试。

**本轮明确不做（记录为后续建议）**：SMTC 系统媒体集成（任务栏/媒体键，需原生大改）、搜索框锚定联想下拉面板（search_page 三态共用，重构风险大，建议单独一轮）、表格 ↑↓ 键盘行导航、列头点击排序、迷你模式、歌词文本可选中、桌面歌词行距/取色器。
