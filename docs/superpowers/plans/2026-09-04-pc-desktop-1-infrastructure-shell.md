# 时音 PC 桌面适配 · 计划 1/3：基础设施与桌面骨架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows 桌面形态下将应用切换为"左侧导航栏 + 内容区 + 底部播放栏"的桌面骨架，含窗口管理（最小/默认/记忆尺寸），车机与手机布局零改动。

**Architecture:** 平台判定（`isDesktopFormFactor`）在 `AppShell._buildShell` 最顶端分流到新的 `DesktopShell`；桌面骨架复用 `HomePage` 现有的 `sectionIndex`/`onTabSwitch` 外部 tab 控制接口。断点工具、播放栏、侧栏均为独立新文件。

**Tech Stack:** Flutter (Material) + window_manager + shared_preferences；状态沿用 ChangeNotifier/AnimatedBuilder 模式。

**设计文档:** `docs/superpowers/specs/2026-09-04-pc-desktop-adaptation-design.md`

**后续计划:** 计划 2/3 = 横轨网格化+滚轮+快捷键+降级清单；计划 3/3 = 桌面歌词+托盘+设置页补充项（窗口重置入口在计划 3 与托盘开关一并加入设置页）。

## Global Constraints

- **禁止修改窄屏/车机路径行为**：`app_shell.dart` 车机分支、`_FloatingBottomBar`、`_CenterDisc`、MiniPlayer 的行为一律不变；仅允许行为中性重构（本计划的 LazyIndexedStack/队列面板抽取），重构后窄屏与车机表现必须与重构前一致。
- **平台判定收敛**：业务/UI 代码只允许引用 `form_factor.dart` 的 `isDesktopFormFactor`，禁止在页面里散落 `Platform.isWindows`（`main.dart`/`player_controller` 等已有的历史 Platform 判断不动）。
- **文件长度**：新建文件 ≤400 行；`home_page.dart`（2941 行）等已超长文件**禁止加长**，本计划不修改 `home_page.dart`。
- 断点值（逻辑像素）：compact <600 / medium 600–839 / expanded 840–1199 / large 1200–1599 / expandedDesktop ≥1600；横轨转网格起点 ≥840 且仅桌面形态。
- 窗口：最小 960×600，默认 1280×800，标题"时音"。
- 每个任务结束：`flutter analyze` 无新增告警、`flutter test` 全绿（以任务 1 的基线为准）、按任务内消息提交。
- 提交信息风格沿用仓库惯例：`type(scope): 中文描述`。
- 工作分支：`feature/pc-desktop-adaptation`（已存在）。

---

## File Structure

| 操作 | 路径 | 职责 |
|---|---|---|
| Create | `lib/ui/form_factor.dart` | 桌面形态判定（唯一入口） |
| Modify | `lib/ui/adaptive_layout.dart` | 追加 `WindowWidthClass` 与列数工具 |
| Test | `test/ui/adaptive_width_class_test.dart` | 断点纯函数测试 |
| Modify | `pubspec.yaml` | 新增 window_manager 依赖 |
| Create | `lib/ui/desktop/desktop_window.dart` | 窗口初始化 + 几何记忆 |
| Test | `test/ui/desktop/window_geometry_store_test.dart` | 几何存取测试 |
| Modify | `lib/main.dart` | main() 中初始化桌面窗口 |
| Create | `lib/ui/widgets/lazy_indexed_stack.dart` | 从 app_shell 抽取的懒构建 IndexedStack |
| Modify | `lib/ui/pages/app_shell.dart` | 改用共享 LazyIndexedStack；顶部加桌面分流 |
| Create | `lib/ui/desktop/desktop_sidebar.dart` | 桌面侧栏（纯展示组件） |
| Test | `test/ui/desktop/desktop_sidebar_test.dart` | 侧栏交互测试 |
| Create | `lib/ui/widgets/queue_sheet.dart` | 从 mini_player 抽取的播放队列面板 |
| Modify | `lib/ui/widgets/mini_player.dart` | 委托给共享队列面板（删私有副本） |
| Modify | `lib/controllers/player_controller.dart` | 新增 volume/setVolume |
| Create | `lib/ui/desktop/desktop_player_bar.dart` | 底部播放栏 |
| Test | `test/ui/desktop/desktop_player_bar_test.dart` | 时间格式化测试 |
| Create | `lib/ui/desktop/desktop_shell.dart` | 桌面骨架（分区状态 + 组装） |

---

### Task 1: 窗口宽度断点工具（TDD）

**Files:**
- Modify: `lib/ui/adaptive_layout.dart`（`AdaptiveLayout` 类内追加）
- Test: `test/ui/adaptive_width_class_test.dart`

**Interfaces:**
- Produces: `enum WindowWidthClass { compact, medium, expanded, large, expandedDesktop }`；`AdaptiveLayout.widthClassFor(double width) → WindowWidthClass`；`AdaptiveLayout.gridColumnsForWidth(double width, {double minItemWidth = 200, int min = 2, int max = 6}) → int`。计划 2 的横轨网格化依赖这两个签名。

- [ ] **Step 1: 建立基线**

```bash
cd "D:\AllCode\flutter\kgka_Music_hl_automotive"
flutter analyze
flutter test
```
记录两者的现有输出作为基线（后续任务只要求"无新增"告警/失败）。

- [ ] **Step 2: 写失败测试**

