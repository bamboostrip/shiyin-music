# 歌词进度调整设计规范 (Lyric Progress Offset)

## 1. 概述与背景

酷狗/第三方曲库返回的歌词偶有整体时间偏差（提前或延后零点几秒），表现为"字幕对不上人声"。
主流播放器（酷狗移动端「调整歌词进度」、QQ 音乐 PC「时间偏移」）都提供用户手动微调能力。

本设计为时音补齐该能力，覆盖三个形态：

1. 移动端播放页（入口在「详情」弹层）；
2. PC 客户端（桌面分栏播放页）；
3. 桌面歌词悬浮窗（PC 子窗 / 移动端悬浮窗）——**播放页调整后必须同步生效**。

## 2. 语义定义

- 状态：`PlayerController.lyricOffset`（`Duration`，正 = **歌词提前**，负 = **歌词延后**）。
- 歌词定位统一使用派生位置：

  ```dart
  Duration get lyricPosition => smoothPosition + lyricOffset; // 夹取到 [0, duration]
  ```

  偏移为 +0.5s 时，真实进度 10.0s 处即显示 10.5s 那一句 —— 歌词"提前"了 0.5s，
  与 QQ 音乐 PC 的「歌词提前 0.5 秒」语义一致。
- 卡拉OK逐字进度同源：`PlayerLyricProgressLogic.forLine` 与
  `activeLyricIndex` 必须吃到**同一个** `lyricPosition`，否则会出现
  "换行提前、扫字延后"的割裂观感。
- 偏移**只作用于歌词**：进度条、拖动 seek、播放统计仍走真实 `smoothPosition`。
- 步进：0.5 秒；范围夹取 ±20 秒（超出无实际意义且会整段错位）。

## 3. 持久化

- **按歌曲**保存（同一首歌下次自动带上偏移，符合"某首歌歌词有错"的实际场景）。
- 键：`settings.lyric_offset_per_song`，值为 JSON `{"<song.hash>": <毫秒>}`；
  容量上限 200 条，超限按插入序淘汰最旧（更新即置为最新）。
- 偏移为 0（重置）时直接删除该条，不留 `0` 值。
- 恢复时机：`_restoreSettings()` 读取映射，并对当前歌曲重新装载（`_restoreSettings`
  与 `_restorePlaybackState` 都是构造函数内 `unawaited` 发起，存在竞态，故恢复完
  映射后必须再对齐一次当前歌）。
- **合并规则（内存优先）**：恢复映射时不清空内存镜像，只 `putIfAbsent` 补上磁盘里
  的新条目；恢复末尾也只在"映射里确有此歌"时才重新装载。否则用户在启动后几百毫秒
  内的调整（此时 `_restoreSettings` 可能还没跑完）会被恢复流程抹回 0 —— 这条真的
  踩到过，回归用例见 `test/controllers/player_lyric_offset_test.dart` 的"重启后恢复"
  与"悬浮窗进度指令"两条。
- 切歌：`playSong` 落定 `currentSong` 后立刻装载该歌偏移。

## 4. 同步链路（为什么只需改控制器）

桌面歌词悬浮窗只接收主窗推送的"当前句/下一句文本 + 逐字进度"，来源均为
`activeLyricIndex` / `lyricPosition`。因此偏移落在控制器后，以下链路自动同步：

- 桌面歌词悬浮窗：`_syncDesktopLyrics()`（换行文本）与 `_syncDesktopKaraokeProgress()`（逐字进度）；
- 超级歌词（车机）、蓝牙歌词广播：均按 `activeLyricIndex` 推送；
- 播放页歌词列表、海报页歌词预览、PC 分栏歌词面板：统一改用 `lyricPosition`。

偏移变更时（`_notifyLyricOffsetChanged`）需要：重置各路的"上一句"缓存
（`_lastDesktopLyricIndex` / `_lastSuperLyricIndex` / `_lastBluetoothLyricIndex`），
主动补推一次桌面歌词与逐字进度，并 `notifyListeners()` 让 UI 重排。

## 5. 交互入口与视觉

### 5.1 共享控件 `LyricOffsetControl`

三键（`− 0.5秒` / `↺ 重置` / `+ 0.5秒`）+ 状态文案（"歌词提前 0.5 秒"/"无偏移"），
视觉对齐酷狗「调整歌词进度」面板：圆角方键、图标居中、注释文字在下。
键支持长按连调（500ms 后每 130ms 一步），20 秒量级不必点四十下。

