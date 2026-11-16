# 车载蓝牙歌词（issue #22）二次排查

> 状态：**诊断到位、修复未验证**。分支 `fix/issue-22-car-lyrics-mediasession` 只做了
> 「把更完整/更干净的内容发出去」+「下一次排查有日志可看」，车机是否因此滚动仍未知，
> issue 不要按「已修复」关闭（见 §3 与 §5）。
> 相关：v3.0.19 首次修复 `2e0d306`（整首 LRC + 行内 position 心跳，**只补了广播通道**）。

## 1. 车主复测反馈（2026-11-13，v3.0.19）

- 车机：Flyme Auto 2.3，机型 `se1000_p171_slave_car`（应用直接装在同一台车机上，
  `isAutomotiveDevice=true`，日志首行「通知渠道定向：channelId=shiyin_music.playback_car」）。
- 症状：升级到含 `2e0d306` 的 v3.0.19 后，「蓝牙歌词依旧有问题」。
- 附带的是**应用内诊断日志**（2011 行），不是之前要求的 `adb logcat -s BluetoothLyrics`。

## 2. 关键线索：乱码是 JSON 尾巴，不是编码问题

首帖实拍截图里，车机卡片大字号一行是：

```
我们最爱的歌"}
```

- `我们最爱的歌` 是当前歌词行，副标题 `你懂得-小沈阳 / 沈春阳` 是 `歌名 - 歌手`。
- 末尾多出的 `"}` 是 **JSON 结构字符**，全仓库没有任何代码拼出这个后缀
  （`grep '"}'` lib/ android/ 均无命中）。最省事的解释是消费方对 `lyricInfo`
  JSON 做了非规范解析，例如 `json.substringAfter("\"lyric\":\"")`，于是把 JSON
  收尾的 `"}` 一起显示出来。

**推断（不是结论）**：Flyme Auto 的歌词卡片读的是 MediaSession metadata 的
`lyricInfo`，而不是 `com.android.music.metachanged` 广播的 extras。推论是
v3.0.19（`2e0d306`）只改广播 extras，所以对这台车机没有效果。

**这个推断有一个没补上的洞**：v3.0.15 起 `lyric` 与 `full_lrc` 由同一处产出、
同生同灭（`buildLyricMediaExtras` 的 `line` / `fullLrc` 同源），代码里造不出
「有当前行、没有整首 LRC」的 JSON —— 也就是说，如果车机是「整段字符串原样显示」，
它现在看到的应该是一整串带 `[mm:ss.xx]` 和**转义 `\n`** 的文本，而不是截图里
干净的一行。于是只剩两种可能，两者结论不同：

| 解释 | 车机行为 | 发送端能否修 |
| --- | --- | --- |
| T1 单行槽 + 整段显示 | 把取到的字符串塞进单行控件，截图那一行是它自己的截断/滚动位置 | 不能。滚动需要车机侧支持多行/时间轴 |
| T2 按时间轴选行 | 自己解析 LRC 时间标签挑当前行，`"}` 只挂在最后一行上（截图恰好停在末句） | 有可能，但依赖它读 PlaybackState 的位置 |

**已排除的三个猜测**（都查过代码/依赖源码）：

1. 「位置没下发」不是主因：MediaSession 的 `PlaybackState` 一直带
   `updatePosition` + `updateTime` + `speed`，消费方可自行插值
   （`just_audio` 的 `positionStream` 是本地插值，不是平台事件，所以不能靠
   "每次 position tick 都重发 playbackState" 这种假设自证）。
2. 「音频编码/UTF-8 乱码」不成立：`"}` 是可见的结构字符，不是解码失败。
3. 「v3.0.19 修复无效」是确定的：`2e0d306` 的改动全在广播通道。

## 3. 核实边界：哪些已证明、哪些没有

**已证明（代码/依赖源码/单测）**

- v3.0.19（`2e0d306`）改的是广播 extras，与 MediaSession 通道无关。
- `mediaItem.add()` 在 audio_service 里会 `setMetadata()` + `updateNotification()`
  （`audio_service-0.18.19/.../AudioService.java:786-807`）——**每次 add 都重建一次
  通知**。所以「行内每秒重推进度」这种方案对弱车机是有代价的，本次**没有**采用。