创建 `test/ui/adaptive_width_class_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/adaptive_layout.dart';

void main() {
  group('AdaptiveLayout.widthClassFor', () {
    test('边界值分级正确', () {
      expect(AdaptiveLayout.widthClassFor(599), WindowWidthClass.compact);
      expect(AdaptiveLayout.widthClassFor(600), WindowWidthClass.medium);
      expect(AdaptiveLayout.widthClassFor(839), WindowWidthClass.medium);
      expect(AdaptiveLayout.widthClassFor(840), WindowWidthClass.expanded);
      expect(AdaptiveLayout.widthClassFor(1199), WindowWidthClass.expanded);
      expect(AdaptiveLayout.widthClassFor(1200), WindowWidthClass.large);
      expect(AdaptiveLayout.widthClassFor(1599), WindowWidthClass.large);
      expect(AdaptiveLayout.widthClassFor(1600),
          WindowWidthClass.expandedDesktop);
    });
  });

  group('AdaptiveLayout.gridColumnsForWidth', () {
    test('低于网格起点返回 min', () {
      expect(AdaptiveLayout.gridColumnsForWidth(839), 2);
    });

    test('按最小项宽计算并夹在 [min, max]', () {
      // (840 - 32) ~/ 200 = 4
      expect(AdaptiveLayout.gridColumnsForWidth(840), 4);
      // 1600 宽下 (1600-32)~/200 = 7 → 被 max=6 截断
      expect(AdaptiveLayout.gridColumnsForWidth(1600), 6);
      // minItemWidth 放大后列数减少并落到 min
      expect(
        AdaptiveLayout.gridColumnsForWidth(840, minItemWidth: 500),
        2,
      );
      expect(
        AdaptiveLayout.gridColumnsForWidth(
          840,
          minItemWidth: 500,
          min: 3,
        ),
        3,
      );
    });
  });
}
```

- [ ] **Step 3: 运行测试确认失败**

```bash
flutter test test/ui/adaptive_width_class_test.dart
```
预期：FAIL（`WindowWidthClass` 未定义）。

- [ ] **Step 4: 实现**

在 `lib/ui/adaptive_layout.dart` 的 `AdaptiveLayout` 类**之前**（文件级）追加枚举，在类内追加两个静态方法（`gridColumnsFor` 之后）：

```dart
/// 窗口宽度分级（逻辑像素），阈值与设计文档 §3 一致。
enum WindowWidthClass { compact, medium, expanded, large, expandedDesktop }
```

```dart
  /// 按宽度返回窗口分级（PC 适配断点体系入口）。
  static WindowWidthClass widthClassFor(double width) {
    if (width >= 1600) return WindowWidthClass.expandedDesktop;
    if (width >= 1200) return WindowWidthClass.large;
    if (width >= 840) return WindowWidthClass.expanded;
    if (width >= 600) return WindowWidthClass.medium;
    return WindowWidthClass.compact;
  }

  /// 按宽度与最小项宽计算网格列数，结果夹在 [min]–[max]。
  ///
  /// 32 为两侧内容边距预留。
  static int gridColumnsForWidth(
    double width, {
    double minItemWidth = 200,
    int min = 2,
    int max = 6,
  }) {
    final columns = ((width - 32) ~/ minItemWidth).clamp(min, max);
    return columns;
  }
```

- [ ] **Step 5: 测试转绿 + 静态检查**

```bash
flutter test test/ui/adaptive_width_class_test.dart
flutter analyze
```
预期：测试 PASS；analyze 无新增告警。

- [ ] **Step 6: 提交**

```bash
git add lib/ui/adaptive_layout.dart test/ui/adaptive_width_class_test.dart
git commit -m "feat(pc): 新增窗口宽度断点分级与网格列数工具"
```

---

### Task 2: 桌面形态判定 + window_manager 窗口管理

**Files:**
- Create: `lib/ui/form_factor.dart`
- Modify: `pubspec.yaml`（dependencies 内追加）
- Create: `lib/ui/desktop/desktop_window.dart`
- Modify: `lib/main.dart`（main() 内追加一行调用 + import）
- Test: `test/ui/desktop/window_geometry_store_test.dart`

**Interfaces:**
- Produces: `bool isDesktopFormFactor`（顶层 final，全项目唯一平台判定入口）；`DesktopWindow.ensureInitialized()`（main 调用）；`DesktopWindowGeometry.load/save/reset`（SharedPreferences 持久化，计划 3 的设置页"重置窗口"将复用 `reset`）。

- [ ] **Step 1: 添加依赖**

`pubspec.yaml` 的 `dependencies:` 中 `url_launcher: ^6.3.2` 之后追加：

```yaml
  window_manager: ^0.4.3
```

然后：

```bash
flutter pub get
```
预期：解析成功。若 ^0.4.3 解析失败，运行 `flutter pub outdated --no-dev-dependencies` 查看 window_manager 最新稳定版并改用其 0.4/0.5 系列约束，保持 API 兼容（本计划仅用 ensureInitialized/waitUntilReadyToShow/setTitle/setMinimumSize/addListener）。

- [ ] **Step 2: 写几何存取的失败测试**

创建 `test/ui/desktop/window_geometry_store_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shiyin_music/ui/desktop/desktop_window.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('无存储值时返回 null', () async {
    final prefs = await SharedPreferences.getInstance();
    expect(DesktopWindowGeometry.load(prefs), isNull);
  });

  test('save 后 load 返回原值', () async {
    final prefs = await SharedPreferences.getInstance();
    const geometry = DesktopWindowGeometry(
      left: 120.0,
      top: 80.0,
      width: 1280.0,
      height: 800.0,
    );
    await geometry.save(prefs);
    expect(DesktopWindowGeometry.load(prefs), geometry);
  });

  test('非法尺寸被拒绝（小于最小窗口视为无效）', () async {
    final prefs = await SharedPreferences.getInstance();
    const bad = DesktopWindowGeometry(
      left: 0,
      top: 0,
      width: 320.0,
      height: 200.0,
    );
    await bad.save(prefs);
    expect(DesktopWindowGeometry.load(prefs), isNull);
  });

  test('reset 清空存储', () async {
    final prefs = await SharedPreferences.getInstance();
    const geometry = DesktopWindowGeometry(
      left: 120.0,
      top: 80.0,
      width: 1280.0,
      height: 800.0,
    );
    await geometry.save(prefs);
    await DesktopWindowGeometry.reset(prefs);
    expect(DesktopWindowGeometry.load(prefs), isNull);
  });
}
```

