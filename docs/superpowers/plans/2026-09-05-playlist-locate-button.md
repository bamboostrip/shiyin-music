# 歌单定位交互改造（用户反馈）

来源：用户反馈——播放歌单中的歌后再次进入该歌单会自动滚动定位，体验不佳。改为手动定位按钮。BASE = e87018a。

## Global Constraints

- **双端同步生效**：本任务是用户明确要求移动端 + PC 端同时改变的行为（取消自动定位），不属于"门控"场景；除按钮样式可按端微调外，行为逻辑两端一致。
- 其余页面（排行榜/歌手/歌词页等）不改动（勘探确认定位逻辑全库仅歌单页一处，无共享）。
- 组件小而内聚：悬浮按钮抽独立 widget；playlist_detail_page.dart 净增量尽量小（该文件刚从 3925 行减到 ~3300 行）。
- 验证门槛：`flutter analyze` 0 issues + 新增测试 + 全量 `flutter test`（基线 256）+ 提交。

## Task 1: 进入歌单不自动定位，改为右下角手动定位按钮

**现状**（已勘探，file:line 为提交 e87018a 时的位置，可能有少量偏移，按符号定位）：
- 自动定位：`_loadInitial()` 完成后（约 :554-556）`unawaited(_autoLocateCurrentSong())`，仅进页一次（`_autoLocateDone` :105-108）。
- 找 index：`_filteredSongs.indexWhere(hash==current.hash)`（:658）；未加载到且 `_queueMatchesThisPlaylist()`（:683-687，已加载歌曲全在播放队列里）时逐页 `_loadMore()` 最多 24 页（:659-670）。
- 滚动：`_scrollToSong()`（:691-764）估算 offset（PC rowExtent 44 / 移动 70，:706）+ jumpTo + GlobalKey `Scrollable.ensureVisible(alignment:0.25, 220ms)` 校正，双端兼容；`_locateRowKey` 挂目标行（:1619/:1691），完事置 null。
- 页面结构：Stack（:1351）> CustomScrollView；`_scrollController` 已存在；多选底栏先例 `Positioned(left:16,right:16,bottom: bottomInset>0? bottomInset+10:16)`（:1745-1750）；列表底部留白 `_isSelecting ? 110 : 16`（:1611）。
- 无既有测试覆盖此页。

**要求**：
1. **取消自动定位（双端）**：移除 `_loadInitial` 里的 `_autoLocateCurrentSong()` 调用与 `_autoLocateDone` 一次性开关语义；`_scrollToSong` 及找 index（含队列匹配时限量加载页数的既有逻辑）保留给按钮用。
2. **右下角定位按钮**：
   - 独立组件（如 `lib/ui/widgets/locate_current_song_button.dart`）：圆形（CircleBorder 先例），约 44-48px，配色用主题 token（surfaceContainerHigh 系 + 阴影），图标建议 `Icons.my_location`（库内无冲突），带 Tooltip（桌面 hover）/Semantics 标签「定位到当前播放」。
   - 位置：歌单页 Stack 内 `Positioned(right: 16~24, bottom: ...)`，bottom 参照多选底栏的 bottomInset 处理；**多选模式下隐藏**（避免与底栏重叠）。
   - 点击：复用既有找 index + 限量加载 + `_scrollToSong` 流程（`_isLocating` 防重入）；当前行切歌后按钮跟随新歌（监听或 AnimatedBuilder player）。
3. **显示条件**：`当前有播放歌曲 && (该歌曲已在已加载歌曲列表中 || _queueMatchesThisPlaylist())`。解释：歌曲已在本歌单（含深页场景用队列匹配做代理）才显示；播放别的歌单/搜索来源的歌且不在本列表 → 不显示。切歌/列表加载变化时用 ValueListenable/AnimatedBuilder 响应式刷新显隐，不 setState 整页。
4. **测试**（新建测试文件，参考 test/ui/pages/desktop_song_table_test.dart 的 pump 模式）：
   - 进入含播放歌曲的歌单**不**自动滚动（offset 保持顶部）。
   - 无播放/播放歌曲不属于本歌单 → 无按钮；属于 → 有按钮。
   - 点击按钮滚动到目标行（pumpAndSettle 后断言行可见）。
   - 多选模式按钮隐藏。
   - 页面加载/仓库依赖如难以注入 fake，按现有测试基建判断，能测则测，测不了的说明原因。
5. `flutter analyze` 0 issues；全量 `flutter test` 通过；提交 `feat(playlist): 进入歌单不再自动定位，改为右下角定位按钮（移动/PC）`。
