# 播放队列「定位到当前歌曲」实施计划（issue #28）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 移动端与车机的播放队列面板打开时自动滚到正在播放行（居中），并提供头部定位按钮一键找回。

**Architecture:** 新建共享 `QueueLocateController`（纯滚动职责：首帧偏移估算 + 入场动画结束后 `ensureVisible` 居中校正 + 按钮触发的平滑定位）；`queue_sheet.dart` 的 builder 抽成 StatefulWidget 接入；车机 `car_left_player_panel.dart` 内联队列同样接入。PC `desktop_queue_panel.dart` 已有打开定位，不动。

**Tech Stack:** Flutter/Dart，flutter_test widget 测试（PlayerController 桩 = `ChangeNotifier` + `implements` + `noSuchMethod`，见 `test/ui/widgets/desktop_queue_panel_test.dart`）。

**Spec:** `docs/superpowers/specs/2026-11-19-queue-locate-current-design.md`

## Global Constraints

- 代码注释与 UI 文案用中文（仓库惯例）；注释密度对齐周边代码。
- `showQueueSheet(BuildContext, PlayerController)` 签名不变；不改 PC `desktop_queue_panel.dart`；不改车机队列行 UI（ListTile、无删除按钮）。
- 行步长常量：移动端 `QueueTile` = 58（56 行高 + 2 分隔）；车机两行 `ListTile` = 74（72 + 2）。
- 切歌不跟随滚动（仅高亮行与 GlobalKey 跟随，按钮手动找回）。
- GlobalKey 只挂 `index == activeIndex`（第一个匹配行），防重复歌曲同 key 崩溃。
- 测试命令在仓库根 `D:\AllCode\flutter\shiyin-music` 下执行。

---

### Task 1: `QueueLocateController` 共享定位器（TDD）

> **修订（实现期裁定）**：本仓库 Flutter 3.44.8 上 `shrinkWrap` 不再全量保活行，下方 Step 1/3 的原始代码有两处缺陷已按「两段式 jump 估算 + ensureVisible 精修」重做（见 Produces 契约与 task-1-report.md）；Step 1/3 代码块保留为最初稿，实现与测试以实际提交为准。

**Files:**
- Create: `lib/ui/widgets/queue_locate.dart`
- Test: `test/ui/widgets/queue_locate_test.dart`

**Interfaces:**
- Consumes: 无（纯 Flutter）
- Produces（Task 2/3 依赖，签名精确一致）:
  - `QueueLocateController({required double rowStride, int? initialIndex, double assumedViewportExtent = 480})`
  - `final ScrollController controller`（`initialScrollOffset = max(0, (initialIndex + 0.5) * rowStride - assumedViewportExtent / 2)`，`initialIndex == null || < 0` 时为 0）
  - `void correctWhenEntranceSettled(Animation<double>? entrance, GlobalKey rowKey)`——入场动画播完后的帧：先 `jumpTo` 居中估算（真实 viewportDimension，比构造期假定 480 准），下一帧 `ensureVisible` 居中精修
  - `Future<void> locate(int index, GlobalKey rowKey)`——先 `jumpTo` 居中估算瞬移（不依赖目标行已挂载），下一帧行在则 250ms `ensureVisible` 精修；不在则停在估算位（本仓库 Flutter 3.44.8 `shrinkWrap` 不再全量保活行，定位器必须懒构建下可用，宿主 ListView **无需**加 cacheExtent）
  - `void dispose()`

- [ ] **Step 1: 写失败测试**

