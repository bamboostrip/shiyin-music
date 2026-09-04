# 时音 PC 桌面适配 · 计划 3/3：桌面歌词、托盘常驻与收尾 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 解锁桌面歌词到 Windows（复用既有 Android 歌词编排）、托盘常驻与关闭行为、计划 2 终审 carry-in 修复批；完成后进入全量人工验收。

**Architecture:** 桌面歌词走既有门面：`DesktopLyricsService.isSupportedPlatform` 纳入 Windows，服务内部按平台分支——Android 走原 MethodChannel，Windows 走新桥接 `WindowsDesktopLyricsBridge`（desktop_multi_window 独立无边框置顶窗）。主窗侧 PlayerController 编排（`setDesktopLyricsEnabled`/`_syncDesktopLyrics`/设置持久化/可见性回调）零改动。托盘（system_tray）在主窗控制器就绪后初始化；关闭行为由 `windowManager.setPreventClose` 拦截并按设置分流。

**Tech Stack:** 新依赖 desktop_multi_window、system_tray；其余沿用。

**设计文档:** `docs/superpowers/specs/2026-09-04-pc-desktop-adaptation-design.md` §6/§7/§8 + 计划 2 终审 carry-in。

## Global Constraints

- **Android 路径零回归**：歌词 Android MethodChannel 路径逐行保留（服务内平台分支）；车机/手机 UI 无任何变化；设置页新增"桌面"卡整体以 `isDesktopFormFactor` 门控。
- 桌面歌词编排（PlayerController）零改动；只允许动 `DesktopLyricsService` 内部与其新增协作文件。
- runner 原生层（main.cpp）改动必须以 desktop_multi_window 包内示例为准，改完 `flutter build windows --debug` 必须成功。
- 提交信息风格 `type(scope): 中文描述`；每任务 analyze 无新增告警、全量测试 ≥55/55（当前基线）。
- 分支 `feature/pc-desktop-adaptation` 继续。
- 已知计划内测试缺口：多窗口/托盘为原生集成，无法 widget 测试，靠 analyze/build + 最终人工冒烟；可纯测的逻辑必须测。

---

## File Structure

| 操作 | 路径 | 职责 |
|---|---|---|
| Modify | `lib/ui/pages/app_shell.dart` | 焦点守卫提取共享（含 InkWell） |
| Create | `lib/ui/keyboard_focus_guard.dart` | `isFocusInsideInteractiveControl()` 共享 |
| Modify | `lib/ui/desktop/desktop_shell.dart` | 桌面快捷键接入焦点守卫 |
| Modify | `lib/ui/adaptive_layout.dart` | `isDesktopGridWidth(w)` 共享门控 |
| Modify | `lib/ui/widgets/app_section.dart`、`lib/ui/pages/home_page.dart`、`lib/ui/pages/rank_page.dart` | 门控统一走 helper；_PlaylistRail 改约束来源 |
| Modify | `lib/ui/pages/settings_page.dart` | 音效瓦片分隔线修正；新增"桌面"卡 |
| Modify | `test/ui/widgets/app_horizontal_rail_test.dart` | 补 HorizontalWheelScroll 断言 |
| Modify | `pubspec.yaml` | + desktop_multi_window |
| Modify | `windows/runner/main.cpp` | 多窗口入口路由（按包示例） |
| Create | `lib/services/windows_desktop_lyrics_bridge.dart` | 主窗侧歌词窗桥接 |
| Create | `lib/ui/desktop/lyrics_overlay_window.dart` | 歌词悬浮窗（子窗口入口+UI） |
| Modify | `lib/services/desktop_lyrics_service.dart` | 平台分支 |
| Modify | `lib/ui/desktop/desktop_player_bar.dart` | 桌面歌词开关按钮 |
| Modify | `pubspec.yaml` | + system_tray、+ lib/assets/app_icon.ico |
| Create | `assets` 复制 | `lib/assets/app_icon.ico`（取自 windows/runner/resources） |
| Create | `lib/ui/desktop/desktop_tray.dart` | 托盘初始化与菜单 |
| Modify | `lib/ui/desktop/desktop_window.dart` | onWindowClose flush + 关闭行为 + try/catch + resetToDefault |
| Modify | `lib/main.dart` | 桌面态托盘初始化 |

