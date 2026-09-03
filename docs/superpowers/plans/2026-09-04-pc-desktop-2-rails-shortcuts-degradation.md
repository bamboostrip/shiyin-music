# 时音 PC 桌面适配 · 计划 2/3：横轨网格化、滚轮横滚、快捷键与桌面降级 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 桌面形态下横向轨道在宽窗口转网格、保留的横轨支持滚轮直接横滚（免 Shift）、补全桌面快捷键与音量联动、完成 Android-only 功能的桌面降级排查；Android 车机/平板/手机路径零回归。

**Architecture:** 新共享组件 `HorizontalWheelScroll`（builder 注入 ScrollController）与 `HorizontalWheelPageScroll`（驱动既有 PageController）承接滚轮；`AppHorizontalRail` 内部按 `isDesktopFormFactor && width ≥ kGridStartWidth` 切网格；桌面专属快捷键（Ctrl+F / Ctrl+1-3 / Enter）挂在 DesktopShell 内部，全局播放/音量快捷键挂在既有 AppShortcutScope。`isDesktopFormFactor` 改为可注入 getter 以便测试双形态。

**Tech Stack:** Flutter (Material)；无新依赖。

**设计文档:** `docs/superpowers/specs/2026-09-04-pc-desktop-adaptation-design.md` §3/§5/§9 + 计划 1 终审 carry-in 项。

## Global Constraints

- **禁止修改窄屏/车机路径行为**：所有网格转换的门控条件是 `isDesktopFormFactor && width >= 840`；滚轮横滚对横轨全平台生效（触屏无滚轮，天然无副作用）；车机专属分支（carMode）渲染结果与重构前逐像素一致。
- **平台判定收敛**：UI 代码只引用 `form_factor.dart` 的 `isDesktopFormFactor`（本计划将其改为 getter，调用点语法不变）。
- **home_page.dart（≈2940 行）净增目标 < 80 行**：只允许本计划列出的改动；不允许顺手重构无关代码。
- 提交信息风格 `type(scope): 中文描述`；每任务 `flutter analyze` 无新增告警、`flutter test` 全绿（当前基线 46/46）。
- 分支 `feature/pc-desktop-adaptation`（继续使用）。
- 明确跳过项：`audio_effects_sheet.dart` 的 EQ 滑杆滚轮（音频特效为 Android-only 功能，桌面端不出现该面板）；`search_page.dart:836` 骨架屏横条（加载占位，无交互意义）。

---

## File Structure

| 操作 | 路径 | 职责 |
|---|---|---|
| Modify | `lib/ui/form_factor.dart` | getter 化 + `debugDesktopFormFactorOverride` |
| Test | `test/ui/form_factor_test.dart` | override 注入测试 |
| Modify | `lib/ui/adaptive_layout.dart` | 常量 + asserts + `gridColumnsForWidth` 复用常量 |
| Test | `test/ui/adaptive_width_class_test.dart` | 追加 700 用例 |
| Modify | `lib/ui/desktop/desktop_shell.dart` | `_handleHomeTabSwitch` 钳制 + 桌面快捷键 |
| Modify | `lib/ui/pages/app_shell.dart` | AppShortcutScope ↑↓ 音量 |
| Create | `lib/ui/widgets/horizontal_wheel_scroll.dart` | 两个滚轮组件 |
| Test | `test/ui/widgets/horizontal_wheel_scroll_test.dart` | 滚轮驱动测试 |
| Modify | `lib/ui/widgets/app_section.dart` | AppHorizontalRail 网格化 + 滚轮 |
| Test | `test/ui/widgets/app_horizontal_rail_test.dart` | 双形态测试 |
| Modify | `lib/ui/pages/home_page.dart` | 播放歌单/电台轨/猜你喜欢 PageView/底部留白 |
| Modify | `lib/ui/pages/rank_page.dart` | 新歌推荐网格化 + 滚轮 |
| Modify | `lib/ui/pages/search_page.dart` | 分类 tab 条 + 热搜 PageView 滚轮 |
| Modify | `lib/ui/pages/player_page.dart` | 海报/歌词 PageView 滚轮 |
| Modify | `lib/controllers/player_controller.dart` | setVolume notifyListeners |
| Modify | `lib/ui/desktop/desktop_player_bar.dart` | 音量滑块同步 + 内层冗余消除 |
| Modify | `lib/ui/desktop/desktop_sidebar.dart` | 导航条目 Semantics |
| Modify | 若排查发现入口未守卫的页面 | Android-only 降级（见 Task 8） |

---

### Task 1: form_factor 可测试化（TDD）

**Files:**
- Modify: `lib/ui/form_factor.dart`
- Test: `test/ui/form_factor_test.dart`（新建）