```dart
// test/ui/widgets/queue_locate_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/queue_locate.dart';

/// 与 queue_sheet 同构的最小列表宿主：40 行 × 行高 56 + 分隔 2。
Widget _harness({required QueueLocateController locate, required GlobalKey activeKey}) {
  return MaterialApp(
    home: Scaffold(
      body: ListView.separated(
        controller: locate.controller,
        itemCount: 40,
        separatorBuilder: (_, _) => const SizedBox(height: 2),
        itemBuilder: (context, i) => KeyedSubtree(
          key: i == 19 ? activeKey : null,
          child: const SizedBox(height: 56, child: Text('row19')),
        ),
      ),
    ),
  );
}

void main() {
  test('初始偏移估算：目标行中心对准假定视口中心', () {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    // (19 + 0.5) * 58 - 480 / 2 = 891
    expect(locate.controller.initialScrollOffset, 891);
    locate.dispose();
  });

  testWidgets('无入场动画：correctWhenEntranceSettled 首帧后精确居中', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_harness(locate: locate, activeKey: key));

    final position = locate.controller.position;
    // 估算值先落位（891 ≤ maxScrollExtent 才可见误差校正）。
    expect(position.pixels, 891);

    locate.correctWhenEntranceSettled(null, key);
    await tester.pump();

    // 居中：行顶 19*58 + 行高一半 28 - 视口一半。
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));
    locate.dispose();
  });

  testWidgets('入场动画播完后校正；locate 平滑滚回居中；行未挂载不崩溃', (tester) async {
    final locate = QueueLocateController(rowStride: 58, initialIndex: 19);
    final key = GlobalKey();
    await tester.pumpWidget(_harness(locate: locate, activeKey: key));

    // 入场动画进行中调用：先不校正（视口未稳定），播完才居中。
    final entrance = AnimationController(
      vsync: tester,
      duration: const Duration(milliseconds: 250),
    )..forward();
    await tester.pump(const Duration(milliseconds: 50)); // 动画进行中
    locate.correctWhenEntranceSettled(entrance, key);
    await tester.pump();
    expect(locate.controller.position.pixels, 891); // 仍是估算值

    await tester.pumpAndSettle(); // 入场动画播完 → completed → 帧末校正
    final position = locate.controller.position;
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));

    // 滚走后 locate 平滑滚回。
    locate.controller.jumpTo(0);
    await tester.pump();
    await locate.locate(key);
    await tester.pumpAndSettle();
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 1));

    // 行未挂载（新 key）/ 无 client：no-op 不崩溃。
    await locate.locate(GlobalKey());
    locate.correctWhenEntranceSettled(null, GlobalKey());
    expect(locate.controller.hasClients, isTrue);
    entrance.dispose();
    locate.dispose();
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ui/widgets/queue_locate_test.dart`
Expected: FAIL（`Error: Couldn't resolve the package 'shiyin_music/ui/widgets/queue_locate.dart'` 或编译错误）

- [ ] **Step 3: 最小实现**