---

### Task 1: carry-in 修复批（TDD）

**Files:**
- Create: `lib/ui/keyboard_focus_guard.dart`
- Modify: `lib/ui/pages/app_shell.dart`、`lib/ui/desktop/desktop_shell.dart`、`lib/ui/adaptive_layout.dart`、`lib/ui/widgets/app_section.dart`、`lib/ui/pages/home_page.dart`、`lib/ui/pages/rank_page.dart`、`lib/ui/pages/settings_page.dart`
- Modify: `test/ui/widgets/app_horizontal_rail_test.dart`

**Interfaces:**
- Produces: 顶层 `bool isFocusInsideInteractiveControl()`（keyboard_focus_guard.dart，守卫列表含 EditableText/SelectableText/ButtonStyleButton/IconButton/RawMaterialButton/**InkWell**）；`AdaptiveLayout.isDesktopGridWidth(double width) => isDesktopFormFactor && width >= kGridStartWidth`。

- [ ] **Step 1: 提取焦点守卫** — 新建 `lib/ui/keyboard_focus_guard.dart`：把 `app_shell.dart` 的 `AppShortcutScope._isFocusInsideInteractiveControl` 方法体原样搬为顶层函数，检查类型列表**追加 `InkWell`**（修复空格键聚焦卡片无响应）；doc 注释说明桌面快捷键共用。`app_shell.dart` 的 AppShortcutScope 改为调用顶层函数（删私有方法，import 该文件）。`desktop_shell.dart` 的 Actions：四个 `onInvoke` 开头加 `if (isFocusInsideInteractiveControl()) return null;`（修复 Enter 遮蔽按钮激活）。
- [ ] **Step 2: 统一网格门控** — `adaptive_layout.dart` 追加：

```dart
  /// 桌面形态且宽度达到网格起点（横轨转网格的唯一门控入口）。
  static bool isDesktopGridWidth(double width) =>
      isDesktopFormFactor && width >= kGridStartWidth;
```

（需 import form_factor.dart。）四个门控点替换为 `AdaptiveLayout.isDesktopGridWidth(...)`：app_section（constraints.maxWidth）、home _PlaylistRail（**改约束来源**：非车机分支的网格/横轨选择包进 `LayoutBuilder`，用 `constraints.maxWidth`，修终审 Important #2）、home _RadioStationRail（constraints.maxWidth）、rank（constraints.maxWidth）。
- [ ] **Step 3: 设置分隔线修正** — `settings_page.dart` 音效瓦片块：让音效瓦片后的 `_SettingsDivider()` 移出守卫（守卫只包瓦片本身），使"响度均衡/播放统计"在桌面隐藏音效后仍有分隔线。锚点：`if (player.isAudioEffectsSupported) ...[ _SettingsDivider(), _SettingsTile(音效...), _SettingsDivider(),` → `if (player.isAudioEffectsSupported) ...[ _SettingsDivider(), _SettingsTile(音效...) ], _SettingsDivider(),`（保持支持时渲染不变）。
- [ ] **Step 4: 测试补断言** — `app_horizontal_rail_test.dart` 桌面窄窗用例追加 `expect(find.byType(HorizontalWheelScroll), findsOneWidget);`（import 该组件）。
- [ ] **Step 5: 验证 + 提交** — analyze 零新增、全量 ≥55/55、`git commit -m "fix(pc): 快捷键焦点守卫与网格门控统一（计划2终审carry-in）"`

### Task 2: 桌面歌词 Windows 解锁

**Files:**
- Modify: `pubspec.yaml`（dependencies 加 `desktop_multi_window: ^0.2.0`；以 pub 解析为准，若该约束不可解析，取 pub.dev 最新 0.x 并适配 API）
- Modify: `windows/runner/main.cpp`（按包内示例改造多窗口入口路由）
- Create: `lib/services/windows_desktop_lyrics_bridge.dart`
- Create: `lib/ui/desktop/lyrics_overlay_window.dart`
- Modify: `lib/services/desktop_lyrics_service.dart`（平台分支）

**Interfaces:**
- Produces: 桌面上 `player.isDesktopLyricsSupported == true`（既有 getter 自动透出）；`setDesktopLyricsEnabled`/设置页歌词卡/播放页入口全部生效；子窗口接收消息协议：`updateLyric`（current/next/isPlaying/设置 JSON）。

**实现要点（按序）：**

- [ ] **Step 1: 依赖与 runner** — 加依赖 + `flutter pub get`；读 pub 缓存中 `desktop_multi_window-*/example/windows/runner/main.cpp`（`~/.pub-cache/hosted/pub.dev/` 下）与本仓库 `windows/runner/main.cpp` 对照，按示例加多窗口命令行路由（通常为 include 插件头 + 入口判断）。验收：`flutter build windows --debug` 成功。注意 `DesktopWindow.ensureInitialized` 在 `runApp` 前运行——子窗口进程同样会执行 `main()`，`main.dart` 顶部需在 `runApp` 前检测 `args`（`main(List<String> args)`）：若为多窗口参数（按示例约定），改为运行 `runLyricsOverlayWindow(args)` 并 `return`，**不得**执行音频服务/窗口管理初始化。
- [ ] **Step 2: 子窗口 UI** — 新建 `lib/ui/desktop/lyrics_overlay_window.dart`：

```dart
@pragma("vm:entry-point")
Future<void> runLyricsOverlayWindow(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final windowController = await WindowController.fromWindowId(int.parse(args.last));
  // 参数 JSON：{settings: DesktopLyricsSettings.toMap(), current: String, next: String, isPlaying: bool}
  final initial = jsonDecode(windowController.arguments ?? '{}') as Map<String, dynamic>;
  await windowManager.ensureInitialized();
  // 置顶、无边框、初始尺寸按字号设置给足
  await windowManager.setAlwaysOnTop(true);
  ... // runApp(_LyricsOverlayApp(...))
}
```

子窗口 UI 要求：无系统标题栏（`windowManager.setTitleBarStyle(TitleBarStyle.hidden)`）；圆角半透明背景（用 settings.backgroundColor/opacity）；两行文本——当前行（fontSize 设置值、加粗、settings.textColor）+ 下一行（60% 字号、70% 透明度）；`DragToMoveArea`（window_manager 提供，`locked==false` 时启用；拖动结束把新位置存 SharedPreferences key `desktop_lyrics.window.left/top`，启动时恢复）；右上角悬停工具条：锁定/解锁、关闭（关闭=通知主窗后 `windowManager.destroy()`）。子窗口通过 `DesktopMultiWindow.setMethodHandler` 接收主窗消息（`updateLyric`、`updateSettings`、`close`），并经 `DesktopMultiWindow.sendToMain(MethodCall('windowClosed'))` 通知主窗用户手动关闭。尺寸自适应：文本变化时用 `Measure`-less 策略——固定最大宽 720、按内容 `ConstrainedBox` 包裹，窗口 `setFrame` 由主窗管理（子窗口只在锁定尺寸变化时调 `windowManager.setSize` 谨慎处理；v1 允许固定窗高 120、宽 720，文本居中截断，避免 setSize 复杂度）。
- [ ] **Step 3: 主窗桥接** — 新建 `lib/services/windows_desktop_lyrics_bridge.dart`：类 `WindowsDesktopLyricsBridge`，持有 `WindowController?`；方法与 DesktopLyricsService 门面一一对应：`show(title, artist)`（createWindow + setFrame + show + 推送初始内容）、`hide()`（`DesktopMultiWindow.sendToWindow`? 不存在则向子窗发 `close` 消息后 `windowController.close()`）、`updateLyrics(current, next)`、`updatePlayState(isPlaying)`、`updateSettings(map)`（均经 `DesktopMultiWindow` 消息通道；实现前先读 pub 缓存包源码确认 main→sub 发消息 API 名，以源码为准）、`isVisible` 内部 bool、`onWindowClosed` 回调透传给服务的 `_visibilityChanged`。主窗侧 `DesktopMultiWindow.setMethodHandler` 处理 `windowClosed`。
- [ ] **Step 4: 服务平台分支** — `desktop_lyrics_service.dart`：`isSupportedPlatform` 改为 `!kIsWeb && (defaultTargetPlatform == TargetPlatform.android || isDesktopFormFactor)`（import form_factor）；类内增加 `static final WindowsDesktopLyricsBridge? _windowsBridge = isDesktopFormFactor ? WindowsDesktopLyricsBridge(_visibilityChanged 透传) : null;`——注意 `_visibilityChanged` 现为静态字段，桥接回调经静态方法转发。所有方法体改为：Android 分支保持原实现不动；Windows 分支调 `_windowsBridge!` 对应方法（`checkPermission`→true、`requestPermission`→no-op、`updateKaraokeProgress`→v1 no-op、`setAppForeground`→内部记录、其余转发）。
- [ ] **Step 5: 验证 + 提交** — `flutter analyze` 零新增；全量测试 ≥55/55；`flutter build windows --debug` 成功；`git commit -m "feat(pc): 桌面歌词解锁至 Windows（desktop_multi_window 悬浮窗）"`

### Task 3: 播放栏桌面歌词开关

**Files:**
- Modify: `lib/ui/desktop/desktop_player_bar.dart`

- [ ] **Step 1: 开关按钮** — 队列按钮左侧插入歌词开关（仅 `player.isDesktopLyricsSupported` 时渲染，桌面恒真、Android 无此栏）：

```dart
              AnimatedBuilder(
                animation: player,
                builder: (context, _) {
                  final enabled = player.desktopLyricsEnabled;
                  return IconButton(
                    tooltip: enabled ? '关闭桌面歌词' : '开启桌面歌词',
                    onPressed: song == null
                        ? null
                        : () => player.setDesktopLyricsEnabled(!enabled),
                    icon: Icon(
                      enabled
                          ? Icons.lyrics_rounded
                          : Icons.lyrics_outlined,
                      size: 26,
                    ),
                    color: enabled
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                  );
                },
              ),
              const SizedBox(width: 4),