**Interfaces:**
- Produces: `bool debugDesktopFormFactorOverride`（顶层可变量，测试注入用；null=按平台）；`isDesktopFormFactor` 变为顶层 getter（所有既有调用点语法不变）。后续所有双形态测试依赖此机制。

- [ ] **Step 1: 写失败测试** — 创建 `test/ui/form_factor_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/form_factor.dart';

void main() {
  tearDown(() {
    debugDesktopFormFactorOverride = null;
  });

  test('默认跟随平台（测试宿主为 Windows 桌面）', () {
    debugDesktopFormFactorOverride = null;
    // flutter test 在宿主 OS 上运行；CI/本机均为 Windows → true。
    // 若未来在非桌面宿主跑测试，此断言需按宿主调整。
    expect(isDesktopFormFactor, isTrue);
  });

  test('override 强制非桌面', () {
    debugDesktopFormFactorOverride = false;
    expect(isDesktopFormFactor, isFalse);
  });

  test('override 强制桌面', () {
    debugDesktopFormFactorOverride = true;
    expect(isDesktopFormFactor, isTrue);
  });
}
```

- [ ] **Step 2: RED** — `flutter test test/ui/form_factor_test.dart`，预期 FAIL（`debugDesktopFormFactorOverride` 未定义）。

- [ ] **Step 3: 实现** — 将 `lib/ui/form_factor.dart` 全文替换为：

```dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 测试注入开关：非 null 时 [isDesktopFormFactor] 直接返回该值。
///
/// 仅用于 widget 测试在任意宿主上覆盖桌面/非桌面双形态；
/// 业务代码禁止写入。
bool? debugDesktopFormFactorOverride;

final bool _osIsDesktop =
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 桌面形态判定：仅由操作系统决定，与窗口大小无关。
///
/// 车机/平板/手机均为 Android，恒为 false，走既有布局路径；
/// Windows/macOS/Linux 视为桌面，启用桌面 Shell。
/// 全项目唯一的桌面平台判定入口，页面代码不得散落 Platform.isWindows。
// ignore: non_constant_identifier_names
bool get isDesktopFormFactor =>
    debugDesktopFormFactorOverride ?? _osIsDesktop;
```

注意：原实现是 `final bool isDesktopFormFactor = ...`；改为 getter 后所有 `isDesktopFormFactor` 调用点语法不变，`flutter analyze` 应零告警（`non_constant_identifier_names` 的 ignore 仅在 analyze 报错时保留——getter 名为下划线开头风格对齐原常量，若 analyze 无告警则删除该 ignore 行， getter 改为小驼峰 `isDesktopFormFactor` 本身合规，无需 ignore）。

- [ ] **Step 4: GREEN + 回归** — `flutter test test/ui/form_factor_test.dart` PASS；`flutter analyze` 零新增告警；`flutter test` 全量通过。

- [ ] **Step 5: 提交** — `git commit -m "refactor(pc): 桌面形态判定支持测试注入覆盖"`

### Task 2: 断点工具加固 + DesktopShell 钳制（TDD）

**Files:**
- Modify: `lib/ui/adaptive_layout.dart`、`test/ui/adaptive_width_class_test.dart`
- Modify: `lib/ui/desktop/desktop_shell.dart`

**Interfaces:**
- Produces: `double AdaptiveLayout.kGridStartWidth = 840`、`double AdaptiveLayout.kGridHorizontalPadding = 32`（常量，网格化门控统一引用）；`gridColumnsForWidth` 含参数防卸断言；DesktopShell `_handleHomeTabSwitch` 对越界 shellIndex 静默钳制。

- [ ] **Step 1: 追加失败测试** — 在 `test/ui/adaptive_width_class_test.dart` 的 `gridColumnsForWidth` group 内追加：

```dart
    test('medium 区间(600-839)恒返回 min（钉住早退守卫行为）', () {
      expect(AdaptiveLayout.gridColumnsForWidth(600), 2);
      expect(AdaptiveLayout.gridColumnsForWidth(700), 2);
      expect(AdaptiveLayout.gridColumnsForWidth(839), 2);
    });
```

- [ ] **Step 2: RED** — 运行该文件测试，预期 PASS（守卫已在计划 1 落地，此步是钉行为）+ 随后的常量重构仍需保持 PASS。

- [ ] **Step 3: 实现** — `AdaptiveLayout` 类内追加常量并让 `gridColumnsForWidth` 引用：

```dart
  /// 横轨转网格的宽度起点（逻辑像素），与 widthClassFor 的 expanded 对齐。
  static const double kGridStartWidth = 840;

  /// 网格列数计算时为两侧内容预留的总边距。
  static const double kGridHorizontalPadding = 32;
```

`gridColumnsForWidth` 改为（加防御断言、用常量）：