```dart
// lib/ui/widgets/queue_locate.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 播放队列面板「定位到正在播放行」的滚动控制（issue #28）。
///
/// 职责纯滚动，不感知 PlayerController：
/// - 构造时按固定行步长估算 [controller] 的初始偏移（假定视口 480 居中，
///   只求首帧落点接近，误差由校正兜底）；
/// - 队列面板在带入场动画的 modal 底部弹层里，动画期间视口高度在变，
///   [correctWhenEntranceSettled] 等路由动画播完后的下一帧再
///   `ensureVisible` 居中（无动画/已播完则下一帧立即校正）；
/// - [locate] 供头部定位按钮平滑滚回（~250ms）。
///
/// 队列面板均为 shrinkWrap 全量构建，目标行 context 必在，无需懒加载探测。
class QueueLocateController {
  QueueLocateController({
    required double rowStride,
    int? initialIndex,
    double assumedViewportExtent = 480,
  })  : _rowStride = rowStride,
        controller = ScrollController(
          // 目标行中心对准假定视口中心；480 为手机弹层内容区典型高度，
          // 偏差只影响入场结束后的校正跳变量（≤ 半个视口误差的一半）。
          initialScrollOffset: initialIndex == null || initialIndex < 0
              ? 0
              : math.max(0.0, (initialIndex + 0.5) * rowStride - assumedViewportExtent / 2),
        );

  final double _rowStride;
  final ScrollController controller;

  /// 精确校正：目标行 [rowKey] 居中。宿主在首帧后的回调里调用。
  void correctWhenEntranceSettled(Animation<double>? entrance, GlobalKey rowKey) {
    if (entrance == null || entrance.isCompleted) {
      _scheduleCorrection(rowKey);
      return;
    }
    void listener(AnimationStatus status) {
      switch (status) {
        case AnimationStatus.completed:
          entrance.removeStatusListener(listener);
          _scheduleCorrection(rowKey);
        case AnimationStatus.dismissed:
          // 弹层被关掉（入场动画倒放）：不再校正，撤监听。
          entrance.removeStatusListener(listener);
        default:
          break;
      }
    }
    entrance.addStatusListener(listener);
  }

  void _scheduleCorrection(GlobalKey rowKey) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOn(rowKey, animate: false));
  }

  /// 头部定位按钮：平滑滚回目标行居中。
  Future<void> locate(GlobalKey rowKey) async {
    await _centerOn(rowKey, animate: true);
  }

  Future<void> _centerOn(GlobalKey rowKey, {required bool animate}) async {
    if (!controller.hasClients) return;
    final rowContext = rowKey.currentContext;
    if (rowContext == null) return;
    await Scrollable.ensureVisible(
      rowContext,
      alignment: 0.5,
      duration: animate ? const Duration(milliseconds: 250) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  void dispose() => controller.dispose();
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/ui/widgets/queue_locate_test.dart`
Expected: PASS（3 个测试全绿）

- [ ] **Step 5: 提交**

```bash
git add lib/ui/widgets/queue_locate.dart test/ui/widgets/queue_locate_test.dart
git commit -m "feat(queue): 队列面板定位器——初始偏移估算与入场后居中校正"
```

---

### Task 2: `queue_sheet.dart` 接入定位（TDD）

**Files:**
- Modify: `lib/ui/widgets/queue_sheet.dart`（`showQueueSheet` 的 builder 全量替换为 `_QueueSheetBody`；`removeFromQueue`/`clearQueue`/`QueueTile` 不动）
- Test: `test/ui/widgets/queue_sheet_locate_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `QueueLocateController` 全部 API；`isSameSong`（已 import 自 `../player/song_tap_handler.dart`）。
- Produces: `showQueueSheet` 行为扩展（签名不变）。

- [ ] **Step 1: 写失败测试**

```dart
// test/ui/widgets/queue_sheet_locate_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/controllers/player_controller.dart';
import 'package:shiyin_music/models/music_models.dart';
import 'package:shiyin_music/ui/widgets/queue_sheet.dart';

class _FakePlayerController extends ChangeNotifier implements PlayerController {
  @override
  bool isPersonalFmActive = false;

  @override
  bool isLoadingPersonalFm = false;

  @override
  Future<bool> startPersonalFm({List<Song>? initialSongs}) async => false;

  @override
  Song? currentSong;
  @override
  List<Song> queue = const [];
  @override
  bool isPlaying = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Song _song(int n, {String? hash}) => Song(
      id: '$n',
      title: '测试歌曲$n',
      artist: '测试歌手',
      hash: hash ?? 'hash-$n',
      duration: const Duration(minutes: 3, seconds: 45),
    );

Future<void> _openSheet(WidgetTester tester, _FakePlayerController player) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (buttonContext) => IconButton(
              tooltip: '打开队列',
              onPressed: () => showQueueSheet(buttonContext, player),
              icon: const Icon(Icons.queue_music_rounded),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byTooltip('打开队列'));
  await tester.pumpAndSettle();
}

/// 队列面板 ListView 的滚动位置（弹层内唯一 ListView，controller 由定位器持有）。
ScrollPosition _sheetPosition(WidgetTester tester) {
  final listView = tester.widget<ListView>(find.byType(ListView));
  return listView.controller!.position;
}

