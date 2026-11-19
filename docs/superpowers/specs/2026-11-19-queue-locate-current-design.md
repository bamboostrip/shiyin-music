# 播放队列「定位到当前歌曲」设计（issue #28）

日期：2026-11-19　|　分支：`feat/queue-locate-current`　|　来源：[issue #28](https://github.com/bamboostrip/shiyin-music/issues/28)

## 背景与问题

用户反馈（hisdc，2026-11-18）：播放队列几百首歌（截图 439 首），队列面板打开时永远停在列表顶部，正在播放的歌曲虽有高亮（primary 色底 + 均衡器图标）但要手动翻很久才能找到。

现状盘点（三个队列 UI 行为不一致）：

| 队列 UI | 文件 | 现状 |
|---|---|---|
| 移动端底部面板（issue 截图，播放页队列按钮唤起） | `lib/ui/widgets/queue_sheet.dart` | 打开停在顶部，无定位 |
| PC 锚定面板（桌面播放栏队列按钮唤起） | `lib/ui/widgets/desktop_queue_panel.dart` | ✅ 打开自动滚到正在播放行（居中） |
| 车机内联队列面板 | `lib/ui/widgets/car_left_player_panel.dart` `_showQueue` | 打开停在顶部，无定位 |

另：歌单详情页（`playlist_detail_page.dart`）已有手动定位 FAB 模式（`LocateCurrentSongButton` + 滚动校正），可借鉴交互语义与图标。

## 需求决策（已与维护者确认）

1. **交互方式**：打开面板自动滚到正在播放行（对齐 PC 面板）+ 头部定位按钮（手动翻走后一键找回）。
2. **覆盖范围**：移动端 `queue_sheet.dart` + 车机内联队列；PC 已有，不动。
3. **代码结构**：抽共享定位辅助类，两处接入；车机行 UI 不动（保留无删除按钮的驾驶简化）。
4. **切歌跟随**：面板打开期间自动切歌**不跟随滚动**（与 PC 面板一致，不打断用户浏览），当前行高亮/key 跟随，点按钮找回。

## 交互行为

- **打开面板**：首帧前按固定行步长估算 `initialScrollOffset`，首帧后 `Scrollable.ensureVisible` 精确校正到居中。全程 jump 无滚动动画（PC 面板同款策略），且发生在 sheet 入场动画期间/之前，用户无感知。
- **头部定位按钮**：头部「清空」左侧新增 `IconButton`（`Icons.my_location_rounded`，tooltip/语义标签「定位到正在播放」，与歌单详情页 FAB 同图标同语义）。点击平滑滚动（~250ms）回当前行居中。当前歌不在队列时禁用（防御，理论不发生）。
- **定位目标**：`index == activeIndex`（第一个匹配行）的行居中显示。
- 移动端与车机行为一致。

## 组件结构

### 新增 `lib/ui/widgets/queue_locate.dart` — `QueueLocateController`

纯滚动职责，不依赖 PlayerController：

```dart
QueueLocateController({required double rowStride, int? initialIndex})
  → ScrollController controller        // initialScrollOffset = max(0, index * stride)
  → void correctAfterFirstFrame(GlobalKey rowKey)  // ensureVisible 居中、无动画（字体缩放兜底）
  → Future<void> locate(GlobalKey rowKey)          // ensureVisible 居中 + 平滑动画
  → void dispose()
```

- 队列 sheet 均为 `shrinkWrap: true` 全量 build，active 行 context 首帧必在，无需歌单页那套懒加载探测。
- 行步长参数化：移动端 `QueueTile` 56 + 分隔 2 = 58；车机两行 `ListTile`（title+subtitle）72 + 分隔 2 = 74。估算只影响首帧落点，post-frame 校正保证精确，行高误差不致错。

### `queue_sheet.dart` 改造

- `showQueueSheet` 函数签名不变（`player_page.dart` 调用点不动）。
- builder 内容抽成 `_QueueSheetBody`（StatefulWidget）：
  - initState：算 `activeIndex = queue.indexWhere(isSameSong(current, s))`；建 locator；post-frame 校正；
  - 头部 Row 的 Spacer 后、「清空」前加定位按钮（enabled = activeIndex >= 0）；
  - ListView 挂 `_locate.controller`；`itemBuilder` 中 `index == activeIndex` 的行外包 `KeyedSubtree(key: _activeRowKey, ...)`。

### 车机 `car_left_player_panel.dart` `_showQueue` 改造

- 同样抽 body 为 StatefulWidget，接入同一 locator；行 UI（ListTile、无删除按钮）不动。

## 边界与细节

- **重复添加同一首歌**（同 hash 多行，现状多行都高亮）：GlobalKey 只挂 `index == activeIndex` 的第一个匹配行，避免同 key 多挂崩溃。
- **面板内删非当前行**（`removeFromQueue` → `replaceQueue` 不关面板）：行号移位，key 在 active 行上随 rebuild 跟随，无需特殊处理。
- **当前歌是第一首**：偏移 0，无感知；按钮照常显示（一致性）。
- **清空按钮**（`clearQueue`）与点到当前歌（pop）都会关面板，无残留状态问题。

## 测试计划

新建 `test/ui/widgets/queue_sheet_locate_test.dart`（PlayerController 桩写法参考 `desktop_queue_panel_test.dart`）：

1. 打开面板自动滚到当前行（offset > 0 / 当前行可视）；
2. 定位按钮存在、tooltip/语义正确；当前歌不在队列时禁用；
3. 手动滚走后点按钮回到当前行；
4. 重复歌曲行（同 hash 两行）不因 GlobalKey 冲突崩溃。

## 不做的事（YAGNI）

- 不改 PC `desktop_queue_panel.dart`（已有打开定位，无按钮诉求未提出）。
- 不做切歌跟随滚动。
- 不统一车机与移动端队列行 UI（保留驾驶简化）。
- 不动 `shrinkWrap` 全量 build 的性能现状（另题）。