```dart
  static int gridColumnsForWidth(
    double width, {
    double minItemWidth = 200,
    int min = 2,
    int max = 6,
  }) {
    assert(minItemWidth > 0, 'minItemWidth 必须为正数');
    assert(min <= max, 'min 不能大于 max');
    if (width < kGridStartWidth) return min;
    return ((width - kGridHorizontalPadding) ~/ minItemWidth).clamp(min, max);
  }
```

- [ ] **Step 4: DesktopShell 钳制** — `desktop_shell.dart` 的 `_handleHomeTabSwitch` 改为：

```dart
  /// HomePage.onTabSwitch 的 shell 级下标语义（0=我的, 1..3=三个子 tab）。
  /// 越界值静默钳制，防止侧栏高亮失步（HomePage 当前只发 0..3，防御性收敛）。
  void _handleHomeTabSwitch(int shellIndex) {
    setState(() {
      final clamped = shellIndex.clamp(0, 3);
      if (clamped <= 0) {
        _section = _DesktopSection.library;
      } else {
        _section = _DesktopSection.home;
        _homeTab = clamped - 1;
      }
    });
  }
```

- [ ] **Step 5: 验证 + 提交** — `flutter test`（全量）+ `flutter analyze`；`git commit -m "refactor(pc): 断点常量化加固与桌面 tab 切换钳制"`

### Task 3: 滚轮横滚共享组件（TDD）

**Files:**
- Create: `lib/ui/widgets/horizontal_wheel_scroll.dart`
- Test: `test/ui/widgets/horizontal_wheel_scroll_test.dart`（新建）

**Interfaces:**
- Produces:
  - `class HorizontalWheelScroll extends StatefulWidget { const HorizontalWheelScroll({super.key, required this.builder}); final Widget Function(BuildContext context, ScrollController controller) builder; }` — 内部自建/自释放 ScrollController，把垂直滚轮增量转为横向 `position.pointerScroll`。
  - `class HorizontalWheelPageScroll extends StatelessWidget { const HorizontalWheelPageScroll({super.key, required this.controller, required this.child}); final ScrollController controller; final Widget child; }` — 包裹既有 PageView（PageController 是 ScrollController 子类），滚轮驱动 `controller.position.pointerScroll`，由 PageView 物理吸附翻页。

- [ ] **Step 1: 写失败测试** — 创建 `test/ui/widgets/horizontal_wheel_scroll_test.dart`：

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/widgets/horizontal_wheel_scroll.dart';

void main() {
  Future<void> sendWheel(WidgetTester tester, Offset dy) async {
    final center = tester.getCenter(find.byType(ListView));
    final signal = PointerSignalEvent; // 占位防误用；实际用下一行
    // ignore: unused_local_variable
    final _ = signal;
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: dy),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('垂直滚轮驱动横向 ListView', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            child: HorizontalWheelScroll(
              builder: (context, controller) => ListView.separated(
                controller: controller,
                scrollDirection: Axis.horizontal,
                itemCount: 40,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (_, i) => SizedBox(width: 80, child: Text('i$i')),
              ),
            ),
          ),
        ),
      ),
    ));
    // 外部传入的 controller 不被组件使用；组件内部自建 controller。
    // 通过找到实际 ListView 的 position 验证滚动。
    controller.dispose();

    await sendWheel(tester, const Offset(0, 120));
    final listFinder = find.byType(ListView);
    final ScrollPosition position = Scrollable.of(
      tester.element(listFinder),
    ).position;
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('PageController 由滚轮驱动（HorizontalWheelPageScroll）', (tester) async {
    final pageController = PageController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HorizontalWheelPageScroll(
          controller: pageController,
          child: PageView(
            controller: pageController,
            children: [
              for (var i = 0; i < 5; i)
                SizedBox.expand(child: Center(child: Text('p$i'))),
            ],
          ),
        ),
      ),
    ));

    final center = tester.getCenter(find.byType(PageView));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 400)),
    );
    await tester.pumpAndSettle();
    expect(pageController.page, greaterThan(0));
    pageController.dispose();
  });
}
```

注意：第一段测试里 `controller` 是干扰项（证明组件不依赖外部 controller），实现时把测试简化为不创建外部 controller、直接用 `Scrollable.of` 断言（保留 `sendWheel` helper；删除占位行 `final signal = ...` 与 unused 注释——它们只是提示实现者不要用 PointerSignalEvent 类型名误写，正式测试文件里不出现）。

- [ ] **Step 2: RED** — `flutter test test/ui/widgets/horizontal_wheel_scroll_test.dart`，FAIL（文件不存在）。

- [ ] **Step 3: 实现** — 创建 `lib/ui/widgets/horizontal_wheel_scroll.dart`：

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 把垂直滚轮增量转为子级横向滚动（PC 适配：免 Shift 横向滚动）。
///
/// [builder] 注入组件内部持有的 [ScrollController]，调用方把它接到
/// 自己的横向 ListView/SingleChildScrollView 上；组件随自身销毁释放。
/// 说明：滚轮落在横轨区域时事件被本组件消费，不会穿透给父级纵向滚动——
/// 需要滚动页面时把鼠标移出横轨即可（与主流桌面音乐软件一致）。
class HorizontalWheelScroll extends StatefulWidget {
  const HorizontalWheelScroll({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  @override
  State<HorizontalWheelScroll> createState() => _HorizontalWheelScrollState();
}

class _HorizontalWheelScrollState extends State<HorizontalWheelScroll> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) => _scrollOnWheel(context, event, _controller),
      child: widget.builder(context, _controller),
    );
  }
}

/// 滚轮驱动既有 [PageView]（controller 传入其 PageController）。
///
/// pointerScroll 的增量由 PageView 的页面物理吸附，表现为滚轮翻页。
class HorizontalWheelPageScroll extends StatelessWidget {
  const HorizontalWheelPageScroll({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (event) => _scrollOnWheel(context, event, controller),
      child: child,
    );
  }
}

void _scrollOnWheel(
  BuildContext context,
  PointerSignalEvent event,
  ScrollController controller,
) {
  if (event is! PointerScrollEvent) return;
  final delta = event.scrollDelta.dy;
  if (delta == 0 || !controller.hasClients) return;
  final position = controller.position;
  if (position.maxScrollExtent <= 0) return;
  position.pointerScroll(delta);
}
```