### 5.2 移动端：入口放「详情」弹层（不是常用操作）

- **主入口**：播放页「更多/详情」弹层（`showPlayerMoreSheet`）里的「歌词进度」宫格项，
  与倍速/音质/高潮/定时同排；副标题直接显示当前偏移（如"歌词提前 0.5 秒"，未调整时不显示）。
  点击后关闭详情弹层并弹出「调整歌词进度」底部弹层。
- **快捷入口**：长按歌词行同样弹出该弹层（主流 App 习惯，不占界面）。
- 不在歌词页底栏放常驻按键：低频修正操作不该和"译/音/字号"抢位置。

### 5.3 PC 客户端

- 封面左下角开关列新增 `调` 方形开关（始终可见）→ 按钮旁锚定弹层；
- 歌词列表**右键** → 指针位置锚定弹层（对齐 QQ 音乐 PC 右键菜单「时间偏移」）；
- 详情弹层里的「歌词进度」在桌面形态同样可用，落在同一锚点（无需再走底部弹层）；
- 桌面歌词悬浮窗快捷菜单新增「歌词进度」行（`−` / 重置 / `+`），经既有
  `controlPlayback` 通道下发指令到主窗（主窗是偏移的唯一真相源）。

## 6. 涉及文件

| 文件 | 改动 |
|------|------|
| `lib/controllers/player_controller.dart` | 偏移字段/键/`lyricPosition`/`activeLyricIndex` |
| `lib/controllers/player_controller.lyrics.dart` | 装载/调整/重置/落盘/变更广播 |
| `lib/controllers/player_controller.desktop.dart` | 逐字进度改用 `lyricPosition`、悬浮窗播控扩展偏移指令 |
| `lib/controllers/player_controller.playback.dart` | 切歌装载偏移 |
| `lib/controllers/player_controller.settings.dart` | 启动恢复偏移映射 |
| `lib/controllers/player_logic.dart` | `PlayerLyricOffsetLogic`（夹取/文案） |
| `lib/ui/player/lyric_offset_sheet.dart`（新增） | 共享面板 + 移动端弹层 + PC 锚定弹层 |
| `lib/ui/player/player_top_bar.dart` | 详情弹层「歌词进度」宫格入口 |
| `lib/ui/player/mobile_lyric_list.dart` | `lyricPosition`、长按歌词入口 |
| `lib/ui/player/desktop_lyric_list.dart` | `lyricPosition`、右键菜单 |
| `lib/ui/player/landscape_player.dart` | `调` 开关 + 锚定弹层、面板进度源 |
| `lib/ui/player/lyric_views.dart` | 长按/右键透传（底栏不动） |
| `lib/ui/player/poster_player.dart` | 预览进度源 |
| `lib/ui/desktop/lyrics_overlay_window.dart` | 悬浮窗快捷菜单「歌词进度」行 |
| `lib/services/windows_desktop_lyrics_bridge.dart` | 菜单面板高度常量随新增行调整 |
| `test/controllers/player_lyric_offset_test.dart`（新增） | 语义/夹取/逐曲持久化/竞态/桌面歌词同步 |
| `test/ui/player/lyric_offset_sheet_test.dart`（新增） | 弹层三键、PC 锚定面板、右键与开关列入口 |
| `test/ui/desktop/desktop_lyrics_test.dart` | 悬浮窗尺寸与光标坐标改由常量推导 |
| `test/ui/player/*`（13 个 fake 控制器） | 补齐新增接口成员 |

## 7. 验证

- 单测：偏移夹取/按歌隔离/落盘与恢复/重置删除条目；偏移 ±0.5s 时
  `activeLyricIndex` 提前或延后一行；`lyricPosition` 命中同一行。
- Widget 测试：移动端弹层三键可用、状态文案随偏移更新；PC 锚定弹层可打开并生效；
  封面开关列 `调` 键与歌词右键都能唤起。
- 回归：`test/ui/player/**`、`test/controllers/**`、`test/ui/desktop/**` 全绿；
  `flutter analyze` 无新增问题。
- 真机/PC 手测：详情弹层调整后，桌面歌词换行与逐字进度同步变化；重启后仍生效。