- MediaItem extras 支持 int/bool（`AudioService.java:149-162` 映射为 Long），
  新增字段不会在原生侧丢值或抛错。
- 单测实测：`lyricInfo` 里 `lyric` 挪到末位后，傻瓜解析只多出固定 `"}`；
  规范解析器取值不受影响（JSON 字段顺序无语义）。

**未证明（不要再声称「已修复」）**

- 车机到底读哪一个 key、能否渲染多行、能不能滚动 —— 一条都没验证过。
  本次只做到「把更完整、更干净的内容发出去」+「让下一次排查有日志可看」。
- 因此本分支是**缩小问题范围**，不是**确认修复**；issue 不要按「已修复」关闭。

## 4. 本次改动（分支 `fix/issue-22-car-lyrics-mediasession`）

| 位置 | 改动 | 目的 |
| --- | --- | --- |
| `lib/services/music_audio_handler.dart` | 行推送的 extras 增加 `position` / `duration` / `playing` 与纯文本 `lyrics`；`lyricInfo` 的 `lyric` 挪到末位；新增 `[LyricMeta]` 诊断日志（每首歌最多两行） | 补齐「只在 extras 里找位置」的消费方所需字段（`PlaybackState` 那条路本来就有）；`lyric` 末位把傻瓜解析的垃圾固定成 `"}`；日志能证明这条通道真的发了什么 |
| `lib/services/lrc_formatter.dart` | 新增 `toPlainText`（剥时间标签，保留间奏空行以维持行序） | 车机只认纯文本时的降级内容 |
| `lib/services/bluetooth_lyrics_service.dart` | 捕获原生返回值并 `debugPrint`（每首歌最多两条成功日志、失败即打；截断不切断代理对） | 导出日志终于能看出广播通道是否活着；此前整段静默，车主只能跑 `adb logcat` |
| `android/.../MainActivity.kt` | 广播 extras 增加 `lyrics` / `plainLyric`，`Log.d` 带 `plainLyricLen` | 第三方车机歌词 App 也能吃纯文本 |

刻意**没有**做的事（复查后撤回）：

- ~~MediaSession 行内 1s 进度心跳~~：收益未证实，代价却是车机上每秒重建一次通知，
  与本仓库「不随位置 tick 重建媒体通知/不重复拼歌词」的既有约束冲突。消费方若要
  连续进度，应当读 `PlaybackState`（本仓库每条 `playbackEventStream` 都会重广播
  一次，含 `updatePosition`/`updateTime`，可自行插值）。
- 不改 `MediaItem.id` 之类「骗消费方刷新」的偏方：会破坏通知/队列身份，风险高于收益。

## 5. 决定性实验（下一步只需要这一条信息）

**这台车的卡片上，其他 App（网易云 / QQ 音乐）的歌词能滚动吗？**

- 能 → 车机确实支持第三方滚动歌词，只是字段没对上。请在车机上抓
  `adb shell dumpsys media_session`（或 `dumpsys media_session | grep -A40 网易云`）
  里那条会话的 `metadata:` 段，看它用了哪几个 extras key，我们按同名对齐。
- 不能 → 卡片只支持单行歌词，第三方滚动在这台车上无解；应改用
  「手环 / AVRCP 歌词同步」把当前歌词写成媒体标题，预期降到「逐句更新」。

无论哪种，都请附带新版本导出的诊断日志，正常应能看到
`[BluetoothLyrics] 广播成功：… fullLrcLen=…` 与 `[LyricMeta] 系统歌词元数据下发: … keys=[…]`。

## 6. 已知不可控项

`"}` 这类尾巴来自车机端的解析实现，发送端无法消除（改 JSON 字段顺序只会把尾巴
换成另一段结构字符，本次只是把它缩短成固定 `"}`）。彻底解决要靠车机侧修解析，
或改用系统歌词插件（Lyricon / SuperLyric / LyricProvider）。