- [ ] **Step 4: GREEN + 回归** — 聚焦测试 PASS；`flutter analyze` 干净；`flutter test` 全量。

- [ ] **Step 5: 提交** — `git commit -m "feat(pc): 滚轮横滚共享组件（横轨/翻页双形态）"`

### Task 4: AppHorizontalRail 自适应（TDD）

**Files:**
- Modify: `lib/ui/widgets/app_section.dart`
- Test: `test/ui/widgets/app_horizontal_rail_test.dart`（新建）

**Interfaces:**
- Consumes: `HorizontalWheelScroll`（Task 3）、`isDesktopFormFactor`（Task 1）、`AdaptiveLayout.kGridStartWidth/gridColumnsForWidth`（Task 2）。
- Produces: 行为—桌面且宽 ≥840 时渲染为网格（列数按 `gridColumnsForWidth(width, minItemWidth: itemWidth 的两倍或 220, max: 6)`），否则维持横轨+滚轮。非桌面各宽度渲染与现状一致。

- [ ] **Step 1: 写失败测试** — 创建 `test/ui/widgets/app_horizontal_rail_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/form_factor.dart';
import 'package:shiyin_music/ui/widgets/app_section.dart';

Widget _wrap(Widget child, {Size size = const Size(1200, 800)}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size),
        child: Scaffold(body: child),
      ),
    );

void main() {
  tearDown(() => debugDesktopFormFactorOverride = null);

  Widget rail() => AppHorizontalRail<String>(
        title: '测试轨',
        items: ['a', 'b', 'c'],
        height: 120,
        itemWidth: 100,
        itemBuilder: (_, item) => Text(item),
      );

  testWidgets('桌面窄窗(<840)：保持横轨', (tester) async {
    debugDesktopFormFactorOverride = true;
    await tester.pumpWidget(_wrap(rail(), size: const Size(700, 800)));
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('桌面宽窗(≥840)：转网格', (tester) async {
    debugDesktopFormFactorOverride = true;
    await tester.pumpWidget(_wrap(rail(), size: const Size(1200, 800)));
    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('非桌面同宽：保持横轨（零回归）', (tester) async {
    debugDesktopFormFactorOverride = false;
    await tester.pumpWidget(_wrap(rail(), size: const Size(1200, 800)));
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
  });
}
```

- [ ] **Step 2: RED** — 运行，桌面宽窗用例 FAIL（当前只有 ListView）。

- [ ] **Step 3: 实现** — `app_section.dart` 的 `AppHorizontalRail.build` 改为：

```dart
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final wideDesktop =
            isDesktopFormFactor && constraints.maxWidth >= AdaptiveLayout.kGridStartWidth;
        return Padding(
          padding: EdgeInsets.only(top: topPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: headerPadding ?? padding,
                child: AppSectionHeader(title: title, action: action),
              ),
              const SizedBox(height: 12),
              if (wideDesktop)
                // 桌面宽窗：横轨转网格，列数随宽度收敛（设计 §3/§5）。
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: padding,
                  itemCount: items.length,
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: (itemWidth ?? 110) * 2 + separatorWidth,
                    mainAxisSpacing: separatorWidth,
                    crossAxisSpacing: separatorWidth,
                    mainAxisExtent: height,
                  ),
                  itemBuilder: (context, index) {
                    final child = itemBuilder(context, items[index]);
                    return MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: child,
                    );
                  },
                )
              else
                SizedBox(
                  height: height,
                  child: HorizontalWheelScroll(
                    builder: (context, controller) => ListView.separated(
                      controller: controller,
                      scrollDirection: Axis.horizontal,
                      padding: padding,
                      itemCount: items.length,
                      separatorBuilder: (_, _) =>
                          SizedBox(width: separatorWidth),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final child = itemBuilder(context, item);
                        final sized = itemWidth == null
                            ? child
                            : SizedBox(width: itemWidth, child: child);
                        // 桌面端显示手型光标，增强可点击感知。
                        return MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: sized,
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
```