- [ ] **Step 3: 运行确认失败**

```bash
flutter test test/ui/desktop/window_geometry_store_test.dart
```
预期：FAIL（文件不存在）。

- [ ] **Step 4: 实现 form_factor.dart**

创建 `lib/ui/form_factor.dart`：

```dart
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// 桌面形态判定：仅由操作系统决定，与窗口大小无关。
///
/// 车机/平板/手机均为 Android，恒为 false，走既有布局路径；
/// Windows/macOS/Linux 视为桌面，启用桌面 Shell。
/// 全项目唯一的桌面平台判定入口，页面代码不得散落 Platform.isWindows。
final bool isDesktopFormFactor = !kIsWeb &&
    (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
```

- [ ] **Step 5: 实现 desktop_window.dart**

创建 `lib/ui/desktop/desktop_window.dart`：

```dart
import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../form_factor.dart';

/// 桌面窗口初始化与几何记忆。
///
/// 仅在桌面形态生效（[isDesktopFormFactor]），其余平台直接返回。
class DesktopWindow {
  DesktopWindow._();

  static const Size kMinSize = Size(960, 600);
  static const Size kDefaultSize = Size(1280, 800);
  static const String kWindowTitle = '时音';

  /// 初始化窗口：恢复上次几何 → 应用最小尺寸 → 显示窗口。
  /// 必须在 runApp 之前 await 调用。
  static Future<void> ensureInitialized() async {
    if (!isDesktopFormFactor) return;
    await windowManager.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final geometry = DesktopWindowGeometry.load(prefs);
    final options = WindowOptions(
      size: geometry?.size ?? kDefaultSize,
      position: geometry?.offset,
      minimumSize: kMinSize,
      title: kWindowTitle,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    _saver = _WindowGeometrySaver(prefs);
    windowManager.addListener(_saver!);
  }

  static _WindowGeometrySaver? _saver;
}

/// 窗口几何（位置 + 尺寸）的持久化。
class DesktopWindowGeometry {
  const DesktopWindowGeometry({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  Size get size => Size(width, height);
  Offset get offset => Offset(left, top);

  static const String _kLeft = 'window.geometry.left';
  static const String _kTop = 'window.geometry.top';
  static const String _kWidth = 'window.geometry.width';
  static const String _kHeight = 'window.geometry.height';

  /// 读取持久化几何；缺项或尺寸非法（小于最小窗口）时返回 null。
  static DesktopWindowGeometry? load(SharedPreferences prefs) {
    final left = prefs.getDouble(_kLeft);
    final top = prefs.getDouble(_kTop);
    final width = prefs.getDouble(_kWidth);
    final height = prefs.getDouble(_kHeight);
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (width < DesktopWindow.kMinSize.width ||
        height < DesktopWindow.kMinSize.height) {
      return null;
    }
    return DesktopWindowGeometry(
      left: left,
      top: top,
      width: width,
      height: height,
    );
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setDouble(_kLeft, left);
    await prefs.setDouble(_kTop, top);
    await prefs.setDouble(_kWidth, width);
    await prefs.setDouble(_kHeight, height);
  }

  /// 清空持久化几何（下次启动回落到默认尺寸）。
  static Future<void> reset(SharedPreferences prefs) async {
    await prefs.remove(_kLeft);
    await prefs.remove(_kTop);
    await prefs.remove(_kWidth);
    await prefs.remove(_kHeight);
  }
}

/// 监听窗口移动/缩放，防抖后持久化几何。
class _WindowGeometrySaver extends WindowListener {
  _WindowGeometrySaver(this._prefs);

  final SharedPreferences _prefs;
  Timer? _debounce;

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      final bounds = await windowManager.getBounds();
      await DesktopWindowGeometry(
        left: bounds.left,
        top: bounds.top,
        width: bounds.width,
        height: bounds.height,
      ).save(_prefs);
    });
  }
}
```

注意：`Size`/`Offset` 来自 window_manager 重新导出的 dart:ui 类型（`package:window_manager/window_manager.dart` 已导出），无需额外 import。

- [ ] **Step 6: 测试转绿**

```bash
flutter test test/ui/desktop/window_geometry_store_test.dart
```
预期：4 个测试 PASS。

- [ ] **Step 7: main.dart 接入**

`lib/main.dart`：

import 区（`import 'ui/adaptive_layout.dart';` 之后）追加：

```dart
import 'ui/desktop/desktop_window.dart';
```

`main()` 中 `final themeController = ThemeController();` 之前插入：

```dart
  // 桌面形态（Windows 等）：初始化窗口尺寸/最小尺寸/几何记忆。
  // 必须在 runApp 之前完成，避免首帧以错误尺寸渲染。
  await DesktopWindow.ensureInitialized();
```

- [ ] **Step 8: 静态检查 + 全量测试 + 提交**

```bash
flutter analyze
flutter test
```
预期：均不劣于 Task 1 基线。

```bash
git add pubspec.yaml pubspec.lock lib/ui/form_factor.dart lib/ui/desktop/desktop_window.dart lib/main.dart test/ui/desktop/window_geometry_store_test.dart
git commit -m "feat(pc): 桌面形态判定与窗口管理（最小/默认/记忆尺寸）"
```

---

### Task 3: 抽取共享 LazyIndexedStack（行为中性重构）

**Files:**
- Create: `lib/ui/widgets/lazy_indexed_stack.dart`
- Modify: `lib/ui/pages/app_shell.dart`（替换 2 处使用 + 删除私有类 + 加 import）

