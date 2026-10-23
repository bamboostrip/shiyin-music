# 歌词页切歌按钮与顶部间距收紧 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移动端歌词页底部栏并入 上一首/下一首 切歌键（issue #3 主诉求），并温和收紧播放页顶部留白（约 16px）。

**Architecture:** `LyricBottomBar`（仅移动端歌词页使用）在圆形播放/暂停键两侧加私有 `_LyricSkipButton`，LayoutBuilder 按可用宽度分三档（≥380 / <380 / <340）收紧间距与按钮尺寸防窄屏溢出；`TopBar` 页点行与歌词页标题头只改 padding 常量。切歌直调 `player.previous()/next()`（与封面页 `Controls` 同一 API）。

**Tech Stack:** Flutter (Dart)，flutter_test widget 测试。

## Global Constraints

- 分支 `feat/lyrics-skip-buttons`（自 main），不合 main，等用户审查
- 提交信息遵循 `docs/commit-convention.md`：`type(scope): 中文首行≤30字` + `- ` bullets，一事一提交
- 不动桌面/车机分栏布局（`LandscapePlayerContent`/`DesktopLyricList`）
- 不新增依赖
- 验证命令：`flutter analyze`、`flutter test test/ui/player/`

---

### Task 1: LyricBottomBar 并入切歌键

**Files:**
- Modify: `lib/ui/player/lyric_bottom_bar.dart`
- Test: `test/ui/player/lyric_bottom_bar_test.dart`

**Interfaces:**
- Consumes: `PlayerController.previous()` / `PlayerController.next()`（已存在，`Future<void>`）
- Produces: 无对外新接口（`_LyricSkipButton` 私有）；测试用 ValueKey `lyric_previous_button` / `lyric_next_button`

- [ ] **Step 1: 写失败测试**

在 `test/ui/player/lyric_bottom_bar_test.dart` 的 `_FakePlayerController` 里加计数器与覆写（放在 `togglePlay` 覆写之后）：

```dart
  int previousCalls = 0;
  int nextCalls = 0;

  @override
  Future<void> previous() async => previousCalls++;

  @override
  Future<void> next() async => nextCalls++;
```

在文件末尾 `main()` 的 `group('LyricBottomBar', ...)` 内追加两个用例：

```dart
    testWidgets('renders skip buttons and triggers previous/next', (
      tester,
    ) async {
      const song = Song(id: 's1', hash: 'h1', title: 'Song', artist: 'Artist');
      final player = _FakePlayerController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricBottomBar(
              player: player,
              song: song,
              showTranslation: false,
              showRomanization: false,
              hasTranslation: false,
              hasRomanization: false,
              lyricScale: 1.0,
              onToggleTranslation: (_) {},
              onToggleRomanization: (_) {},
              onLyricScaleChanged: (_) {},
            ),
          ),
        ),
      );

      final prevBtn = find.byKey(const ValueKey('lyric_previous_button'));
      final nextBtn = find.byKey(const ValueKey('lyric_next_button'));
      expect(prevBtn, findsOneWidget);
      expect(nextBtn, findsOneWidget);

      await tester.tap(prevBtn);
      await tester.tap(nextBtn);
      expect(player.previousCalls, 1);
      expect(player.nextCalls, 1);
    });

    testWidgets('does not overflow on 320dp width with both pills shown', (
      tester,
    ) async {
      const song = Song(id: 's1', hash: 'h1', title: 'Song', artist: 'Artist');
      final player = _FakePlayerController();

      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LyricBottomBar(
              player: player,
              song: song,
              showTranslation: true,
              showRomanization: true,
              hasTranslation: true,
              hasRomanization: true,
              lyricScale: 1.0,
              onToggleTranslation: (_) {},
              onToggleRomanization: (_) {},
              onLyricScaleChanged: (_) {},
            ),
          ),
        ),
      );

      // 渲染期若 Row 溢出，Flutter 会抛 RenderFlex overflow，用例直接失败。
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lyric_previous_button')),
          findsOneWidget);
    });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ui/player/lyric_bottom_bar_test.dart`
Expected: 新增两用例 FAIL（`lyric_previous_button` 找不到），原有用例 PASS

- [ ] **Step 3: 最小实现**

`lib/ui/player/lyric_bottom_bar.dart`，在 `_LyricRoundPlayPauseButton` 类之后新增：

```dart
/// 歌词页底部上一首/下一首切歌键（issue #3：看歌词时免滑回封面页即可切歌）。
/// 与封面页 Controls 同一 player API，仅样式更收敛以塞进药丸行。
class _LyricSkipButton extends StatelessWidget {
  const _LyricSkipButton.previous({required this.onPressed, this.buttonSize = 40, this.iconSize = 26})
      : tooltip = '上一首',
        icon = Icons.skip_previous_rounded,
        super(key: const ValueKey('lyric_previous_button'));

  const _LyricSkipButton.next({required this.onPressed, this.buttonSize = 40, this.iconSize = 26})
      : tooltip = '下一首',
        icon = Icons.skip_next_rounded,
        super(key: const ValueKey('lyric_next_button'));

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final double buttonSize;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: buttonSize,
      child: Tooltip(
        message: tooltip,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: iconSize,
          color: Colors.white.withValues(alpha: 0.85),
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      ),
    );
  }
}
```

把 `LyricBottomBar.build` 整体替换为（LayoutBuilder 分档防溢出；宽度账：常规档全开 368dp≤390，紧凑档 340≤360，超紧凑档 314≤320）：