文件顶部加 `import '../form_factor.dart';`、`import 'adaptive_layout.dart';`（相对 `lib/ui/widgets/`：`../form_factor.dart`、`../adaptive_layout.dart`）、`import 'horizontal_wheel_scroll.dart';`。`AdaptiveLayout.kGridStartWidth` 已在 Task 2 提供。网格的 `maxCrossAxisExtent` 取卡片宽 ×2 + 间距，保证桌面上每行约 3-6 张卡且卡片不比横轨模式大太多；`mainAxisExtent: height` 沿用横轨卡高，杜绝纵横比溢出。

- [ ] **Step 4: GREEN + 回归** — 三用例 PASS；全量测试/analyze 通过。

- [ ] **Step 5: 提交** — `git commit -m "feat(pc): AppHorizontalRail 宽窗网格化并内置滚轮横滚"`

### Task 5: home_page 桌面接入（网格 + 滚轮 + 留白）

**Files:**
- Modify: `lib/ui/pages/home_page.dart`（四处，见各 Step 锚点）

**Interfaces:**
- Consumes: `HorizontalWheelScroll` / `HorizontalWheelPageScroll`、`isDesktopFormFactor`、`AdaptiveLayout.kGridStartWidth`。
- 净增目标 < 80 行。

- [ ] **Step 1: _PlaylistRail 非车机分支网格化 + 滚轮** — 锚点：非车机 `return Padding(...)` 分支（约 :1545-1563，含 `SizedBox(height: 204, child: ListView.separated(...))`）。改为：

```dart
    final isDesktopWide =
        isDesktopFormFactor && size.width >= AdaptiveLayout.kGridStartWidth;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: _SectionHeader(
              title: '推荐歌单',
              action: const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: 12),
          if (isDesktopWide)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 18),
              itemCount: playlists.length,
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                mainAxisSpacing: 16,
                crossAxisSpacing: 14,
                childAspectRatio: 0.60,
              ),
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return _PlaylistCard(
                  playlist: playlist,
                  onTap: () => onTap(playlist),
                );
              },
            )
          else
            SizedBox(
              height: 204,
              child: HorizontalWheelScroll(
                builder: (context, controller) => ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  scrollDirection: Axis.horizontal,
                  itemCount: playlists.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 14),
                  itemBuilder: (context, index) {
                    final playlist = playlists[index];
                    return _PlaylistCard(
                      playlist: playlist,
                      onTap: () => onTap(playlist),
                      width: 128,
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
```

车机分支保持原样（其网格 delegate 与桌面网格数值相同是巧合共存，不做合并以控风险）。文件顶部加 `import '../form_factor.dart';` 与 `import '../adaptive_layout.dart';`、`import '../widgets/horizontal_wheel_scroll.dart';`（若尚未引入）。

- [ ] **Step 2: _RadioStationRail 桌面分支复用 _RadioStationGrid + 滚轮** — 锚点：`class _RadioStationRail`（约 :2223-2258）的 `build`。改为 LayoutBuilder 分支：

```dart
  @override
  Widget build(BuildContext context) {
    if (stations.isEmpty) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 桌面宽窗直接复用车机网格组件（同参数、同卡片），保持视觉一致。
        if (isDesktopFormFactor &&
            constraints.maxWidth >= AdaptiveLayout.kGridStartWidth) {
          return _RadioStationGrid(
            stations: stations,
            loadingStationId: loadingStationId,
            onTap: onTap,
          );
        }
        // 卡片内容高度充足（封面116 + 标题 + 副标题），轨道188彻底杜绝底部溢出且呼吸感匀称。
        return SizedBox(
          height: 188,
          child: HorizontalWheelScroll(
            builder: (context, controller) => ListView.separated(
              controller: controller,
              scrollDirection: Axis.horizontal,
              itemCount: stations.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final station = stations[index];
                return _RadioStationCard(
                  station: station,
                  loading: loadingStationId == station.id,
                  onTap: () => onTap(station),
                );
              },
            ),
          ),
        );
      },
    );
  }
```

（保留原注释；ListView 主体逐行不变，仅外包 HorizontalWheelScroll 与分支。）

- [ ] **Step 3: 猜你喜欢 PageView 滚轮** — 锚点：约 :1152 `SizedBox(height: rowCount * 76.0, child: PageView.builder(controller: _pageController, ...))`。把 PageView 包进 `HorizontalWheelPageScroll`：

