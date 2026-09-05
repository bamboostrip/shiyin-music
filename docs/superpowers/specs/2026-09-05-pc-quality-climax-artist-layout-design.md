# PC音质快捷切换、未播试听高潮修复与歌手/歌单页动态全量加载设计规约

## 1. 概述与背景

本规约旨在解决用户在 PC 桌面端及多端使用过程中发现的体验痛点：
1. **未播放试听高潮回弹 Bug**：冷启动或刚进入软件未开始播放时，进入播放详情页点击“试听高潮”，进度条跳转到高潮位置但瞬间弹回 0 秒重头播放；
2. **PC 端音质切换繁琐**：此前 PC 端切换当前播放音质需进入设置页或播放页右上角三级菜单，缺乏像主流 PC 音乐软件（QQ 音乐、网易云音乐）那样直接在底部播放条或播放页显眼处的常驻音质标签；
3. **歌手详情页专辑遮挡歌曲**：PC 端由于把 20 张专辑排在上方大网格中，将核心的歌曲列表挤到屏幕数屏之下；且初始仅加载 30 首，导致标头只显示“30 首热门单曲”，且不滚动到底部就不加载后续歌曲；
4. **歌手页与歌单页动态全量预加载**：长歌单与歌手全部歌曲需要具备后台静默累进预加载机制，动态刷新总数，保障多端列表浏览与搜索的流畅度。

---

## 2. 模块详细设计

### 2.1 修复未播放时“试听高潮”弹回 0 秒 Bug

#### 根因分析
- 在 `lib/controllers/player_controller.dart` 中，`playClimaxPreview()` 获取到高潮起始时间戳后，先执行 `await seek(climax.startTime)`；
- 随后因 `!audioPlayer.playing` 调用 `await togglePlay()`；
- 若底层 `AudioPlayer` 处于 `ProcessingState.idle`（冷启动恢复状态），`togglePlay` 转入 `playSong(song)`；
- `playSong` 初始化新音频源时，未指定起始偏移量，默认从 0 开始播放，且在方法开头将 `_climaxEndTime` 和 `climax` 清空，导致进度条跳回 0 秒。

#### 改造实现
1. `PlayerController.playSong` 支持新参数：
   ```dart
   Future<void> playSong(
     Song song, {
     List<Song>? queue,
     bool isRetry = false,
     Duration? initialPosition,
     bool preserveClimax = false,
   })
   ```
2. 当 `preserveClimax == false` 时才清空 `_climaxEndTime` 与 `climax`；
3. 在音频源加载成功后（`_audioHandler.loadSong` 后），若 `initialPosition != null`，先 `await seek(initialPosition)` 再 `await _audioHandler.play()`；
4. 在 `playClimaxPreview()` 中：
   ```dart
   if (audioPlayer.processingState == ProcessingState.idle) {
     await playSong(
       song,
       queue: queue,
       initialPosition: climax.startTime,
       preserveClimax: true,
     );
   } else {
     await seek(climax.startTime);
     if (!audioPlayer.playing) {
       await togglePlay();
     }
   }
   _climaxEndTime = climax.endTime;
   ```

---

### 2.2 PC 端快捷音质切换（双入口常驻）

#### 入口 1：底部播放栏 `DesktopPlayerBar`
- 在 `lib/ui/desktop/desktop_player_bar.dart` 的进度条右侧与音量条左侧之间新增 `_AudioQualityBadge(player: player)`：
  - 展示当前音质 Badge（如 `无损` / `高品` / `标准`），辅以微边框与小字号（11px）；
  - 悬停（Hover）背景微亮，显示手型光标与 Tooltip `切换音质 (${player.audioQuality.label})`；
  - 单击直接调用 `showAudioQualitySheet(...)`，在 PC 上弹出居中 Desktop Dialog，选择后自动调用 `player.setAudioQuality(quality, reloadCurrent: true)`。

#### 入口 2：大屏播放页 `PlayerPage`
- 在 `lib/ui/pages/player_page.dart` 歌曲信息区（标题与歌手下方）及快捷控制区显眼位置展示当前音质胶囊标签；
- 点击同样呼出音质选择弹窗，即点即切。

---

### 2.3 歌手详情页 `ArtistDetailPage` 结构重构（Tab 标签页切换）

#### 视图层级结构
1. **SliverAppBar 保持置顶**：保留歌手头像、姓名与“播放热门单曲”Hero 区域；
2. **SliverPersistentHeader 粘性 Tab 栏**：
   - 两个 Tab：`精选单曲` 和 `所有专辑`；
   - 默认选中 `精选单曲`；
3. **内容区域条件渲染**：
   - 当激活 `精选单曲`：直接渲染热门单曲列表（PC 为 `DesktopSongTableRow` 表格，移动端为 `SongListTile`），视线无任何遮挡；
   - 当激活 `所有专辑`：PC 渲染响应式 6 列专辑网格 `AlbumSliverGridSection`，移动端渲染卡片网格。

#### 动态总数显示
- 歌手头部歌曲统计文本调整为动态：
  - 若在静默加载中：`已加载 ${_songs.length} 首热门单曲 · ${_albums.length} 张专辑`；
  - 若已全量加载完毕：`共 ${_songs.length} 首热门单曲 · ${_albums.length} 张专辑`。

---

### 2.4 歌手页与歌单页动态静默全量预加载

#### 歌手详情页（`ArtistDetailPage`）
- 首屏快速加载第 1 页（30 首）并立即可见；
- 随后开启后台管道 `_startProgressiveLoading()`：
  - 循环请求 `page = 2, 3, ...`，每页间隔 200ms 防抖避免突发网络洪峰；
  - 每次拿到新数据后 `_songs.addAll(newSongs)` 并触发局部刷新；
  - 当拿到数据为空或不满页时结束，标记 `_allSongsLoaded = true`；
  - 页面销毁时自动取消在途加载。

#### 歌单详情页（`PlaylistDetailPage`）
- 在 `_loadInitial()` 成功拿到第 1 页并渲染后，若 `_hasMore == true` 且 `!_allSongsLoaded`，自动在 `WidgetsBinding.instance.addPostFrameCallback` 中触发 `_loadAllSongs(silent: true)`；
- 无论是 PC 端还是移动端，歌单后续歌曲在后台平滑补充，保证长歌单滚动顺畅，搜索能够即时覆盖全歌单曲目。

---

## 3. 测试与验证方案

1. **Bug 1 单元与组件测试**：
   - 编写 `test/controllers/player_climax_idle_test.dart`：模拟冷启动 `idle` 状态调用 `playClimaxPreview()`，验证 `playSong` 接收到 `initialPosition`，播放位置直接设为高潮起始点，且 `_climaxEndTime` 保持有效。
2. **PC 音质切换测试**：
   - 更新 `test/ui/desktop/desktop_player_bar_test.dart`：验证底部播放栏音质徽标存在，显示当前音质文字，点击触发音质弹窗。
3. **歌手页 Tab 与动态加载测试**：
   - 新增 `test/ui/pages/artist_detail_tab_test.dart`：验证进入歌手页默认展示单曲列表，切换 Tab 显示专辑网格；验证多页动态静默拉取。
4. **全量回归与静态分析**：
   - 运行全量 `flutter test`（320+ 测试）；
   - 运行 `flutter analyze` 确保 0 errors / 0 warnings。
