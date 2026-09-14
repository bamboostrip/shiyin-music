# 移动端播放界面与歌词展示改版实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 优化移动端播放界面：将海报页与歌词页评论图标对齐为 PC 端自绘气泡并展示评论数字；打造 QQ 音乐风格的移动端原生触控歌词页，支持逐字（KRC）高亮染色、滑动中线加重与右侧 `[ ▶ mm:ss ]` 时间胶囊跳转播放、底部独立 `[词]`、`[译 on/off]`、`[音 on/off]` 与圆形播放按钮。

**Architecture:** 
- 提取通用的 `PlayerCommentButton`，打通会话内评论数缓存与 `CommentBubbleIcon` 绘制，供 PC 底栏、移动端海报页和歌词页通用。
- 编写专为移动端触控优化的原生 `MobileLyricList`，基于 `ListView.builder`、`ScrollController` 与 `KaraokeLinePainter` 实现逐字平滑渲染高亮，并结合视口中线距离算法实现滑动时精准准星加粗与 `[ ▶ mm:ss ]` 胶囊。
- 构建 `LyricBottomBar` 底部栏，集成评论按钮、字号调节浮层、翻译/音译独立 on/off 胶囊与圆形播放按钮。

**Tech Stack:** Flutter, Dart, SharedPreferences, CustomPainter, AnimationController.

## Global Constraints

- 不改变现有桌面端播放逻辑与功能；
- 遵循已有项目代码风格与 lint 规范（`prefer_const_constructors`, `unawaited`, 私有成员规范等）；
- 保持所有修改有完备的自动化 widget 测试覆盖。

---

### Task 1: 提取通用评论按钮组件 `PlayerCommentButton`

**Files:**
- Create: `lib/ui/player/player_comment_button.dart`
- Modify: `lib/ui/player/poster_player.dart:354-377`
- Modify: `lib/ui/desktop/desktop_player_bar.dart:799-915`
- Test: `test/ui/player/player_comment_button_test.dart`

**Interfaces:**
- Produces: `class PlayerCommentButton extends StatefulWidget`
  - `PlayerCommentButton({super.key, required this.player, required this.song, this.iconSize = 22.0, this.iconColor = Colors.white, this.onOpenComment})`
  - `String formatCommentCount(int count)`
- Consumes: `CommentBubbleIcon` (from `player_bar_widgets.dart`), `CommentPage`, `PlayerController`, `Song`.