```dart
                      SizedBox(
                        height: rowCount * 76.0,
                        child: HorizontalWheelPageScroll(
                          controller: _pageController,
                          child: PageView.builder(
```

（PageView 原参数逐行不动，仅多包一层；补齐对应闭合括号。）

- [ ] **Step 4: 底部留白桌面收窄** — 锚点：约 :502 `const SliverToBoxAdapter(child: SizedBox(height: 166)),` 改为：

```dart
              // 悬浮播放条留白仅手机/平板/车机需要；桌面播放栏占位于骨架底部。
              SliverToBoxAdapter(
                child: SizedBox(height: isDesktopFormFactor ? 24 : 166),
              ),
```

（去掉 const；若桌面收窄导致页面底部过贴，冒烟阶段再调数值。）

- [ ] **Step 5: 验证** — `flutter analyze` 零新增；`flutter test` 全量；`wc -l lib/ui/pages/home_page.dart` 相对改动前净增 < 80。

- [ ] **Step 6: 提交** — `git commit -m "feat(pc): 首页横轨宽窗网格化与滚轮横滚接入"`

### Task 6: rank / search / player 桌面接入

**Files:**
- Modify: `lib/ui/pages/rank_page.dart`、`lib/ui/pages/search_page.dart`、`lib/ui/pages/player_page.dart`

- [ ] **Step 1: rank 新歌推荐网格化 + 滚轮** — 锚点：约 :299-315 `SizedBox(height: 142, child: ListView.separated(...))`（`_NewSongCard` 固定宽 108）。改为 LayoutBuilder 分支：桌面且宽 ≥840 用

```dart
                child: HorizontalWheelScroll(
                  builder: (context, controller) => LayoutBuilder(
```

结构：外层 LayoutBuilder 拿宽度 → `isDesktopFormFactor && w >= AdaptiveLayout.kGridStartWidth` 时渲染：

```dart
GridView.builder(
  shrinkWrap: true,
  physics: const NeverScrollableScrollPhysics(),
  padding: EdgeInsets.zero,
  itemCount: showCount,
  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 120,
    mainAxisExtent: 142,
    mainAxisSpacing: 12,
    crossAxisSpacing: 12,
  ),
  itemBuilder: (context, index) { /* 原 ListView itemBuilder 主体逐行搬入 */ },
)
```

（`showCount` = `songs.length > 10 ? 10 : songs.length`，保持原上限。）非桌面分支：原 ListView 外包 `HorizontalWheelScroll`（controller 由 builder 注入）。文件加 import（form_factor / adaptive_layout / horizontal_wheel_scroll，相对路径 `../`）。

- [ ] **Step 2: search 分类 tab 条滚轮** — 锚点：约 :1025-1042 分类条 `SizedBox(height: 34, child: ListView.separated(...))`。ListView 外包 `HorizontalWheelScroll`（builder 注入 controller），itemBuilder 逐行不动。
- [ ] **Step 3: search 热搜榜 PageView 滚轮** — 锚点：约 :1048 `SizedBox(height: 360, child: PageView.builder(controller: _pageController, ...))`。PageView 外包 `HorizontalWheelPageScroll(controller: _pageController, child: ...)`，参数不动。
- [ ] **Step 4: player_page 海报/歌词 PageView 滚轮** — 锚点：约 :292-294 `NotificationListener<ScrollNotification>(onNotification: ..., child: PageView(controller: _pageController, ...))`。在 NotificationListener 外包一层 `HorizontalWheelPageScroll(controller: _pageController, child: <原 NotificationListener 整体>)`；原结构逐行不动。
- [ ] **Step 5: 验证 + 提交** — analyze/全量测试；`git commit -m "feat(pc): 排行榜/搜索/播放页滚轮横滚与网格接入"`

### Task 7: 快捷键补全 + 音量联动 + 导航语义（TDD）

**Files:**
- Modify: `lib/ui/pages/app_shell.dart`（AppShortcutScope ↑↓ 音量）
- Modify: `lib/controllers/player_controller.dart`（setVolume notifyListeners）
- Modify: `lib/ui/desktop/desktop_player_bar.dart`（音量滑块随 player 同步）
- Modify: `lib/ui/desktop/desktop_shell.dart`（Ctrl+F / Ctrl+1-3 / Enter）
- Modify: `lib/ui/desktop/desktop_sidebar.dart`（Semantics）
- Test: `test/ui/desktop/desktop_shortcut_volume_test.dart`（新建，纯逻辑部分）

**Interfaces:**
- Produces: 快捷键—空格/←→（已有）+ ↑（音量+5%）+ ↓（音量-5%）（全局，输入框聚焦时不拦截）；桌面骨架内 Ctrl+F 打开搜索、Ctrl+1/2/3 切换 推荐/排行榜/电台、Enter 打开播放页（无歌时无操作）；音量变化经 PlayerController.notifyListeners 同步到播放栏滑块。

