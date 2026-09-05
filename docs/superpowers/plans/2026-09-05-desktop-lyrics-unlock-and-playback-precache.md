# 桌面歌词一键解锁与多端播放缓存/预缓存实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 
1. 增强桌面播放栏歌词按钮状态联动，锁定态展示带锁图标，单击一键解锁、右键弹出快捷菜单；
2. 优化本地播放缓存离线降级（断网自动读取任意音质本地缓存）；
3. 实现多端智能下一首预缓存（播放到 70% 自动预载下一首音频+歌词，完美支持随机播放）。

**Architecture:**
- **UI 交互层**：`DesktopPlayerBar` 联动 `player.desktopLyricsLocked`，按钮锁定态切换为 `Icons.lock_rounded`，单点直调 `unlockDesktopLyrics()`，右键弹出锚定菜单；
- **缓存离线降级层**：`DownloadController` 补充 `localPathForAnyQuality`，断网或无匹配音质时跨音质降级提取本地缓存；
- **智能预缓存流水线**：`PlayerController` 监听播放进度（>= 70% 且 >= 15s），按当前播放模式（含 ShuffleQueue）获取准确下一首，异步并发预拉取歌词与音频并落盘到 PlayCache。

**Tech Stack:** Flutter / Dart, Provider / ChangeNotifier, JustAudio, DesktopMultiWindow, WindowManager.

---

## Global Constraints
- 必须保持全平台架构兼容：预缓存与离线缓存逻辑为 Dart 全平台通用逻辑，不可引入桌面独有依赖；
- 桌面歌词交互增强严格通过 `isDesktopFormFactor` / `isDesktopLyricsSupported` 门控；
- 预缓存必须具有防刷防护（每首歌只触发一次、切歌立即重置标志位、播放未达阈值不跑流量）；
- 每次修改后 `flutter analyze` 必须为 0 issues，相关测试全部绿灯。

---

## File Structure

```
lib/
├── controllers/
│   ├── download_controller.dart        # [MODIFY] 增加 localPathForAnyQuality 离线降级查询
│   └── player_controller.dart          # [MODIFY] 增加解锁入口、离线降级播放与下一首智能预缓存触发逻辑
└── ui/
    └── desktop/
        └── desktop_player_bar.dart     # [MODIFY] 歌词按钮联动锁定态（带锁图标 + 单击一键解锁 + 右键菜单）
test/
├── controllers/
│   └── player_precache_test.dart       # [NEW] 预缓存与离线缓存降级单元测试
└── ui/
    └── desktop/
        └── desktop_player_bar_test.dart# [MODIFY] 增加歌词按钮锁定图标与点击一键解锁用例
```

---

## Tasks

### Task 1: 底部播放栏桌面歌词按钮锁定联动与一键解锁

**Files:**
- Modify: `lib/controllers/player_controller.dart`
- Modify: `lib/ui/desktop/desktop_player_bar.dart`
- Test: `test/ui/desktop/desktop_player_bar_test.dart`

**Interfaces:**
- `PlayerController.desktopLyricsLocked -> bool`: 返回当前桌面歌词是否处于锁定状态；
- `PlayerController.unlockDesktopLyrics() -> Future<void>`: 将桌面歌词解锁并通知子窗与主窗；
- `PlayerController.setDesktopLyricsLocked(bool) -> Future<void>`: 切换锁定状态；
- `DesktopPlayerBar`: 歌词按钮根据 `desktopLyricsEnabled` 与 `desktopLyricsLocked` 动态切换样式与操作。

- [ ] **Step 1: Write failing widget test for locked lyrics button**
  在 `test/ui/desktop/desktop_player_bar_test.dart` 增加测试：
  - 当 `desktopLyricsEnabled == true && desktopLyricsLocked == true` 时，按钮渲染为带锁图标（`Icons.lock_rounded`），Tooltip 为“桌面歌词已锁定，点击一键解锁”；
  - 点击该按钮触发 `unlockDesktopLyrics()`；
  - 桌面歌词未锁定时保留原有开关逻辑。
- [ ] **Step 2: Run test to verify failure**
  运行 `flutter test test/ui/desktop/desktop_player_bar_test.dart` 验证新用例失败。
- [ ] **Step 3: Implement unlockDesktopLyrics in PlayerController**
  在 `lib/controllers/player_controller.dart` 增加：
  ```dart
  bool get desktopLyricsLocked => desktopLyricsSettings.locked;
  Future<void> unlockDesktopLyrics() => setDesktopLyricsLocked(false);
  ```
- [ ] **Step 4: Update DesktopPlayerBar UI & interactions**
  在 `lib/ui/desktop/desktop_player_bar.dart`：
  - 判断 `final locked = player.desktopLyricsLocked;`；
  - 若 `enabled && locked`，图标用 `Icons.lock_rounded`，颜色高亮 `colorScheme.primary`，Tooltip 改为“桌面歌词已锁定，点击一键解锁”，点击执行 `player.unlockDesktopLyrics()`；
  - 添加右键（Secondary Tap）菜单：【解锁歌词】/【锁定歌词】/【桌面歌词设置】/【关闭桌面歌词】。