**Interfaces:**
- Produces: `LazyIndexedStack({required int index, required List<Widget> children})`（`lib/ui/widgets/lazy_indexed_stack.dart`），DesktopShell（Task 7）与 app_shell 共用。

- [ ] **Step 1: 创建共享组件**

创建 `lib/ui/widgets/lazy_indexed_stack.dart`，内容为 `app_shell.dart:650-690` 的私有类原样搬迁并公开（保留原注释）：

```dart
import 'package:flutter/material.dart';

/// 只在首次被选中时才构建对应 child 的 [IndexedStack]。
///
/// 普通 IndexedStack 会一次性构建全部 children，导致所有页面
/// 都在 initState 中发起网络请求。这里通过懒构建
/// 保证只有被访问过的 tab 才会真正初始化，避免重复请求与重复监听。
class LazyIndexedStack extends StatefulWidget {
  const LazyIndexedStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  State<LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<LazyIndexedStack> {
  final _built = <int>{};

  @override
  void initState() {
    super.initState();
    _built.add(widget.index);
  }

  @override
  void didUpdateWidget(covariant LazyIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _built.add(widget.index);
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: widget.index,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          _built.contains(i) ? widget.children[i] : const SizedBox.shrink(),
      ],
    );
  }
}
```

- [ ] **Step 2: app_shell.dart 切换到共享组件**

`lib/ui/pages/app_shell.dart` 四处改动：

1. import 区（`import '../widgets/mini_player.dart';` 之后）追加：

```dart
import '../widgets/lazy_indexed_stack.dart';
```

2. `_LazyIndexedStack(` 两处调用（车机分支 `:155` 附近、普通布局 `:212` 附近）改名 `LazyIndexedStack(`。
3. 删除文件末尾的私有类 `/// 只在首次被选中时才构建对应 child 的 [IndexedStack]。` 起的 `_LazyIndexedStack` + `_LazyIndexedStackState` 整段（`:650-690` 附近）。

- [ ] **Step 3: 验证与提交**

```bash
flutter analyze
flutter test
```
预期：与基线一致（重构零行为变化）。

```bash
git add lib/ui/widgets/lazy_indexed_stack.dart lib/ui/pages/app_shell.dart
git commit -m "refactor(ui): 抽取共享 LazyIndexedStack 供桌面骨架复用"
```

---

### Task 4: 抽取共享播放队列面板 + PlayerController 音量 API

**Files:**
- Create: `lib/ui/widgets/queue_sheet.dart`
- Modify: `lib/ui/widgets/mini_player.dart`（删除私有队列实现，改为委托）
- Modify: `lib/controllers/player_controller.dart`（追加 volume API，`:306` 附近 getter 区）

**Interfaces:**
- Produces: `Future<void> showQueueSheet(BuildContext context, PlayerController player)`（`lib/ui/widgets/queue_sheet.dart`）；`PlayerController.volume → double`、`PlayerController.setVolume(double value) → Future<void>`。播放栏（Task 6）依赖这两者。

- [ ] **Step 1: 创建 queue_sheet.dart**

创建 `lib/ui/widgets/queue_sheet.dart`：将 `mini_player.dart` 的 `_showQueue`（`:49-146`）、`_removeFromQueue`（`:149-170`）、`_clearQueue`（`:173-179`）与 `_QueueTile`（`:362-463`）**原样**搬迁，合并为：

```dart
import 'package:flutter/material.dart';

import '../../controllers/player_controller.dart';
import '../../models/music_models.dart';
import 'artwork.dart';
import 'toast.dart';

/// 弹出播放队列面板（底部弹层）。
///
/// 从 MiniPlayer 抽取共享：桌面播放栏（desktop_player_bar.dart）复用同一面板，
/// 行为与原有 MiniPlayer 完全一致。
Future<void> showQueueSheet(
  BuildContext context,
  PlayerController player,
) {
  return showModalBottomSheet<void>(/* ← 原 _showQueue 的 showModalBottomSheet 实参整体搬入 */);
}
```

要求：
- `_showQueue` 内的 `showModalBottomSheet<void>(...)` 调用整体成为 `showQueueSheet` 的返回体；builder 闭包内的 `player`/`_removeFromQueue`/`_clearQueue` 引用改为顶层函数 `removeFromQueue(sheetContext, player, index)` / `clearQueue(sheetContext, player)`（原私有方法加 `player` 参数，函数体逐行不变）。
- `_QueueTile` 改为公开 `QueueTile`（字段、构建逻辑逐行不变）。

- [ ] **Step 2: mini_player.dart 委托**

`lib/ui/widgets/mini_player.dart`：

1. import 区追加 `import 'queue_sheet.dart';`，删除不再使用的 `import '../../models/music_models.dart';`（Song 仅被搬走的 `_QueueTile` 使用，`_MiniPlayerContent` 用的是具体 `song.title/.artist/.coverUrl` 动态成员，无直接 Song 类型引用——若 analyze 报 unused_import 则删，仍需要则保留）与 `import 'toast.dart';`（Toast 仅被搬走的 `_clearQueue` 使用；若 analyze 报 unused 则删）。
2. `:42` `onShowQueue: () => _showQueue(context)` 改为 `onShowQueue: () => showQueueSheet(context, player)`。
3. 删除 `_showQueue`、`_removeFromQueue`、`_clearQueue`、`_QueueTile` 四段私有实现（已搬至 queue_sheet.dart）。

- [ ] **Step 3: PlayerController 音量 API**

`lib/controllers/player_controller.dart`：在 `bool get isScrubbing => _isScrubbing;`（`:306` 附近）之后追加：