- [ ] **Step 1: 写失败测试** — `test/ui/desktop/desktop_shortcut_volume_test.dart`：直接测 PlayerController 音量钳制不可行（需音频后端）；改为测 `AppShortcutScope` 的意图映射不可行（私有 Intent）。因此本任务可自动化的是**通知联动**：用 `test/ui/desktop/desktop_player_bar_test.dart` 追加 widget 测试需构造 PlayerController（不可行，同计划 1 结论）。结论：本任务以 `flutter analyze` + 全量回归 + 人工冒烟为主，唯一新增自动化用例为 form_factor/断点已覆盖部分——**无新增测试文件**（如实记录，这是 PlayerController 具体类无接缝的计划内缺口，终审已 triage 到"后续有接缝时补"）。

- [ ] **Step 2: PlayerController.setVolume 通知** — `player_controller.dart` 的 setVolume（计划 1 追加处）改为：

```dart
  /// 设置音量（0.0–1.0），越界值自动夹取。
  /// 音量会被快捷键等非 UI 入口修改，通知监听者以同步播放栏滑块。
  Future<void> setVolume(double value) async {
    await _audioHandler.audioPlayer.setVolume(value.clamp(0.0, 1.0));
    notifyListeners();
  }
```

- [ ] **Step 3: AppShortcutScope ↑↓ 音量** — `app_shell.dart` 的 `AppShortcutScope`：shortcuts map 追加：

```dart
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const _VolumeUpIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const _VolumeDownIntent(),
```

actions map 追加（沿用 `_isFocusInsideInteractiveControl` 守卫）：

```dart
          _VolumeUpIntent: CallbackAction<_VolumeUpIntent>(
            onInvoke: (_) {
              if (!_isFocusInsideInteractiveControl()) {
                player.setVolume((player.volume + 0.05).clamp(0.0, 1.0));
              }
              return null;
            },
          ),
          _VolumeDownIntent: CallbackAction<_VolumeDownIntent>(
            onInvoke: (_) {
              if (!_isFocusInsideInteractiveControl()) {
                player.setVolume((player.volume - 0.05).clamp(0.0, 1.0));
              }
              return null;
            },
          ),
```

文件尾部追加两个 Intent 类（与既有 `_PlayPauseIntent` 同款式）：

```dart
class _VolumeUpIntent extends Intent {
  const _VolumeUpIntent();
}

class _VolumeDownIntent extends Intent {
  const _VolumeDownIntent();
}
```

- [ ] **Step 4: 播放栏音量滑块同步** — `desktop_player_bar.dart` 的 `_VolumeControl`：把 `late double _volume = widget.player.volume.clamp(0.0, 1.0);` 改为拖拽暂存字段 `double? _dragValue;`，build 改为：

```dart
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: widget.player,
      builder: (context, _) {
        // 拖拽中显示拖拽值，其余时刻跟随 player（快捷键/其他入口改动即时同步）。
        final volume =
            (_dragValue ?? widget.player.volume).clamp(0.0, 1.0);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              volume <= 0
                  ? Icons.volume_off_rounded
                  : volume < 0.5
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded,
              size: 20,
              color: colorScheme.onSurfaceVariant,
            ),
            SizedBox(
              width: 96,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: volume,
                  onChanged: (value) {
                    setState(() => _dragValue = value);
                    widget.player.setVolume(value);
                  },
                  onChangeEnd: (value) {
                    widget.player.setVolume(value);
                    setState(() => _dragValue = null);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
```

- [ ] **Step 5: DesktopShell 桌面快捷键** — `desktop_shell.dart`：文件内追加三个 Intent 类与常量 map，`build` 用 `Shortcuts`+`Actions` 包裹既有 `Scaffold`：

```dart
/// 桌面骨架专属快捷键意图。
class _OpenSearchIntent extends Intent {
  const _OpenSearchIntent();
}

class _SelectHomeSectionIntent extends Intent {
  const _SelectHomeSectionIntent(this.index);
  final int index;
}

class _OpenPlayerIntent extends Intent {
  const _OpenPlayerIntent();
}
```

`build` 返回值改为（原 Scaffold 整体作为 child）：