- [ ] **Step 5: Run tests and verify green**
  运行 `flutter test test/ui/desktop/desktop_player_bar_test.dart` 确保通过。

---

### Task 2: 本地播放缓存离线降级（断网播放任意可用缓存）

**Files:**
- Modify: `lib/controllers/download_controller.dart`
- Modify: `lib/controllers/player_controller.dart`
- Test: `test/controllers/player_precache_test.dart`

**Interfaces:**
- `DownloadController.localPathForAnyQuality(Song song, {AudioQuality? preferredQuality}) -> String?`:
  优先返回首选音质；若无匹配，则返回该歌曲在本地已下载或播放缓存中的任意有效文件路径。
- `PlayerController.playSong`:
  在解析网络播放 URL 前（尤其是断网时），尝试调用 `localPathForAnyQuality`，命中则直接离线开播。

- [ ] **Step 1: Write unit test for localPathForAnyQuality**
  在 `test/controllers/player_precache_test.dart` 中编写单测：
  - 首选音质匹配时返回对应路径；
  - 首选音质不匹配但存在其他音质的 `_playCache` 时，能正确返回降级路径；
  - 不存在任何本地文件时返回 null。
- [ ] **Step 2: Implement localPathForAnyQuality in DownloadController**
  在 `lib/controllers/download_controller.dart` 实现全音质降级检索：
  ```dart
  String? localPathForAnyQuality(Song song, {AudioQuality? preferredQuality}) {
    if (preferredQuality != null) {
      final exact = localPathFor(song, preferredQuality);
      if (exact != null) return exact;
    }
    // 遍历已下载
    final download = _downloads[song.hash];
    if (download?.status == DownloadStatus.downloaded &&
        download?.filePath != null &&
        File(download!.filePath!).existsSync()) {
      return download.filePath;
    }
    // 遍历播放缓存
    for (final entry in _playCache.values) {
      if (entry.song.hash == song.hash && File(entry.filePath).existsSync()) {
        return entry.filePath;
      }
    }
    return null;
  }
  ```
- [ ] **Step 3: Integrate into PlayerController.playSong offline fallback**
  在 `lib/controllers/player_controller.dart`：
  - 当 `local == null` 时，先查一次 `localPathForAnyQuality(song, preferredQuality: audioQuality)`；
  - 若命中降级缓存，直接使用该本地文件播放，跳过网络解析，并在断网时顺利播放。
- [ ] **Step 4: Run tests to verify green**
  运行 `flutter test test/controllers/player_precache_test.dart` 确认测试通过。

---

### Task 3: 多端下一首智能预缓存流水线（含随机播放感知）

**Files:**
- Modify: `lib/controllers/player_controller.dart`
- Test: `test/controllers/player_precache_test.dart`

**Interfaces:**
- `PlayerController._maybePrecacheNext(Duration position)`:
  进度 >= 70% 或剩余 <= 25s 且 >= 15s 时触发；
- `PlayerController._precacheNextTrack()`:
  并发执行下一首歌词缓存与音频下载落盘。

- [ ] **Step 1: Write unit tests for precache conditions & shuffle queue**
  在 `test/controllers/player_precache_test.dart` 编写测试：
  - 播放进度在 50% 时不触发预缓存；
  - 播放进度达到 70% 时触发且仅触发一次（防抖守卫）；
  - 切歌后防抖守卫重置；
  - 随机播放模式下，预缓存对象严格为 `_shuffleQueue` 中的下一首。
- [ ] **Step 2: Implement precache logic in PlayerController**
  在 `lib/controllers/player_controller.dart`：
  - 增加防刷与并发保护字段：
    ```dart
    String? _precachedForSongHash;
    bool _isPrecaching = false;
    ```
  - 在 `_positionSub` 监听中增加 `_maybePrecacheNext(value)`；
  - 实现 `_precacheNextTrack()`：
    - 调用 `_nextSong()` 准确获取下一首（自然支持随机播放序列）；
    - 若已有本地缓存则直接预拉取歌词；
    - 若无本地缓存则后台解析 URL 并调用 `downloadController.cacheForPlayback(...)`。
- [ ] **Step 3: Reset precache state on song change**
  在 `playSong` 开头重置 `_precachedForSongHash = null;`。
- [ ] **Step 4: Run tests and verify green**
  运行 `flutter test test/controllers/player_precache_test.dart` 确认用例通过。

---

### Task 4: 全量回归测试与代码静态检查

**Files:**
- All modified & test files

- [ ] **Step 1: Run full test suite**
  执行 `flutter test` 确保所有 280+ 个单测全部通过。
- [ ] **Step 2: Run flutter analyze**
  执行 `flutter analyze` 确保 0 警告 0 报错。
- [ ] **Step 3: Update documentation and walkthrough**
  更新 `walkthrough.md` 记录实现原理与测试结果。