void main() {
  testWidgets('长队列打开自动滚到正在播放行并居中', (tester) async {
    final songs = List<Song>.generate(30, (i) => _song(i + 1));
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = songs[19]
      ..isPlaying = true;
    await _openSheet(tester, player);

    final position = _sheetPosition(tester);
    // 居中目标：行顶 19*58 + 28 - 视口一半（允许半行内的布局误差）。
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 29));
  });

  testWidgets('头部定位按钮存在；当前歌不在队列时禁用', (tester) async {
    final songs = [_song(1), _song(2)];
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = _song(99) // 不在队列
      ..isPlaying = true;
    await _openSheet(tester, player);

    final button = tester.widget<IconButton>(
      find.descendant(
        of: find.byTooltip('定位到正在播放'),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);

    // 当前歌在队列时按钮可用。
    player.currentSong = songs[0];
    player.notifyListeners();
    await tester.pump();
    final enabled = tester.widget<IconButton>(
      find.descendant(
        of: find.byTooltip('定位到正在播放'),
        matching: find.byType(IconButton),
      ),
    );
    expect(enabled.onPressed, isNotNull);
  });

  testWidgets('滚走后点定位按钮平滑回到当前行居中', (tester) async {
    final songs = List<Song>.generate(30, (i) => _song(i + 1));
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = songs[19]
      ..isPlaying = true;
    await _openSheet(tester, player);

    // 滚到顶（远离当前行）。
    _sheetPosition(tester).jumpTo(0);
    await tester.pump();

    await tester.tap(find.byTooltip('定位到正在播放'));
    await tester.pumpAndSettle();

    final position = _sheetPosition(tester);
    final expected =
        (19 * 58 + 28 - position.viewportDimension / 2).clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, moreOrLessEquals(expected, epsilon: 29));
  });

  testWidgets('重复添加同一首歌：定位不崩溃且按钮可回到首个匹配行', (tester) async {
    final dup = _song(7, hash: 'hash-dup');
    final songs = [_song(1), dup, _song(7, hash: 'hash-dup'), _song(3)];
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = dup
      ..isPlaying = true;
    await _openSheet(tester); // 若 GlobalKey 重复挂载会在此抛异常

    expect(find.text('测试歌曲7'), findsNWidgets(2));
    // 两行都高亮（既有行为），定位按钮可用（key 只挂首个匹配行）。
    await tester.tap(find.byTooltip('定位到正在播放'));
    await tester.pumpAndSettle();
    expect(_sheetPosition(tester).pixels, 0.0); // 首个匹配行就在顶部附近
  });

  testWidgets('短队列回归：标题/计数渲染，当前第 2 首时不滚动', (tester) async {
    final songs = [_song(1), _song(2), _song(3)];
    final player = _FakePlayerController()
      ..queue = songs
      ..currentSong = songs[1]
      ..isPlaying = true;
    await _openSheet(tester, player);

    expect(find.text('播放队列'), findsOneWidget);
    expect(find.text('3 首'), findsOneWidget);
    expect(find.text('测试歌曲2'), findsOneWidget);
    expect(find.byIcon(Icons.equalizer_rounded), findsOneWidget);
    expect(_sheetPosition(tester).pixels, 0.0);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/ui/widgets/queue_sheet_locate_test.dart`
Expected: FAIL（找不到「定位到正在播放」按钮 / `ListView.controller` 为 null）

- [ ] **Step 3: 实现 `_QueueSheetBody`**

`queue_sheet.dart` 中 `showQueueSheet` 的 `builder:` 参数替换为 `builder: (sheetContext) => _QueueSheetBody(player: player)`，其余（`showModalBottomSheet` 参数、`removeFromQueue`、`clearQueue`、`QueueTile`）原样保留。新增 import：`'queue_locate.dart'`。新增：

```dart
/// 队列面板主体：头部（标题/计数/定位/清空）+ 可滚动队列列表。
///
/// 打开时自动滚到正在播放行居中（issue #28）；入场动画播完前视口高度
/// 在变，校正等动画结束后执行。切歌不跟随滚动（仅高亮与行 key 跟随），
/// 头部定位按钮一键找回。
class _QueueSheetBody extends StatefulWidget {
  const _QueueSheetBody({required this.player});

  final PlayerController player;

  @override
  State<_QueueSheetBody> createState() => _QueueSheetBodyState();
}

class _QueueSheetBodyState extends State<_QueueSheetBody> {
  /// QueueTile 行高 56（40 封面 + 上下 8 padding）+ 分隔 2。
  static const double _rowStride = 58;

  final GlobalKey _activeRowKey = GlobalKey();
  late final QueueLocateController _locate;
  Animation<double>? _entrance;
  bool _correctScheduled = false;

  int _indexOfCurrent() {
    final current = widget.player.currentSong;
    if (current == null) return -1;
    return widget.player.queue.indexWhere((song) => isSameSong(current, song));
  }

  @override
  void initState() {
    super.initState();
    _locate = QueueLocateController(
      rowStride: _rowStride,
      initialIndex: _indexOfCurrent(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entrance ??= ModalRoute.of(context)?.animation;
    if (_correctScheduled) return;
    _correctScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _locate.correctWhenEntranceSettled(_entrance, _activeRowKey);
    });
  }

  @override
  void dispose() {
    _locate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部（队列数 + 定位/清空可用态）监听 player，
            // 面板打开期间队列变化时保持刷新（与桌面端 DesktopQueuePanel 一致）。
            AnimatedBuilder(
              animation: widget.player,
              builder: (context, _) {
                final activeIndex = _indexOfCurrent();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Text(
                        '播放队列',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${widget.player.queue.length} 首',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Spacer(),
                      // 定位到正在播放行（issue #28）。
                      IconButton(
                        tooltip: '定位到正在播放',
                        visualDensity: VisualDensity.compact,
                        onPressed: activeIndex >= 0
                            ? () =>
                                unawaited(_locate.locate(activeIndex, _activeRowKey))
                            : null,
                        icon: const Icon(Icons.my_location_rounded, size: 20),
                        color: colorScheme.onSurfaceVariant,
                      ),
                      TextButton(
                        onPressed: widget.player.queue.length > 1
                            ? () => clearQueue(context, widget.player)
                            : null,
                        child: Text(
                          '清空',
                          style: TextStyle(color: colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            Flexible(
              child: AnimatedBuilder(
                animation: widget.player,
                builder: (context, _) {
                  if (widget.player.queue.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          '播放队列为空',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    );
                  }
                  // 行 key 只挂首个匹配行：重复添加同一首歌时多行都高亮，
                  // 但 GlobalKey 只能有一个，避免重复挂载崩溃。
                  final activeIndex = _indexOfCurrent();
                  return ListView.separated(
                    controller: _locate.controller,
                    shrinkWrap: true,
                    itemCount: widget.player.queue.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 2),
                    itemBuilder: (context, index) {
                      final song = widget.player.queue[index];
                      final active = isSameSong(widget.player.currentSong, song);
                      return KeyedSubtree(
                        key: index == activeIndex ? _activeRowKey : null,
                        child: QueueTile(
                          song: song,
                          index: index + 1,
                          active: active,
                          isPlaying: active && widget.player.isPlaying,
                          onTap: () {
                            // 点到当前歌只关面板不重播（对齐列表页 318eea8）
                            if (isSameSong(widget.player.currentSong, song)) {
                              Navigator.of(context).pop();
                              return;
                            }
                            Navigator.of(context).pop();
                            widget.player.playSong(song, queue: widget.player.queue);
                          },
                          onDelete: widget.player.queue.length > 1
                              ? () => removeFromQueue(context, widget.player, index)
                              : null,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

注意：原 builder 里用的 `sheetContext`（`Theme.of(sheetContext)`、`Navigator.of(sheetContext)`、`clearQueue(sheetContext, ...)`）在新代码里全部改为 State 的 `context`。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/ui/widgets/queue_sheet_locate_test.dart`
Expected: PASS（5 个测试全绿）

- [ ] **Step 5: 提交**

```bash
git add lib/ui/widgets/queue_sheet.dart test/ui/widgets/queue_sheet_locate_test.dart
git commit -m "feat(queue): 队列面板打开定位到正在播放行 + 头部定位按钮（issue #28）"
```

---

### Task 3: 车机队列面板接入

**Files:**
- Modify: `lib/ui/widgets/car_left_player_panel.dart`（`_showQueue` 约 503-632 行：builder 内容抽出为 `_CarQueueSheetBody`；行 ListTile、内联清空逻辑不动）

**Interfaces:**
- Consumes: Task 1 的 `QueueLocateController` 全部 API；`isSameSong`（已 import）。
- Produces: 车机队列面板同款定位行为（无独立测试：定位逻辑已被 Task 1/2 覆盖，此处仅布局接线；现有 `car_left_player_panel_test.dart` 与 `car_display_integration_test.dart` 作回归网）。

- [ ] **Step 1: 改造 `_showQueue`，抽出 `_CarQueueSheetBody`**

`_showQueue` 的 builder 参数替换为 `builder: (sheetContext) => _CarQueueSheetBody(player: player)`（`showModalBottomSheet` 参数不动）。文件底部（`_CarProgressBar` 类之前）新增，顶部补 `import 'queue_locate.dart';`（与其它 `../widgets` 同级 import 排在一起，按字母序放在 `marquee_text.dart` 之后）：

```dart
/// 车机队列面板主体：头部（标题/计数/定位/清空）+ 可滚动队列列表。
///
/// 与移动端 queue_sheet 同款「打开定位到正在播放行 + 头部定位按钮」
/// （issue #28）；行 UI 保留车机简化版（ListTile、无删除按钮，驾驶
/// 场景防误触）。清空为内联实现（驾驶时不断流语义与移动端一致）。
class _CarQueueSheetBody extends StatefulWidget {
  const _CarQueueSheetBody({required this.player});

  final PlayerController player;

  @override
  State<_CarQueueSheetBody> createState() => _CarQueueSheetBodyState();
}

class _CarQueueSheetBodyState extends State<_CarQueueSheetBody> {
  /// 两行 ListTile（title+subtitle）72 + 分隔 2。
  static const double _rowStride = 74;

  final GlobalKey _activeRowKey = GlobalKey();
  late final QueueLocateController _locate;
  Animation<double>? _entrance;
  bool _correctScheduled = false;

  int _indexOfCurrent() {
    final current = widget.player.currentSong;
    if (current == null) return -1;
    return widget.player.queue.indexWhere((song) => isSameSong(current, song));
  }

  @override
  void initState() {
    super.initState();
    _locate = QueueLocateController(
      rowStride: _rowStride,
      initialIndex: _indexOfCurrent(),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entrance ??= ModalRoute.of(context)?.animation;
    if (_correctScheduled) return;
    _correctScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _locate.correctWhenEntranceSettled(_entrance, _activeRowKey);
    });
  }

  @override
  void dispose() {
    _locate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部监听 player，面板打开期间队列变化时保持刷新。
            AnimatedBuilder(
              animation: widget.player,
              builder: (context, _) {
                final activeIndex = _indexOfCurrent();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Text(
                        '播放队列',
                        style: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${widget.player.queue.length} 首',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Spacer(),
                      // 定位到正在播放行（issue #28）。
                      IconButton(
                        tooltip: '定位到正在播放',
                        visualDensity: VisualDensity.compact,
                        onPressed: activeIndex >= 0
                            ? () =>
                                unawaited(_locate.locate(activeIndex, _activeRowKey))
                            : null,
                        icon: const Icon(Icons.my_location_rounded, size: 20),
                        color: colorScheme.onSurfaceVariant,
                      ),
                      TextButton(
                        onPressed: widget.player.queue.length > 1
                            ? () {
                                final current = widget.player.currentSong;
                                if (current == null) return;
                                Navigator.of(context).pop();
                                // 与移动端队列语义对齐：静默换队不重载，驾驶时不断流
                                unawaited(widget.player.replaceQueue([current]));
                                Toast.success('已清空播放队列');
                              }
                            : null,
                        child: Text(
                          '清空',
                          style: TextStyle(color: colorScheme.error),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
            Flexible(
              child: AnimatedBuilder(
                animation: widget.player,
                builder: (context, _) {
                  if (widget.player.queue.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          '播放队列为空',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    );
                  }
                  // 行 key 只挂首个匹配行（重复歌曲防 GlobalKey 冲突）。
                  final activeIndex = _indexOfCurrent();
                  return ListView.separated(
                    controller: _locate.controller,
                    shrinkWrap: true,
                    itemCount: widget.player.queue.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 2),
                    itemBuilder: (context, index) {
                      final song = widget.player.queue[index];
                      final active =
                          isSameSong(widget.player.currentSong, song);
                      return KeyedSubtree(
                        key: index == activeIndex ? _activeRowKey : null,
                        child: ListTile(
                          selected: active,
                          leading: Artwork(
                            url: song.coverUrl,
                            size: 40,
                            borderRadius: 8,
                          ),
                          title: active
                              ? MarqueeText.text(
                                  song.title,
                                  style: TextStyle(
                                    color: colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                                )
                              : Text(
                                  song.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          subtitle: Text(song.artist),
                          trailing: active
                              ? Icon(
                                  widget.player.isPlaying
                                      ? Icons.equalizer_rounded
                                      : Icons.pause_rounded,
                                  color: colorScheme.primary,
                                )
                              : null,
                          onTap: () {
                            // 点当前行只关面板不重头播（与队列面板一致）
                            if (isSameSong(widget.player.currentSong, song)) {
                              Navigator.of(context).pop();
                              return;
                            }
                            Navigator.of(context).pop();
                            widget.player
                                .playSong(song, queue: widget.player.queue);
                          },
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

原 `_showQueue` 内联的 ListTile itemBuilder 与现有实现逐字段一致（title/subtitle/trailing/onTap 原样搬入），仅新增 controller、KeyedSubtree 与头部定位按钮。

- [ ] **Step 2: 静态检查 + 车机回归测试**

Run: `flutter analyze lib/ui/widgets/car_left_player_panel.dart && flutter test test/ui/widgets/car_left_player_panel_test.dart test/ui/pages/car_display_integration_test.dart`
Expected: No issues / 全部 PASS

- [ ] **Step 3: 提交**

```bash
git add lib/ui/widgets/car_left_player_panel.dart
git commit -m "feat(car): 车机队列面板接入打开定位与头部定位按钮（issue #28）"
```

---

### Task 4: 全量回归与收尾

**Files:**
- 无新增（验证任务）

**Interfaces:**
- Consumes: 前三个任务的全部产物。

- [ ] **Step 1: 全仓静态分析**

Run: `flutter analyze`
Expected: No issues found!

- [ ] **Step 2: 全量测试**

Run: `flutter test`
Expected: 全部 PASS（现有 ~1600 个 + 新增 8 个）

- [ ] **Step 3: 手动检查清单（供 review 时核对）**

- 打开队列面板（播放页 → 队列按钮）：长队列自动滚到正在播放行居中；短队列不滚动。
- 面板开着切歌：列表不动，高亮行移动；点定位按钮回到新当前行。
- 重复添加同一首歌后打开面板：不崩溃，按钮定位到首个匹配行。
- 删非当前行（面板保持打开）：定位按钮仍回当前行。
- 车机模式同上抽查。

- [ ] **Step 4: 若全绿，本分支实现阶段结束（不自行发版/不改 update.md，发版流程另行处理）**