- [ ] **Step 1: 编写失败测试 `test/ui/player/player_comment_button_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/player_comment_button.dart';

void main() {
  test('formatCommentCount formats correctly', () {
    expect(formatCommentCount(0), '0');
    expect(formatCommentCount(999), '999');
    expect(formatCommentCount(1000), '999+');
    expect(formatCommentCount(12000), '1w+');
    expect(formatCommentCount(990000), '99w+');
  });

  testWidgets('PlayerCommentButton renders bubble icon', (tester) async {
    const song = Song(
      id: 'song1',
      title: 'Test Song',
      artist: 'Artist',
      source: SongSource.kugou,
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PlayerCommentButton(
            player: null,
            song: song,
          ),
        ),
      ),
    );
    expect(find.byType(PlayerCommentButton), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

运行：`flutter test test/ui/player/player_comment_button_test.dart`
预期：FAIL（文件尚未创建，编译失败）。

- [ ] **Step 3: 实现 `PlayerCommentButton` 并替换 `desktop_player_bar.dart` 与 `poster_player.dart`**

在 `lib/ui/player/player_comment_button.dart` 中实现：
- 导出 `formatCommentCount`；
- 维护 `_commentCountCache` 和 `_commentCountInFlight`；
- 构建 `PlayerCommentButton`，绘制 `CommentBubbleIcon`，若有评论数则在右上角展示数字角标。
在 `lib/ui/player/poster_player.dart` 中引入 `PlayerCommentButton`，替换原来的硬编码 Material `IconButton`。
在 `lib/ui/desktop/desktop_player_bar.dart` 中复用 `PlayerCommentButton`。

- [ ] **Step 4: 运行测试验证通过**

运行：`flutter test test/ui/player/player_comment_button_test.dart`
预期：PASS。

- [ ] **Step 5: 提交 Task 1 代码**

```bash
git add lib/ui/player/player_comment_button.dart lib/ui/player/poster_player.dart lib/ui/desktop/desktop_player_bar.dart test/ui/player/player_comment_button_test.dart
git commit -m "feat(player): extract PlayerCommentButton with badge count and use on mobile poster rail"
```

---

### Task 2: 构建歌词页底部 QQ 音乐风格控制栏 `LyricBottomBar`

**Files:**
- Create: `lib/ui/player/lyric_bottom_bar.dart`
- Test: `test/ui/player/lyric_bottom_bar_test.dart`

**Interfaces:**
- Produces: `class LyricBottomBar extends StatelessWidget`
  - Params:
    - `required PlayerController player`
    - `required Song song`
    - `required bool showTranslation`
    - `required bool showRomanization`
    - `required bool hasTranslation`
    - `required bool hasRomanization`
    - `required double lyricScale`
    - `required ValueChanged<bool> onToggleTranslation`
    - `required ValueChanged<bool> onToggleRomanization`
    - `required ValueChanged<double> onLyricScaleChanged`
- Produces: `class LyricTogglePill extends StatelessWidget`
  - 胶囊样式按钮，文字 + `on` / `off` 角标。

- [ ] **Step 1: 编写失败测试 `test/ui/player/lyric_bottom_bar_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/lyric_bottom_bar.dart';

void main() {
  testWidgets('LyricTogglePill renders on/off label and triggers callback', (tester) async {
    bool toggled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LyricTogglePill(
            label: '译',
            isOn: true,
            onToggle: () => toggled = true,
          ),
        ),
      ),
    );
    expect(find.text('译'), findsOneWidget);
    expect(find.text('on'), findsOneWidget);
    await tester.tap(find.text('译'));
    expect(toggled, isTrue);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

运行：`flutter test test/ui/player/lyric_bottom_bar_test.dart`
预期：FAIL。

- [ ] **Step 3: 实现 `LyricBottomBar`、`LyricTogglePill` 与字号微浮层**

在 `lib/ui/player/lyric_bottom_bar.dart` 中实现：
1. `LyricTogglePill`：圆角矩形胶囊，背景半透明，右上角展示微型 `on` / `off` 文本标签；
2. `[词]` 胶囊按钮：点击触发 `_showFontSizeDialog` 或带有 `A-` / `A+` 与重置的弹层；
3. 左侧接入 `PlayerCommentButton`；
4. 右侧展示 `[词]`、`[译 on/off]`（若 `hasTranslation`）、`[音 on/off]`（若 `hasRomanization`）以及圆盘播放键（点击切换 `player.playOrPause()`）。

- [ ] **Step 4: 运行测试验证通过**

运行：`flutter test test/ui/player/lyric_bottom_bar_test.dart`
预期：PASS。

- [ ] **Step 5: 提交 Task 2 代码**

```bash
git add lib/ui/player/lyric_bottom_bar.dart test/ui/player/lyric_bottom_bar_test.dart
git commit -m "feat(lyrics): add LyricBottomBar with QQ-music style toggle pills and controls"
```

---

### Task 3: 移动端原生逐字卡拉OK歌词列表 `MobileLyricList`

**Files:**
- Create: `lib/ui/player/mobile_lyric_list.dart`
- Test: `test/ui/player/mobile_lyric_list_test.dart`

**Interfaces:**
- Produces: `class MobileLyricList extends StatefulWidget`
  - Params:
    - `required PlayerController player`
    - `required String songHash`
    - `required List<LyricLine> lyrics`
    - `required int activeIndex`
    - `required bool showTranslation`
    - `required bool showRomanization`
    - `required double lyricScale`
    - `required bool isPageVisible`