```

- [ ] **Step 2: 验证 + 提交** — analyze/全量测试；`git commit -m "feat(pc): 底部播放栏桌面歌词开关"`

### Task 4: 托盘常驻 + 关闭行为 + 设置页"桌面"卡

**Files:**
- Modify: `pubspec.yaml`（`system_tray: ^2.0.3`，以 pub 解析为准）、assets 加 `lib/assets/app_icon.ico`（`cp windows/runner/resources/app_icon.ico lib/assets/app_icon.ico`）
- Create: `lib/ui/desktop/desktop_tray.dart`
- Modify: `lib/ui/desktop/desktop_window.dart`、`lib/main.dart`、`lib/ui/pages/settings_page.dart`

**Interfaces:**
- Produces: 托盘菜单（显示/隐藏主窗、播放/暂停、上一首、下一首、退出）；设置键 `window.closeToTray`（默认 true）控制关闭行为；`DesktopWindow.resetToDefault()`（重置几何 + 恢复默认尺寸居中）。

- [ ] **Step 1: DesktopWindow 收尾** — `_WindowGeometrySaver` 追加 `onWindowClose`：取消防抖 Timer 并**立即**保存几何（计划 1 终审 carry-in）。`ensureInitialized` 里 `windowManager.setPreventClose(true)`（桌面形态恒开）；新增静态 `closeToTrayEnabled(prefs)`/`setCloseToTray(prefs, bool)`（键 `window.closeToTray`，默认 true）。onWindowClose 逻辑：读设置——true → `windowManager.hide()`；false → `windowManager.destroy()`。显示器查询 try/catch 加固：`getPrimaryDisplay/getAllDisplays` 包 try/catch，异常时回退"不钳制直接用保存几何"（计划 1 复审 carry-in）。新增 `resetToDefault(prefs)`：`DesktopWindowGeometry.reset(prefs)` + `setBounds` 默认尺寸并居中（`windowManager.center()`）。
- [ ] **Step 2: 托盘组件** — 新建 `lib/ui/desktop/desktop_tray.dart`：`class DesktopTray` 静态 `init({required PlayerController player})` / `dispose()`；菜单项：显示主窗（`windowManager.show()+focus()`）、隐藏主窗、播放/暂停（`player.togglePlay()`）、上一首、下一首、退出（`windowManager.destroy()`，退出前 flush 几何——复用 saver 的立即保存）；左键单击切换显示/隐藏。system_tray API 以包源码/README 为准（iconPath 用 `lib/assets/app_icon.ico`；若该路径加载失败改用绝对文件路径方案并在报告注明）。
- [ ] **Step 3: 主窗接线** — `main.dart` `_ShiyinAppState.initState` 末尾：`if (isDesktopFormFactor) { unawaited(DesktopTray.init(player: _player)); }`（import desktop_tray/form_factor）；`dispose()` 对应 `DesktopTray.dispose()`。
- [ ] **Step 4: 设置页"桌面"卡** — 锚点：播放设置卡闭合后、`// Cache section` 之前（约 :397-399）。插入：