```dart
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 并入切歌键后右侧变挤，按可用宽度分档收紧间距与按钮：
        // <380（360dp 主流安卓）pill 间距 10、切歌 36px；
        // <340（320dp 小屏/部分车机）pill 间距 8、切歌 32px、水平边距 12。
        final width = constraints.maxWidth;
        final pillGap = width < 340 ? 8.0 : (width < 380 ? 10.0 : 14.0);
        final skipGap = width < 340 ? 6.0 : (width < 380 ? 8.0 : 12.0);
        final skipSize = width < 340 ? 32.0 : (width < 380 ? 36.0 : 40.0);
        final skipIcon = width < 340 ? 20.0 : (width < 380 ? 22.0 : 26.0);
        final hPadding = width < 340 ? 12.0 : 16.0;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: hPadding, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 左侧：评论入口
              PlayerCommentButton(
                player: player,
                song: song,
                iconSize: 22.0,
                iconColor: Colors.white.withValues(alpha: 0.85),
                onOpenComment: onOpenComment,
              ),

              const Spacer(),

              // 右侧：[词] 字号调节
              _LyricSettingsPill(onTap: () => _showFontSizeSheet(context)),
              SizedBox(width: pillGap),

              // [译 on/off]
              if (hasTranslation) ...[
                LyricTogglePill(
                  label: '译',
                  isOn: showTranslation,
                  tooltip: '翻译 (${showTranslation ? '已开启' : '已关闭'})',
                  onToggle: () => onToggleTranslation(!showTranslation),
                ),
                SizedBox(width: pillGap),
              ],

              // [音 on/off]
              if (hasRomanization) ...[
                LyricTogglePill(
                  label: '音',
                  isOn: showRomanization,
                  tooltip: '拼音/音译 (${showRomanization ? '已开启' : '已关闭'})',
                  onToggle: () => onToggleRomanization(!showRomanization),
                ),
                SizedBox(width: pillGap),
              ],

              // 上一首 / 播放暂停 / 下一首
              _LyricSkipButton.previous(
                onPressed: player.previous,
                buttonSize: skipSize,
                iconSize: skipIcon,
              ),
              SizedBox(width: skipGap),
              _LyricRoundPlayPauseButton(player: player),
              SizedBox(width: skipGap),
              _LyricSkipButton.next(
                onPressed: player.next,
                buttonSize: skipSize,
                iconSize: skipIcon,
              ),
            ],
          ),
        );
      },
    );
  }
```

同时把类 doc 注释里右侧描述补上切歌键（`- 右侧：`词` 字号入口、`[译 on/off]`、`[音 on/off]`、上一首/播放暂停/下一首`）。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/ui/player/lyric_bottom_bar_test.dart`
Expected: 全部 PASS（原 4 条 + 新 2 条）

- [ ] **Step 5: 提交**

```bash
git add lib/ui/player/lyric_bottom_bar.dart test/ui/player/lyric_bottom_bar_test.dart
git commit -m "feat(lyrics): 歌词页底部栏并入上一首下一首切歌键

- 看歌词时切歌此前必须横滑回封面页，圆形播放键两侧并入 skip 键直调 player.previous/next
- 右侧变挤后按可用宽度三档收紧间距与切歌键尺寸，320dp 窄屏译音双 pill 全开不溢出
- 补切歌键渲染/点击计数与 320dp 防溢出两用例"
```

---

### Task 2: 播放页顶部留白温和收紧

**Files:**
- Modify: `lib/ui/player/player_top_bar.dart:96`（页点变体 padding）
- Modify: `lib/ui/player/lyric_views.dart:107`（歌词页标题头 padding）

**Interfaces:**
- Consumes: Task 1 已合入的 `LyricBottomBar`（本任务不改它，回归验证）
- Produces: 无

- [ ] **Step 1: 改 TopBar 页点行上下内边距**

`player_top_bar.dart` 中 `currentPage != null` 分支（第 95-96 行）：

```dart
      content = Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
```

（原值 `fromLTRB(8, 8, 8, 6)`。仅页点变体；`else` 分支的标题行变体是桌面/车机分栏用，不动。）

- [ ] **Step 2: 改歌词页标题头上边距**

`lyric_views.dart` `_buildHeader`（第 107 行）：

```dart
      padding: const EdgeInsets.fromLTRB(20, 2, 16, 8),
```

（原值 `fromLTRB(20, 6, 16, 8)`。）

- [ ] **Step 3: 静态检查 + 回归**

Run: `flutter analyze`
Expected: No issues

Run: `flutter test test/ui/player/`
Expected: 全部 PASS（间距常量无测试断言，跑全目录确认无回归）

- [ ] **Step 4: 提交**

```bash
git add lib/ui/player/player_top_bar.dart lib/ui/player/lyric_views.dart
git commit -m "style(player): 播放页顶部留白温和收紧

- 页点行上下内边距 8/6 收到 4/2，歌词页歌名头上边距 6 收到 2，合计约省 16px 给歌词区
- 封面页共用页点行同步微收，两页顶部观感一致（issue #3 次要诉求）
- flutter analyze 无告警，test/ui/player 全过"
```

---

## 收尾（计划外自动步骤）

实现完成后向用户汇报：分支、提交清单、验证结果；等用户审查后再决定是否合入 main / 回复 issue。不主动 push、不合并 main（用户明确要先审查）。