- [ ] **Step 1: 编写失败测试 `test/ui/player/mobile_lyric_list_test.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/player/mobile_lyric_list.dart';

void main() {
  testWidgets('MobileLyricList renders lines and highlights active', (tester) async {
    final lyrics = [
      const LyricLine(time: Duration(seconds: 0), text: 'Line 1'),
      const LyricLine(time: Duration(seconds: 5), text: 'Line 2'),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MobileLyricList(
            player: null,
            songHash: 'hash1',
            lyrics: lyrics,
            activeIndex: 0,
            showTranslation: false,
            showRomanization: false,
            lyricScale: 1.0,
            isPageVisible: true,
          ),
        ),
      ),
    );
    expect(find.text('Line 1'), findsOneWidget);
    expect(find.text('Line 2'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 运行测试验证失败**

运行：`flutter test test/ui/player/mobile_lyric_list_test.dart`
预期：FAIL。

- [ ] **Step 3: 实现 `MobileLyricList` 核心交互与逐字绘制**

在 `lib/ui/player/mobile_lyric_list.dart` 中实现：
1. `ScrollController` 驱动歌词平滑居中；
2. 触摸开始/滑动时置 `_userHolding = true`，停止自动滚动，通过行 `GlobalKey` 测量并计算最靠近 `viewportHeight * 0.40` 的歌词行 `_focusedIndex`；
3. 正在唱的行使用 `LyricText` / `KaraokeLinePainter` 逐字高亮，字号放大至 `(isHighlighted ? 27.0 : 20.0) * widget.lyricScale`；
4. 滑动时在视口中线右侧浮现 `SeekPointerButton(timeText: formatDuration(focusedLine.time), onTap: ...)`，附带向左渐隐辅助对齐线；
5. 点击时间胶囊或歌词行时执行 `player.seekToAndPlay(line.time)` 并立即恢复跟随；
6. 用户静止 3.5 秒后平滑恢复自动居中跟随。

- [ ] **Step 4: 运行测试验证通过**

运行：`flutter test test/ui/player/mobile_lyric_list_test.dart`
预期：PASS。

- [ ] **Step 5: 提交 Task 3 代码**

```bash
git add lib/ui/player/mobile_lyric_list.dart test/ui/player/mobile_lyric_list_test.dart
git commit -m "feat(lyrics): implement MobileLyricList with karaoke highlight and center seek pointer"
```

---

### Task 4: 集成到 `LyricPlayerPage` 与系统整体回归测试

**Files:**
- Modify: `lib/ui/player/lyric_views.dart`
- Modify: `lib/ui/pages/player_page.dart` (传递评论与状态，如需)
- Test: `test/ui/player/lyric_views_test.dart` (或对应集成测试)

- [ ] **Step 1: 编写/更新集成测试**
- [ ] **Step 2: 在 `LyricPlayerPage` 中集成 `MobileLyricList` 与 `LyricBottomBar`**
  - 移除 `flutter_lyric` 的 `LyricView`，移动端统一路由到 `MobileLyricList`；
  - 底部叠加 `LyricBottomBar`；
  - 接入 `SharedPreferences` 存储 `settings.lyric_show_translation` 与 `settings.lyric_show_romanization`；
- [ ] **Step 3: 运行全套播放器与歌词相关测试**

运行：
`flutter test test/ui/player/ test/ui/desktop/`
预期：全部 PASS。

- [ ] **Step 4: 代码格式化与静态检查**

运行：
`dart format --set-exit-if-changed lib/ test/`
`flutter analyze`
预期：0 errors, 0 warnings。

- [ ] **Step 5: 提交 Task 4 代码**

```bash
git add lib/ui/player/lyric_views.dart test/
git commit -m "feat(lyrics): integrate mobile karaoke list and bottom bar into LyricPlayerPage"
```