```dart
                  if (isDesktopFormFactor) ...[
                    const SizedBox(height: 20),
                    const _SectionHeader(title: '桌面'),
                    const SizedBox(height: 8),
                    _SettingsCard(
                      children: [
                        _SettingsSwitchTile(
                          icon: Icons.window_rounded,
                          iconColor: const Color(0xFF00B0FF),
                          title: '关闭时最小化到托盘',
                          subtitle: '点关闭按钮时隐藏到系统托盘，音乐不断',
                          value: _closeToTray,
                          onChanged: (value) async { ... 读写 window.closeToTray + setState ... },
                        ),
                        _SettingsDivider(),
                        _SettingsTile(
                          icon: Icons.crop_square_rounded,
                          iconColor: const Color(0xFF7CB342),
                          title: '重置窗口',
                          subtitle: '恢复默认窗口大小并居中',
                          onTap: () => DesktopWindow.resetToDefault(...prefs...),
                        ),
                      ],
                    ),
                  ],
```

`_closeToTray` 为页面内本地状态（initState 读 prefs；settings_page 是 StatelessWidget → 该卡改为读取处用 `FutureBuilder` 或把页面需要的两处做成独立 StatefulWidget `_CloseToTraySwitch`——**选后者**，避免改造整页状态）；`resetToDefault` 内部自取 SharedPreferences。import：form_factor、desktop_window、shared_preferences（若未有）。
- [ ] **Step 5: 验证 + 提交** — analyze/全量测试/`flutter build windows --debug`；`git commit -m "feat(pc): 托盘常驻、关闭行为设置与窗口重置入口"`

### 收尾（控制器自做，不派发）

全量 `flutter analyze` / `flutter test` / `flutter build windows --debug`；计划 3 范围终审；更新台账与验收清单。

## Self-Review 记录

- 规格覆盖：设计 §7（Task 2/3：入口=设置卡既有 + 播放栏新增 + 播放页既有自动透出）、§8（Task 4）、计划 2 终审 carry-in 全部入 Task 1（Enter/InkWell 守卫、门控统一、分隔线、测试断言）+ Task 4（onWindowClose flush、try/catch）。
- 已知风险点已显式化：runner 改造与 main→sub 消息 API 名以包源码为准（Step 1/3 决策规则）；子窗口 v1 固定尺寸避免 setSize 复杂度；卡拉OK 进度 v1 no-op。
- 类型一致性：`WindowsDesktopLyricsBridge` 方法集与门面一一对应；`isFocusInsideInteractiveControl`/`isDesktopGridWidth` 签名唯一。