```dart
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _OpenSearchIntent(),
        SingleActivator(LogicalKeyboardKey.digit1, control: true):
            _SelectHomeSectionIntent(0),
        SingleActivator(LogicalKeyboardKey.digit2, control: true):
            _SelectHomeSectionIntent(1),
        SingleActivator(LogicalKeyboardKey.digit3, control: true):
            _SelectHomeSectionIntent(2),
        SingleActivator(LogicalKeyboardKey.enter):
            _OpenPlayerIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter):
            _OpenPlayerIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenSearchIntent: CallbackAction<_OpenSearchIntent>(
            onInvoke: (_) {
              _openSearch(context);
              return null;
            },
          ),
          _SelectHomeSectionIntent:
              CallbackAction<_SelectHomeSectionIntent>(
            onInvoke: (intent) {
              _selectSection((intent as _SelectHomeSectionIntent).index);
              return null;
            },
          ),
          _OpenPlayerIntent: CallbackAction<_OpenPlayerIntent>(
            onInvoke: (_) => _openPlayerPage(context),
          ),
        },
        child: Scaffold(/* 原 Scaffold 代码逐行不动 */),
      ),
    );
```

并把 `_openPlayerPage` 从播放栏逻辑提升到 DesktopShell（新增私有方法，与 `_openSearch` 并列）：

```dart
  void _openPlayerPage(BuildContext context) {
    if (widget.player.currentSong == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(player: widget.player, auth: widget.auth),
      ),
    );
  }
```

import 追加：`import 'package:flutter/services.dart';`（LogicalKeyboardKey）、`import '../pages/player_page.dart';`。文件顶部原有 `../pages/player_page.dart` 若已存在则不重复。

- [ ] **Step 6: 导航 Semantics** — `desktop_sidebar.dart` 的 `_NavItemTile.build`：`MouseRegion` 内、`GestureDetector` 外包一层：

```dart
      child: Semantics(
        button: true,
        onTap: widget.onTap,
        child: GestureDetector(
```

（闭合括号对应补齐；视觉零变化。）

- [ ] **Step 7: 验证 + 提交** — `flutter analyze` 零新增；`flutter test` 全量；`git commit -m "feat(pc): 桌面快捷键补全与音量联动同步"`

### Task 8: Android-only 功能桌面降级排查

**Files:**
- 视排查结果：`lib/ui/pages/settings_page.dart`、`lib/ui/pages/player_page.dart` 等入口处的小修

**排查清单（服务 → 既有守卫 → 应达标的桌面表现）：**

| 功能 | 守卫来源 | 桌面应表现 |
|---|---|---|
| 蓝牙歌词 | `bluetooth_lyrics_service.dart:16`（Android-only） | 入口隐藏或置灰 |
| 超级歌词 | `super_lyric_service.dart:38` | 同上 |
| 音频特效/EQ | `audio_effects_service.dart:66` | 入口隐藏；EQ 面板桌面不可达 |
| 桌面歌词(Android 版) | `desktop_lyrics_service.dart:73` | 桌面入口由计划 3 重建，本任务确保旧 Android 入口不显示 |
| 设备信息/自更新 | `device_info_service.dart:14`、`app_update_service.dart:23` | 自更新检查跳过；无崩溃 |

- [ ] **Step 1: 审计** — 对每个服务，grep 其在 `lib/ui/` 的引用点（如 `grep -rn "BluetoothLyrics\|SuperLyric\|audioEffects\|AudioEffects\|appUpdate\|AppUpdate" lib/ui/`），核对入口（设置项/按钮/面板）是否已被 `isXxxSupported` 类守卫包裹。
- [ ] **Step 2: 修复未守卫入口** — 决策规则：入口未守卫时，在**入口渲染处**加该服务已有的 support getter 判断隐藏（例：

```dart
if (service.isXxxSupported) SettingsTile(...),
```

集合/列表场景用 `...if (cond) [tile]` 展开）。禁止改动服务实现本身；禁止为桌面新增功能。
- [ ] **Step 3: 记录** — 每个功能的结论（已守卫/已修复/桌面不适用）写进任务报告。
- [ ] **Step 4: 验证 + 提交** — analyze/全量测试；`git commit -m "fix(pc): Android-only 功能桌面入口降级守卫"`（若无修复项则不提交，报告说明即可）。

---

## Self-Review 记录

- 规格覆盖：设计 §3（Task 2 常量）、§5 滚轮+网格（Task 3-6）、§9 快捷键（Task 7）、§9 降级（Task 8）、计划 1 终审 carry-in（音量同步 Task 7、Semantics Task 7、gridColumnsForWidth 加固 Task 2、_handleHomeTabSwitch 钳制 Task 2、播放栏冗余 AnimatedBuilder 已在计划 1 修复提交中删除）。
- 已知不测项：Task 7 无新增自动化测试（PlayerController 具体类无接缝，计划内缺口，终审 triage 记录在案）；滚轮行为由 Task 3 自动化覆盖，页面接入点靠 analyze+全量回归+最终人工冒烟。
- 类型一致性：`HorizontalWheelScroll(builder:)`、`HorizontalWheelPageScroll(controller:, child:)`、`AdaptiveLayout.kGridStartWidth/kGridHorizontalPadding`、`debugDesktopFormFactorOverride` 各任务 Consumes/Produces 与实现一致。