```dart
  /// 当前音量（0.0–1.0）。桌面播放栏音量滑杆使用。
  double get volume => _audioHandler.audioPlayer.volume;

  /// 设置音量（0.0–1.0），越界值自动夹取。
  Future<void> setVolume(double value) =>
      _audioHandler.audioPlayer.setVolume(value.clamp(0.0, 1.0));
```

- [ ] **Step 4: 验证与提交**

```bash
flutter analyze
flutter test
```
预期：与基线一致（纯搬迁 + 纯新增 API，无行为变化）。

```bash
git add lib/ui/widgets/queue_sheet.dart lib/ui/widgets/mini_player.dart lib/controllers/player_controller.dart
git commit -m "refactor(ui): 抽取共享播放队列面板并补齐播放器音量 API"
```

---

### Task 5: 桌面侧栏（TDD）

**Files:**
- Create: `lib/ui/desktop/desktop_sidebar.dart`
- Test: `test/ui/desktop/desktop_sidebar_test.dart`

**Interfaces:**
- Produces（Task 7 依赖的精确签名）:
  - `class DesktopNavItem { const DesktopNavItem({required this.icon, required this.activeIcon, required this.label, this.showDividerAbove = false}); final IconData icon; final IconData activeIcon; final String label; final bool showDividerAbove; }`
  - `class DesktopSidebar extends StatelessWidget { const DesktopSidebar({super.key, required this.items, required this.selectedIndex, required this.onSelect, required this.onSearch}); }`
  - `selectedIndex` 为 `items` 下标（0-based）；`onSelect(int index)`；`onSearch` 为搜索胶囊点击回调。

- [ ] **Step 1: 写失败测试**

创建 `test/ui/desktop/desktop_sidebar_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/desktop_sidebar.dart';

void main() {
  const items = [
    DesktopNavItem(icon: Icons.explore_outlined, activeIcon: Icons.explore_rounded, label: '推荐'),
    DesktopNavItem(icon: Icons.leaderboard_outlined, activeIcon: Icons.leaderboard_rounded, label: '排行榜'),
    DesktopNavItem(
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings_rounded,
      label: '设置',
      showDividerAbove: true,
    ),
  ];

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('点击条目回调对应下标', (tester) async {
    final selected = <int>[];
    await tester.pumpWidget(wrap(DesktopSidebar(
      items: items,
      selectedIndex: 0,
      onSelect: selected.add,
      onSearch: () {},
    )));

    await tester.tap(find.text('排行榜'));
    expect(selected, [1]);
  });

  testWidgets('选中项与悬停样式渲染且搜索可点', (tester) async {
    var searched = false;
    await tester.pumpWidget(wrap(DesktopSidebar(
      items: items,
      selectedIndex: 2,
      onSelect: (_) {},
      onSearch: () => searched = true,
    )));

    expect(find.text('搜索音乐'), findsOneWidget);
    await tester.tap(find.text('搜索音乐'));
    expect(searched, isTrue);
  });
}
```

- [ ] **Step 2: 运行确认失败**

```bash
flutter test test/ui/desktop/desktop_sidebar_test.dart
```
预期：FAIL（文件不存在）。

- [ ] **Step 3: 实现**

创建 `lib/ui/desktop/desktop_sidebar.dart`：

```dart
import 'package:flutter/material.dart';

/// 侧栏条目描述。[showDividerAbove] 为 true 时在该条目上方加分隔线
/// （用于把"设置"与导航区隔开）。
class DesktopNavItem {
  const DesktopNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.showDividerAbove = false,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool showDividerAbove;
}

/// 桌面侧栏：顶部品牌 + 搜索胶囊 + 导航条目。
///
/// 纯展示组件：选中态与回调全部由父级（DesktopShell）持有。
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.onSearch,
  });

  final List<DesktopNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      width: 208,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.asset(
                    'lib/assets/logo.png',
                    width: 26,
                    height: 26,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '时音',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w900),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: _SearchPill(
              isDark: isDark,
              colorScheme: colorScheme,
              onTap: onSearch,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              children: [
                for (final (index, item) in items.indexed) ...[
                  if (item.showDividerAbove)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Divider(
                        height: 1,
                        thickness: 1,
                        color: colorScheme.outlineVariant.withValues(alpha: .4),
                      ),
                    ),
                  _NavItemTile(
                    item: item,
                    selected: index == selectedIndex,
                    colorScheme: colorScheme,
                    onTap: () => onSelect(index),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchPill extends StatelessWidget {
  const _SearchPill({
    required this.isDark,
    required this.colorScheme,
    required this.onTap,
  });

  final bool isDark;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(21),
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest
                .withValues(alpha: isDark ? 1 : .54),
            borderRadius: BorderRadius.circular(21),
            border: Border.all(
              color: colorScheme.outlineVariant
                  .withValues(alpha: isDark ? .85 : .45),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.search_rounded,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                '搜索音乐',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItemTile extends StatefulWidget {
  const _NavItemTile({
    required this.item,
    required this.selected,
    required this.colorScheme,
    required this.onTap,
  });

  final DesktopNavItem item;
  final bool selected;
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  State<_NavItemTile> createState() => _NavItemTileState();
}

class _NavItemTileState extends State<_NavItemTile> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final foreground = selected
        ? widget.colorScheme.primary
        : widget.colorScheme.onSurfaceVariant;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          height: 44,
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? widget.colorScheme.primary.withValues(alpha: .12)
                : _hovering
                    ? widget.colorScheme.surfaceContainerHigh
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                selected ? widget.item.activeIcon : widget.item.icon,
                size: 22,
                color: foreground,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: 测试转绿 + 提交**

```bash
flutter test test/ui/desktop/desktop_sidebar_test.dart
flutter analyze
```
预期：PASS、无新增告警。

```bash
git add lib/ui/desktop/desktop_sidebar.dart test/ui/desktop/desktop_sidebar_test.dart
git commit -m "feat(pc): 桌面侧栏组件（品牌/搜索胶囊/导航条目）"
```

---

### Task 6: 底部播放栏（TDD）

**Files:**
- Create: `lib/ui/desktop/desktop_player_bar.dart`
- Test: `test/ui/desktop/desktop_player_bar_test.dart`

**Interfaces:**
- Consumes: `showQueueSheet(context, player)`（Task 4）、`player.volume`/`player.setVolume`（Task 4）、`player.positionListenable`（现有）、`Artwork`、`PlayerPage(player:, auth:)`。
- Produces: `class DesktopPlayerBar extends StatelessWidget { const DesktopPlayerBar({super.key, required this.player, required this.auth}); }`；顶层纯函数 `String formatDuration(Duration d)`（测试与播放页复用）。

- [ ] **Step 1: 写失败测试**

创建 `test/ui/desktop/desktop_player_bar_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shiyin_music/ui/desktop/desktop_player_bar.dart';

void main() {
  group('formatDuration', () {
    test('分秒补零', () {
      expect(formatDuration(Duration.zero), '00:00');
      expect(formatDuration(const Duration(seconds: 65)), '01:05');
      expect(formatDuration(const Duration(minutes: 9, seconds: 9)), '09:09');
    });
    test('超过一小时显示小时位', () {
      expect(
        formatDuration(const Duration(hours: 1, minutes: 1, seconds: 15)),
        '1:01:15',
      );
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

```bash
flutter test test/ui/desktop/desktop_player_bar_test.dart
```
预期：FAIL。

- [ ] **Step 3: 实现**

创建 `lib/ui/desktop/desktop_player_bar.dart`：

```dart
import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/player_controller.dart';
import '../pages/player_page.dart';
import '../widgets/artwork.dart';
import '../widgets/queue_sheet.dart';

/// 秒数 → `mm:ss`（≥1h 时 `h:mm:ss`）。
String formatDuration(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 桌面底部播放栏：封面/曲目信息 + 播放控制 + 进度 + 音量 + 队列。
///
/// 无歌曲时保持占位布局（高度稳定，不随播放状态跳变）。
/// 桌面歌词开关按钮由计划 3 在本文件追加。
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({
    super.key,
    required this.player,
    required this.auth,
  });

  final PlayerController player;
  final AuthController auth;

  void _openPlayerPage(BuildContext context) {
    if (player.currentSong == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(player: player, auth: auth),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final song = player.currentSong;
        return Container(
          height: 72,
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E2433) : Colors.white,
            border: Border(
              top: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: .5),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              const SizedBox(width: 12),
              // 封面 + 曲目信息：点击进入播放页
              InkWell(
                onTap: () => _openPlayerPage(context),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Artwork(
                        url: song?.coverUrl,
                        size: 48,
                        borderRadius: 8,
                      ),
                      const SizedBox(width: 12),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              song?.title ?? '尚未播放',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: song == null
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              song?.artist ?? '去挑一首喜欢的歌吧',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              // 播放控制
              IconButton(
                tooltip: '上一首',
                onPressed: song == null ? null : player.previous,
                icon: const Icon(Icons.skip_previous_rounded, size: 28),
                color: colorScheme.onSurface,
              ),
              const SizedBox(width: 4),
              AnimatedBuilder(
                animation: player,
                builder: (context, _) {
                  final playing = player.isPlaying;
                  return IconButton(
                    tooltip: playing ? '暂停' : '播放',
                    onPressed: player.isPreparing || song == null
                        ? null
                        : player.togglePlay,
                    icon: Icon(
                      playing
                          ? Icons.pause_circle_rounded
                          : Icons.play_circle_rounded,
                      size: 40,
                    ),
                    color: colorScheme.primary,
                  );
                },
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '下一首',
                onPressed: song == null ? null : player.next,
                icon: const Icon(Icons.skip_next_rounded, size: 28),
                color: colorScheme.onSurface,
              ),
              const Spacer(),
              // 进度区（拖拽中显示拖拽位置，松手 seek）
              if (song != null) ...[
                _ProgressBar(player: player),
                const SizedBox(width: 16),
              ],
              // 音量
              const SizedBox(width: 8),
              _VolumeControl(player: player),
              const SizedBox(width: 8),
              // 队列
              IconButton(
                tooltip: '播放队列',
                onPressed: song == null
                    ? null
                    : () => showQueueSheet(context, player),
                icon: const Icon(Icons.queue_music_rounded, size: 26),
                color: colorScheme.onSurface,
              ),
              const SizedBox(width: 12),
            ],
          ),
        );
      },
    );
  }
}

class _ProgressBar extends StatefulWidget {
  const _ProgressBar({required this.player});

  final PlayerController player;

  @override
  State<_ProgressBar> createState() => _ProgressBarState();
}

class _ProgressBarState extends State<_ProgressBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.player.positionListenable,
      builder: (context, position, _) {
        final durationMs = widget.player.duration.inMilliseconds;
        final progress = _dragValue ??
            (durationMs > 0
                ? (position.inMilliseconds / durationMs).clamp(0.0, 1.0)
                : 0.0);
        final shownPosition = _dragValue != null && durationMs > 0
            ? Duration(milliseconds: (durationMs * _dragValue!).round())
            : position;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatDuration(shownPosition),
              style: TextStyle(
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(
              width: 280,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape:
                      const RoundSliderOverlayShape(overlayRadius: 12),
                ),
                child: Slider(
                  value: progress,
                  onChanged: durationMs > 0
                      ? (value) => setState(() => _dragValue = value)
                      : null,
                  onChangeEnd: durationMs > 0
                      ? (value) {
                          widget.player.seek(
                            Duration(milliseconds: (durationMs * value).round()),
                          );
                          setState(() => _dragValue = null);
                        }
                      : null,
                ),
              ),
            ),
            Text(
              formatDuration(widget.player.duration),
              style: TextStyle(
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _VolumeControl extends StatefulWidget {
  const _VolumeControl({required this.player});

  final PlayerController player;

  @override
  State<_VolumeControl> createState() => _VolumeControlState();
}

class _VolumeControlState extends State<_VolumeControl> {
  late double _volume = widget.player.volume.clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          _volume <= 0
              ? Icons.volume_off_rounded
              : _volume < 0.5
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
              value: _volume,
              onChanged: (value) {
                setState(() => _volume = value);
                widget.player.setVolume(value);
              },
            ),
          ),
        ),
      ],
    );
  }
}
```

注意顶部需要 `import 'dart:ui' show FontFeature;`（若 analyze 提示 FontFeature 未定义则加上；Material 已导出部分 dart:ui 符号，以 analyze 为准）。

- [ ] **Step 4: 测试转绿 + 提交**

```bash
flutter test test/ui/desktop/desktop_player_bar_test.dart
flutter analyze
```
预期：PASS、无新增告警。

```bash
git add lib/ui/desktop/desktop_player_bar.dart test/ui/desktop/desktop_player_bar_test.dart
git commit -m "feat(pc): 桌面底部播放栏（控制/进度/音量/队列）"
```

---

### Task 7: DesktopShell 组装 + AppShell 接入

**Files:**
- Create: `lib/ui/desktop/desktop_shell.dart`
- Modify: `lib/ui/pages/app_shell.dart`（`_buildShell` 顶部桌面分流 + import）

**Interfaces:**
- Consumes: Task 2 `isDesktopFormFactor`；Task 5 `DesktopSidebar`/`DesktopNavItem`；Task 6 `DesktopPlayerBar`；Task 3 `LazyIndexedStack`；现有 `HomePage(api, auth, player, cache, theme, downloads, localMusic, sectionIndex, onTabSwitch)`、`LibraryPage(api, auth, player, downloads, theme, localMusic)`、`DownloadedSongsPage(api, auth, player, downloads)`、`SettingsPage(api, auth, player, theme, localMusic, cache, downloads)`、`SearchPage(api, auth, player)`。
- Produces: `class DesktopShell extends StatefulWidget`，全控制器注入（与 AppShell 参数一致）。

- [ ] **Step 1: 实现 DesktopShell**

创建 `lib/ui/desktop/desktop_shell.dart`：

```dart
import 'package:flutter/material.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/download_controller.dart';
import '../../controllers/local_music_controller.dart';
import '../../controllers/player_controller.dart';
import '../../controllers/theme_controller.dart';
import '../../services/cache_service.dart';
import '../../services/music_api.dart';
import '../pages/app_shell.dart' show AppShortcutScope;
import '../pages/downloaded_songs_page.dart';
import '../pages/home_page.dart';
import '../pages/library_page.dart';
import '../pages/search_page.dart';
import '../pages/settings_page.dart';
import '../widgets/lazy_indexed_stack.dart';
import 'desktop_player_bar.dart';
import 'desktop_sidebar.dart';

/// 桌面骨架的内容分区。home 分区对应 HomePage 的三个子 tab
/// （推荐/排行榜/电台），由侧栏直接切换。
enum _DesktopSection { home, library, downloads, settings }

/// 桌面 Shell：左侧导航栏 + 内容区 + 底部播放栏（QQ 音乐 PC 式三段布局）。
///
/// 复用 HomePage 既有的 sectionIndex/onTabSwitch 外部 tab 控制通道，
/// 页面实例保存在 LazyIndexedStack 中，切分区不丢状态。
/// 车机模式在本骨架中不存在（isDesktopFormFactor 已在最外层分流）。
class DesktopShell extends StatefulWidget {
  const DesktopShell({
    super.key,
    required this.api,
    required this.auth,
    required this.player,
    required this.cache,
    required this.downloads,
    required this.theme,
    required this.localMusic,
  });

  final MusicApi api;
  final AuthController auth;
  final PlayerController player;
  final CacheService cache;
  final DownloadController downloads;
  final ThemeController theme;
  final LocalMusicController localMusic;

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  _DesktopSection _section = _DesktopSection.home;

  /// HomePage 子 tab（0=推荐, 1=排行榜, 2=电台），HomePage.sectionIndex 语义。
  var _homeTab = 0;

  /// HomePage.onTabSwitch 的 shell 级下标语义（0=我的, 1..3=三个子 tab）。
  void _handleHomeTabSwitch(int shellIndex) {
    setState(() {
      if (shellIndex <= 0) {
        _section = _DesktopSection.library;
      } else {
        _section = _DesktopSection.home;
        _homeTab = shellIndex - 1;
      }
    });
  }

  void _selectSection(int sidebarIndex) {
    setState(() {
      if (sidebarIndex <= 2) {
        _section = _DesktopSection.home;
        _homeTab = sidebarIndex;
      } else {
        _section = _DesktopSection.values[sidebarIndex - 2];
      }
    });
  }

  void _openSearch(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchPage(
          api: widget.api,
          auth: widget.auth,
          player: widget.player,
        ),
      ),
    );
  }

  int get _sidebarIndex {
    return switch (_section) {
      _DesktopSection.home => _homeTab,
      _DesktopSection.library => 3,
      _DesktopSection.downloads => 4,
      _DesktopSection.settings => 5,
    };
  }

  int get _contentIndex {
    return switch (_section) {
      _DesktopSection.home => 0,
      _DesktopSection.library => 1,
      _DesktopSection.downloads => 2,
      _DesktopSection.settings => 3,
    };
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        cache: widget.cache,
        theme: widget.theme,
        downloads: widget.downloads,
        localMusic: widget.localMusic,
        sectionIndex: _homeTab,
        onTabSwitch: _handleHomeTabSwitch,
      ),
      LibraryPage(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        downloads: widget.downloads,
        theme: widget.theme,
        localMusic: widget.localMusic,
      ),
      DownloadedSongsPage(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        downloads: widget.downloads,
      ),
      SettingsPage(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        theme: widget.theme,
        localMusic: widget.localMusic,
        cache: widget.cache,
        downloads: widget.downloads,
      ),
    ];

    return Scaffold(
      body: Row(
        children: [
          DesktopSidebar(
            items: const [
              DesktopNavItem(
                icon: Icons.explore_outlined,
                activeIcon: Icons.explore_rounded,
                label: '推荐',
              ),
              DesktopNavItem(
                icon: Icons.leaderboard_outlined,
                activeIcon: Icons.leaderboard_rounded,
                label: '排行榜',
              ),
              DesktopNavItem(
                icon: Icons.radio_rounded,
                activeIcon: Icons.radio_rounded,
                label: '电台',
              ),
              DesktopNavItem(
                icon: Icons.library_music_outlined,
                activeIcon: Icons.library_music_rounded,
                label: '我的音乐',
              ),
              DesktopNavItem(
                icon: Icons.download_outlined,
                activeIcon: Icons.download_rounded,
                label: '已下载',
              ),
              DesktopNavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings_rounded,
                label: '设置',
                showDividerAbove: true,
              ),
            ],
            selectedIndex: _sidebarIndex,
            onSelect: _selectSection,
            onSearch: () => _openSearch(context),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: LazyIndexedStack(
                    index: _contentIndex,
                    children: pages,
                  ),
                ),
                DesktopPlayerBar(player: widget.player, auth: widget.auth),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

注意 `AppShortcutScope` 的 import 仅在需要消 unused 警告时保留——本设计里快捷键作用域由 AppShell 的 `build` 统一包裹（`app_shell.dart:64`），DesktopShell **不需要** import 它；若 analyze 无警告，删除该 import 行。

- [ ] **Step 2: AppShell 接入**

`lib/ui/pages/app_shell.dart`：

1. import 区追加：

```dart
import '../desktop/desktop_shell.dart';
import '../form_factor.dart';
```

2. `_buildShell` 方法体内、`final bottomInset = ...`（`:68`）之前插入：

```dart
    // 桌面形态（Windows 等）：独立的桌面骨架（侧栏 + 底部播放栏）。
    // 判定只看平台（form_factor.dart），Android 车机/平板/手机不受影响；
    // 车机模式在桌面形态下不生效（本分支先行返回）。
    if (isDesktopFormFactor) {
      return DesktopShell(
        api: widget.api,
        auth: widget.auth,
        player: widget.player,
        cache: widget.cache,
        downloads: widget.downloads,
        theme: widget.theme,
        localMusic: widget.localMusic,
      );
    }
```

- [ ] **Step 3: 静态检查 + 全量测试**

```bash
flutter analyze
flutter test
```
预期：无新增告警、全绿。

- [ ] **Step 4: Windows 真机冒烟（需用户或执行者有桌面环境）**

```bash
flutter run -d windows
```
人工核对清单：
1. 启动窗口 1280×800（若上次已记忆则恢复记忆值）；拖到小于 960×600 被阻止。
2. 侧栏 6 项可点：推荐/排行榜/电台 切换 HomePage 子 tab；我的音乐/已下载/设置 切内容区；点搜索胶囊进入搜索页。
3. 底部播放栏：播放歌后封面/标题/进度/时间正常，拖进度条可 seek，音量滑杆生效（若 `just_audio_windows` 音量无效——表现为拖动无变化——按决策规则删除 `_VolumeControl` 调用点并在任务报告注明，保留 API 供后续）。
4. 播放中点窗口 X 关闭再启动，窗口尺寸/位置恢复。
5. 回归：临时注释桌面分流分支跑一次 `flutter run -d windows`，确认 NavigationRail 布局仍正常（可选；无环境则跳过并注明）。

- [ ] **Step 5: 提交**

```bash
git add lib/ui/desktop/desktop_shell.dart lib/ui/pages/app_shell.dart
git commit -m "feat(pc): 桌面骨架接入（侧栏+内容区+底部播放栏）"
```

---

## 已知遗留（后续计划处理）

- HomePage 底部 `SizedBox(height: 166)` 悬浮条留白在桌面端为多余空白 → 计划 2 横轨网格化时按 `isDesktopFormFactor` 收窄。
- 设置页"重置窗口"入口、桌面歌词开关（播放栏右侧按钮位已预留）、托盘 → 计划 3。
- `desktop_shell.dart` 若超 400 行（当前估算 ~260 行），将 pages 构建抽为私有方法而非新文件。

## Self-Review 记录

- 规格覆盖：设计 §2（Task 2）、§3（Task 1）、§4（Task 3/5/6/7）、§5 滚轮部分归计划 2、§6（Task 2，重置入口归计划 3）、§9 快捷键已有部分不动（归计划 2 补全）、§10 三形态自检（Task 7 Step 4）。无缺口。
- 类型一致性：`gridColumnsForWidth`/`widthClassFor`、`DesktopNavItem`/`DesktopSidebar`、`showQueueSheet`、`volume`/`setVolume`、`LazyIndexedStack`、`DesktopPlayerBar` 签名在各任务 Consumes/Produces 与实现处一致。
- 占位符：Task 4 Step 1 的 `showModalBottomSheet(/* ← … */)` 为"原样搬迁"指令而非新写代码，搬迁来源已给出行号；Task 6 FontFeature import 标注了以 analyze 为准的确定规则。无 TBD。
