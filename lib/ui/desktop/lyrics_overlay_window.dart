// 桌面歌词悬浮窗（desktop_multi_window 子窗口入口 + UI）。
//
// 仅在 Windows 桌面形态由主窗经 WindowsDesktopLyricsBridge 创建；
// 子窗口引擎会重新执行 main()（desktop_multi_window 约定），main.dart
// 顶部按 `multi_window` 参数分流到本文件 [runLyricsOverlayWindow]。
//
// 消息协议（main -> sub）：
// - updateLyric    {current, next, isPlaying}
// - updatePlayState {isPlaying}（仅播放态变化；不触发换句重置进度）
// - updateSettings {DesktopLyricsSettings.toMap()}
// 消息协议（sub -> main）：
// - windowClosed   {}（用户手动关闭悬浮窗）
// - overlayReady   {}（子引擎消息通道就绪，主窗收到后补发缓存的歌词与设置，
//   消除 createWindow 到 setMethodHandler 之间启动窗口期的消息丢失）
// - controlPlayback (action: 'previous' | 'togglePlay' | 'next')（悬停播控条触发主窗播控）
// - setLyricsLocked (locked: bool)（工具栏锁定按钮请求切换锁定状态；子窗不本地
//   直改，由主窗落盘并经 updateSettings 回推后统一重建 + 重设穿透）
import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/desktop_lyrics_service.dart';
import '../../services/windows_desktop_lyrics_bridge.dart';
import '../design_tokens.dart';
import 'lyrics_karaoke_line.dart';

/// 子窗口控制器（入口函数创建后模块级持有，供关闭流程使用）。
WindowController? _overlayWindowController;

/// 拖动结束后位置持久化的防抖间隔（WM_MOVE 风暴下合并落盘）。
const Duration _kPersistDebounce = Duration(milliseconds: 500);

/// 关闭流程重入 guard：closeLyricsOverlayWindow 可能由用户点 X、
/// Alt+F4（onWindowClose 漏斗）与主窗侧 hide（window.close 被
/// preventClose 拦截后转入漏斗）并发触发，只执行一次。
bool _overlayCloseInFlight = false;

/// 立即持久化当前窗口位置（防抖取消失效时与关闭前补存共用）。
///
/// 窗口常驻固定高度（菜单收展不再移动/缩放窗口），top 直接落盘即可。
///
/// [markPositionSemanticsCurrent]：随位置一并置位三个一次性迁移键——
/// **只在用户拖动路径置 true**。拖动落盘的位置必是现行窗口语义，标记后
/// 下次启动不会再对它跑「减工具栏带/菜单带」的一次性迁移（全新安装用户
/// 首次拖动保存后，第二次启动曾被误判成迁移前语义而整体上跳 248px）。
/// 启动恢复/关闭补存必须保持 false：主窗 createWindow 先于迁移落盘，
/// 子窗启动恢复读到的可能是迁移前的旧值，标了会把旧语义位置永久焊死。
Future<void> persistOverlayWindowPosition({
  bool markPositionSemanticsCurrent = false,
}) async {
  try {
    final position = await windowManager.getPosition();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
      WindowsDesktopLyricsBridge.windowLeftPrefKey,
      position.dx,
    );
    await prefs.setDouble(
      WindowsDesktopLyricsBridge.windowTopPrefKey,
      position.dy,
    );
    if (markPositionSemanticsCurrent) {
      await prefs.setBool(
        WindowsDesktopLyricsBridge.windowInsetMigratedPrefKey,
        true,
      );
      await prefs.setBool(
        WindowsDesktopLyricsBridge.windowTallMigratedPrefKey,
        true,
      );
      await prefs.setBool(
        WindowsDesktopLyricsBridge.windowMenuProgressRowMigratedPrefKey,
        true,
      );
    }
  } on Exception {
    // 位置持久化失败不影响展示。
  }
}

/// 启动恢复位置的那次 programmatic move 会触发 onWindowMoved：不抑制的
/// 话它会被当成用户拖动走标记路径（见上）。单次 setPosition 只产生一条
/// WM_MOVE，一次性标志即可；若恢复位置与现状相同（无 WM_MOVE），标志
/// 残留到用户首次拖动也只是吞掉第一条事件——拖动是连续 move 流，后续
/// 事件照常防抖落盘，最终位置不丢。
bool _suppressNextMovePersist = false;

/// 用户拖动的防抖落盘是否 pending：onWindowMoved 调度防抖时同步置位，
/// 防抖触发（带标记落盘）后清零。关闭补存（拖动 500ms 内就关窗）凭它
/// 决定是否带标记——否则“拖动后立刻点 ✕”会丢标记（关闭补存默认
/// false，而防抖 timer 随子引擎销毁再也不会触发）。
/// 标记只会置 true、永不清除：多带一次是幂等的，漏带一次才是 bug。
bool _userDragPersistPending = false;

/// 取走待定的拖动标记（关闭补存用，读后即清）。
bool _takeUserDragPersistPending() {
  final pending = _userDragPersistPending;
  _userDragPersistPending = false;
  return pending;
}

/// desktop_multi_window 子窗口参数判定（约定见包源码：
/// args = ['multi_window', windowId, argumentsJson]）。
bool isLyricsOverlayWindowArgs(List<String> args) {
  return args.length >= 2 && args.first == 'multi_window';
}

/// 子窗口入口：桌面歌词悬浮窗。
///
/// 注意：必须在 main() 任何重量级初始化（音频服务/窗口管理/DesktopWindow）
/// 之前调用并 return；本函数自带子引擎所需的最小初始化。
@pragma("vm:entry-point")
Future<void> runLyricsOverlayWindow(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 参数解析失败直接返回，不让子引擎带病启动（此前 jsonDecode/int.parse
  // 无保护，畸形参数会导致子引擎未处理异常）。
  WindowController? windowController;
  try {
    if (args.length < 2) {
      return;
    }
    windowController = WindowController.fromWindowId(int.parse(args[1]));
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] 解析窗口ID失败: $e');
    return;
  }
  _overlayWindowController = windowController;
  final shownController = windowController;
  // 穿透调度器：显示前登记、显示后施加（防隐藏期 WS_EX_LAYERED 空白窗）。
  _overlayPassthroughScheduler = OverlayPassthroughScheduler(
    onApply: applyDesktopLyricsPassthrough,
  );

  var settings = const DesktopLyricsSettings();
  var current = '';
  var next = '';
  var isPlaying = false;
  var progress = 0.0;
  var activeOnBottom = false;
  if (args.length > 2 && args[2].isNotEmpty) {
    try {
      // 包 0.2.1 的 WindowController 无 arguments getter，
      // 初始参数经 createWindow 的 arguments 字符串由 main(args[2]) 传入。
      final initialArgs = jsonDecode(args[2]) as Map<String, dynamic>;
      settings = DesktopLyricsSettings.fromMap(
        (initialArgs['settings'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      );
      current = initialArgs['current'] as String? ?? '';
      next = initialArgs['next'] as String? ?? '';
      isPlaying = initialArgs['isPlaying'] as bool? ?? false;
      progress = (initialArgs['progress'] as num?)?.toDouble() ?? 0.0;
      activeOnBottom = initialArgs['activeOnBottom'] as bool? ?? false;
    } catch (e) {
      debugPrint('[桌面歌词悬浮窗] 解析初始参数失败，使用默认值: $e');
    }
  }

  // 每个原生窗口调用独立 try/catch：此前任何一步抛异常都会中断整个
  // 子引擎启动。互不干扰。
  // 子引擎内 window_manager 作用于本悬浮窗自身（ensureInitialized 将
  // native_window 绑定为当前引擎根 HWND，见 window_manager 源码）。
  try {
    await windowManager.ensureInitialized();
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] ensureInitialized 失败: $e');
  }
  try {
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setTitleBarStyle 失败: $e');
  }
  try {
    await windowManager.setAsFrameless();
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setAsFrameless 失败: $e');
  }
  try {
    await windowManager.setHasShadow(false);
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setHasShadow 失败: $e');
  }
  try {
    await windowManager.setBackgroundColor(Colors.transparent);
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setBackgroundColor 失败: $e');
  }
  try {
    await windowManager.setAlwaysOnTop(true);
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setAlwaysOnTop 失败: $e');
  }
  // 拦截外部关闭（Alt+F4/任务栏关闭）：默认路径下子窗被直接销毁且主窗
  // 毫无感知（desktop_multi_window 的 OnWindowClose 是空实现），桥接会
  // 残留 _visible=true、歌词静默冻结。拦截后统一走
  // [_LyricsOverlayHomeState.onWindowClose] → closeLyricsOverlayWindow 漏斗。
  try {
    await windowManager.setPreventClose(true);
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setPreventClose 失败: $e');
  }
  // 桌面歌词属于纯悬浮组件，不应在系统任务栏占据独立图标。
  try {
    await windowManager.setSkipTaskbar(true);
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setSkipTaskbar 失败: $e');
  }
  try {
    await windowManager.setTitle('桌面歌词');
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setTitle 失败: $e');
  }
  try {
    await windowManager.setSize(
      const Size(
        WindowsDesktopLyricsBridge.overlayWidth,
        WindowsDesktopLyricsBridge.overlayWindowHeight,
      ),
    );
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setSize 失败: $e');
  }
  // 启动即按应用设置准备穿透（锁定=全穿透；主窗缓存的 settings 随
  // createWindow 参数传入，重建路径上穿透状态与应用设置一致）。
  // 注意：穿透样式必须延迟到窗口 show() 之后再施加——
  // windowManager.setIgnoreMouseEvents 会给窗口加 WS_EX_LAYERED，
  // 若在窗口仍隐藏时设置，Flutter 的 DComp 内容面将永久无法呈现
  // （表现为锁定状态下重开/重启后歌词窗口空白），故此处只登记待应用。
  schedulePassthroughAfterShown(settings);

  // 恢复上次拖动位置（失败不影响展示）。记忆位置已由主窗侧在创建前
  // 钳制到可见显示器区域并回写（子引擎无 screen_retriever 插件，无法
  // 自行判断显示器配置变化），这里直接信任 prefs 的值。
  try {
    final prefs = await SharedPreferences.getInstance();
    final left = prefs.getDouble(WindowsDesktopLyricsBridge.windowLeftPrefKey);
    final top = prefs.getDouble(WindowsDesktopLyricsBridge.windowTopPrefKey);
    if (left != null && top != null) {
      // 抑制这次 programmatic move 的持久化：此刻 prefs 里可能还是主窗
      // 迁移落盘前的旧语义值（createWindow 先于迁移，见 persist 注释），
      // 保存它无妨（下次启动迁移会重跑），但不能带语义标记保存。
      _suppressNextMovePersist = true;
      await windowManager.setPosition(Offset(left, top));
    }
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] 恢复窗口位置失败: $e');
  }

  final model = _OverlayModel(
    settings: settings,
    current: current,
    next: next,
    isPlaying: isPlaying,
    progress: progress,
    activeOnBottom: activeOnBottom,
  );

  // 尽早注册消息处理，缩短主窗早期消息的丢失窗口期
  // （主窗 createWindow 后立即推送初始内容）。
  try {
    DesktopMultiWindow.setMethodHandler((
      MethodCall call,
      int fromWindowId,
    ) async {
      switch (call.method) {
        case 'updateLyric':
          final message = (call.arguments as Map?)?.cast<String, dynamic>();
          if (message != null) {
            model
              ..current = message['current'] as String? ?? model.current
              ..next = message['next'] as String? ?? model.next
              ..isPlaying = message['isPlaying'] as bool? ?? model.isPlaying
              ..activeOnBottom = message['activeOnBottom'] as bool? ?? false
              // 换句即重置逐字进度：新句从 0 开始（进度由随后的
              // updateProgress 帧驱动）。
              ..progress = 0.0;
          }
        case 'updatePlayState':
          // 仅播放态变化：不得走 updateLyric 的换句重置，否则每次
          // 暂停/缓冲都清掉当前句已唱的高亮进度。
          final message = (call.arguments as Map?)?.cast<String, dynamic>();
          if (message != null) {
            model.isPlaying = message['isPlaying'] as bool? ?? model.isPlaying;
          }
        case 'updateProgress':
          final message = (call.arguments as Map?)?.cast<String, dynamic>();
          if (message != null) {
            model.progress = (message['progress'] as num?)?.toDouble() ?? 0.0;
            model.isPlaying = message['isPlaying'] as bool? ?? model.isPlaying;
          }
        case 'updateSettings':
          final message = (call.arguments as Map?)?.cast<String, dynamic>();
          if (message != null) {
            model.settings = DesktopLyricsSettings.fromMap(message);
            // 同样经调度器：显示前只登记，避免隐藏期加 WS_EX_LAYERED
            // 导致的空白窗（见 OverlayPassthroughScheduler 注释）。
            await schedulePassthroughAfterShown(model.settings);
          }
      }
      return null;
    });
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] 注册消息处理失败: $e');
  }

  // 向主窗上报就绪：启动窗口期内主窗的推送会因通道未就绪而丢失，
  // 主窗收到后会补发缓存的歌词与设置。
  try {
    await DesktopMultiWindow.invokeMethod(0, 'overlayReady');
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] overlayReady 上报失败: $e');
  }

  // 子引擎异常上报：必须与 binding 同 zone，不能用 runZonedGuarded 包 runApp
  // （binding 在根 zone 初始化，换 zone 会触发 Zone mismatch 断言）。
  final flutterOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    debugPrint(
      '[桌面歌词悬浮窗] FlutterError: ${details.exception}\n${details.stack}',
    );
    flutterOnError?.call(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    debugPrint('[桌面歌词悬浮窗] 未捕获异步异常: $error\n$stack');
    return true;
  };
  runApp(_LyricsOverlayApp(model: model));
  // 插件创建的窗口初始隐藏（源码 ShowWindow(SW_HIDE)）。首帧渲染完成
  // 后再显示：此前 show() 在 runApp 之前调用，空窗口先行贴屏，
  // 既闪现白底默认窗，也可能与引擎首帧初始化竞态。
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await shownController.show();
      // 窗口已可见：现在施加穿透样式才安全（隐藏期设置会导致内容面
      // 永久空白），并补施显示前登记的锁定穿透。
      _overlayPassthroughScheduler?.markShown();
      await _overlayPassthroughScheduler?.flushPending();
      // 窗口显示后确认跳过任务栏（防 Windows Shell 在 ShowWindow 阶段补加 Tab）
      try {
        await windowManager.setSkipTaskbar(true);
      } catch (_) {}
    } catch (e) {
      debugPrint('[桌面歌词悬浮窗] show 失败: $e');
    }
  });
}

/// 锁定即全穿透（QQ 音乐式基准）：locked ⇒ setIgnoreMouseEvents(true)，
/// 歌词纯文字常显、窗口不接收任何鼠标事件；解锁（locked=false）的命中
/// 测试不再在此整体开启 —— 窗口常驻展开高度后上方菜单带平时必须穿透
/// （否则挡下层应用点击），由未锁定态的光标轮询按区域切换（见
/// _HoverableOverlayState._pollCursor）。
/// 旧持久化字段 passthrough 仅保留兼容解析，不再参与穿透判定
/// （"触摸穿透"开关的语义已被锁定吸收）。
/// 公开为顶层函数以便单测固定锁定/解锁的穿透行为。
///
/// ⚠️ 只允许在窗口已经显示后调用（见 [schedulePassthroughAfterShown]）。
Future<void> applyDesktopLyricsPassthrough(
  DesktopLyricsSettings settings,
) async {
  if (!settings.locked) {
    // 解锁：区域穿透由 _HoverableOverlay 的轮询接管（子树 initState
    // 首拍即校准），此处直接整体开启接收会让菜单带挡住下层点击。
    return;
  }
  try {
    await windowManager.setIgnoreMouseEvents(true);
  } on Exception {
    // setIgnoreMouseEvents 失败不影响歌词展示。
  }
}

/// 穿透调度器：窗口显示前只登记最新设置，显示后再真正施加。
///
/// 根因：windowManager.setIgnoreMouseEvents 在 Windows 原生层给窗口加
/// WS_EX_TRANSPARENT | WS_EX_LAYERED。若在窗口仍处于隐藏状态（插件创建
/// 子窗后默认 SW_HIDE）时加 WS_EX_LAYERED，Flutter 子窗的 DComp 内容面
/// 将永久无法呈现——锁定状态下关闭后重开/随应用重启重建的歌词窗口一片
/// 空白即由此而来。窗口可见后增删该样式则安全（工具栏锁定/解锁已验证）。
/// 公开为类以便单测固定「显示前登记、显示后补施」的行为。
class OverlayPassthroughScheduler {
  OverlayPassthroughScheduler({required this.onApply});

  /// 实际施加函数（注入 windowManager 版本；单测注入记录桩）。
  final Future<void> Function(DesktopLyricsSettings settings) onApply;

  bool _shown = false;
  DesktopLyricsSettings? _pending;

  /// 窗口已显示：此后每次调用立即施加。
  void markShown() {
    _shown = true;
  }

  /// 请求施加穿透；窗口尚未显示时仅登记，待 markShown 后补施。
  Future<void> apply(DesktopLyricsSettings settings) async {
    if (!_shown) {
      _pending = settings;
      return;
    }
    _pending = null;
    await onApply(settings);
  }

  /// markShown 后补施显示前登记的最后一笔设置（可能为 null = 无需施加）。
  Future<void> flushPending() async {
    final pending = _pending;
    _pending = null;
    if (pending != null) {
      await onApply(pending);
    }
  }
}

/// 本子窗口的穿透调度器（入口函数创建，updateSettings 与 show 流程共用）。
OverlayPassthroughScheduler? _overlayPassthroughScheduler;

/// 窗口显示前的穿透登记入口（供启动流程与 updateSettings 消息复用）。
Future<void> schedulePassthroughAfterShown(
  DesktopLyricsSettings settings,
) async {
  await _overlayPassthroughScheduler?.apply(settings);
}

/// 关闭悬浮窗的统一漏斗：补存位置 → 通知主窗 → 解除关闭拦截 → 销毁自身。
///
/// 触发来源：卡片关闭按钮、Alt+F4/任务栏关闭（preventClose 拦截后经
/// [_LyricsOverlayHomeState.onWindowClose] 转入）、主窗侧 hide 的
/// window.close()（同样被拦截转入；主窗凭 _visible=false 识别并忽略
/// 其 windowClosed 上报，不会误翻持久化开关）。
Future<void> closeLyricsOverlayWindow() async {
  if (_overlayCloseInFlight) return;
  _overlayCloseInFlight = true;
  // 原生销毁不会执行 Dart dispose：先补存位置（拖动防抖 500ms 内的
  // 最后一次移动在此落盘，标记意图一并带上，见 _userDragPersistPending）。
  await persistOverlayWindowPosition(
    markPositionSemanticsCurrent: _takeUserDragPersistPending(),
  );
  try {
    await DesktopMultiWindow.invokeMethod(0, 'windowClosed');
  } on Exception {
    // 主窗可能已退出；仍然销毁自身。
  }
  // 必须用 WindowController.close()（原生 PostMessage(WM_SYSCOMMAND, SC_CLOSE)，
  // 仅销毁本子窗口并正确清理 WindowChannel/FlutterWindow）。子引擎内绝不可
  // 调用 window_manager.destroy()：其 Windows 实现为 PostQuitMessage(0)
  // （window_manager.cpp Destroy()），子引擎与主窗共享平台线程消息循环，
  // WM_QUIT 会连带退出整个应用。上游 destroy 相关崩溃记录
  // （MixinNetwork/flutter-plugins#137、window_manager#549）仅适用于
  // destroy() 关闭路径，本文件已不再使用。
  // 关闭拦截此时仍开着：SC_CLOSE 会被 preventClose 再次拦下，必须先解除。
  try {
    await windowManager.setPreventClose(false);
  } on Exception {
    // window_manager 不可用时 controller.close() 本就直接销毁。
  }
  final controller = _overlayWindowController;
  if (controller != null) {
    await controller.close();
  }
}

class _OverlayModel extends ChangeNotifier {
  _OverlayModel({
    required DesktopLyricsSettings settings,
    required String current,
    required String next,
    required bool isPlaying,
    double progress = 0.0,
    bool activeOnBottom = false,
  }) : _settings = settings,
       _current = current,
       _next = next,
       _isPlaying = isPlaying,
       _progress = progress,
       _activeOnBottom = activeOnBottom;

  DesktopLyricsSettings _settings;
  String _current;
  String _next;
  bool _isPlaying;
  double _progress;
  bool _activeOnBottom;

  DesktopLyricsSettings get settings => _settings;
  String get current => _current;
  String get next => _next;
  bool get isPlaying => _isPlaying;
  double get progress => _progress;

  /// 双行交替高亮：当前句是否落在下行（主窗按歌词行下标奇偶下发）。
  bool get activeOnBottom => _activeOnBottom;

  set settings(DesktopLyricsSettings value) {
    if (_settings == value) return;
    _settings = value;
    notifyListeners();
  }

  set current(String value) {
    if (_current == value) return;
    _current = value;
    notifyListeners();
  }

  set next(String value) {
    if (_next == value) return;
    _next = value;
    notifyListeners();
  }

  set isPlaying(bool value) {
    if (_isPlaying == value) return;
    _isPlaying = value;
    notifyListeners();
  }

  set progress(double value) {
    if (_progress == value) return;
    _progress = value;
    notifyListeners();
  }

  set activeOnBottom(bool value) {
    if (_activeOnBottom == value) return;
    _activeOnBottom = value;
    notifyListeners();
  }
}

class _LyricsOverlayApp extends StatelessWidget {
  const _LyricsOverlayApp({required this.model});

  final _OverlayModel model;

  @override
  Widget build(BuildContext context) {
    // 与主窗一致：Windows 桌面排除语义树，规避 AXTree 竞态崩溃
    // （上游 flutter/flutter#190357 / #192180 未修复，详见 main.dart）。
    return ExcludeSemantics(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: _LyricsOverlayHome(model: model),
      ),
    );
  }
}

class _LyricsOverlayHome extends StatefulWidget {
  const _LyricsOverlayHome({required this.model});

  final _OverlayModel model;

  @override
  State<_LyricsOverlayHome> createState() => _LyricsOverlayHomeState();
}

class _LyricsOverlayHomeState extends State<_LyricsOverlayHome>
    with WindowListener {
  Timer? _persistDebounce;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    // 取消未触发的防抖保存并立即补存一次，避免最后一次移动丢失；
    // 标记意图一并带上（见 _userDragPersistPending）。
    _persistDebounce?.cancel();
    unawaited(
      persistOverlayWindowPosition(
        markPositionSemanticsCurrent: _takeUserDragPersistPending(),
      ),
    );
    windowManager.removeListener(this);
    super.dispose();
  }

  // 拖动为原生模态循环，PointerUp 不一定派发回 Flutter；
  // onWindowMoved 在移动循环结束后触发，是持久化位置的可靠时机。
  // WM_MOVE 期间会密集回调，防抖合并为停止 500ms 后的一次落盘。
  @override
  void onWindowMoved() {
    if (_suppressNextMovePersist) {
      _suppressNextMovePersist = false;
      return;
    }
    _persistDebounce?.cancel();
    _userDragPersistPending = true;
    _persistDebounce = Timer(_kPersistDebounce, () {
      _userDragPersistPending = false;
      // 用户拖动落盘：位置必为现行窗口语义，连带置位迁移键（见
      // persistOverlayWindowPosition 的参数说明）。
      unawaited(
        persistOverlayWindowPosition(markPositionSemanticsCurrent: true),
      );
    });
  }

  /// 外部关闭（Alt+F4/任务栏关闭）：ensureInitialized 阶段已
  /// setPreventClose(true)，WM_CLOSE 被拦截转到这里而非直接销毁——
  /// 否则主窗零感知（包的 OnWindowClose 是空实现），桥接状态失步、
  /// 歌词静默冻结。统一走 closeLyricsOverlayWindow 漏斗。
  @override
  void onWindowClose() {
    unawaited(closeLyricsOverlayWindow());
  }

  Future<void> _controlPlayback(String action) async {
    try {
      await DesktopMultiWindow.invokeMethod(0, 'controlPlayback', action);
    } catch (e) {
      debugPrint('[桌面歌词悬浮窗] 发送播控指令 $action 失败: $e');
    }
  }

  /// 工具栏锁定按钮：只上报主窗，不本地直改锁定状态。由主窗落盘并经
  /// updateSettings 回推后统一重建子树 + 重设穿透（QQ 音乐式语义：
  /// 锁定即全穿透，解锁入口在主窗设置页/托盘）。
  Future<void> _setLocked(bool locked) async {
    try {
      await DesktopMultiWindow.invokeMethod(0, 'setLyricsLocked', locked);
    } catch (e) {
      debugPrint('[桌面歌词悬浮窗] 上报锁定状态 locked=$locked 失败: $e');
    }
  }

  Future<void> _updateSettings(DesktopLyricsSettings settings) async {
    widget.model.settings = settings;
    try {
      await DesktopMultiWindow.invokeMethod(
        0,
        'updateOverlaySettings',
        settings.toMap(),
      );
    } catch (e) {
      debugPrint('updateOverlaySettings failed: $e');
    }
  }

  Future<void> _openDetailedSettings() async {
    try {
      await DesktopMultiWindow.invokeMethod(0, 'openLyricsSettings');
    } catch (e) {
      debugPrint('openLyricsSettings failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final model = widget.model;
        return DesktopLyricsOverlayContent(
          settings: model.settings,
          current: model.current,
          next: model.next,
          isPlaying: model.isPlaying,
          progress: model.progress,
          activeOnBottom: model.activeOnBottom,
          onControlPlayback: (action) => unawaited(_controlPlayback(action)),
          onToggleLock: (locked) => unawaited(_setLocked(locked)),
          onClose: () => unawaited(closeLyricsOverlayWindow()),
          onUpdateSettings: (settings) => unawaited(_updateSettings(settings)),
          onOpenDetailedSettings: () => unawaited(_openDetailedSettings()),
        );
      },
    );
  }
}

/// 悬浮窗内容（公开以便桌面歌词单测直接校验锁定/解锁两套子树）。
///
/// - locked：纯歌词常显（QQ 音乐式全穿透）——**无** MouseRegion、无工具栏、
///   无容器背景/边框/hover 卡片；穿透后窗口收不到任何鼠标事件，独立子树
///   用于杜绝过渡帧残留任何 hover UI。
/// - 未锁定：保留悬停卡片 + 工具栏（播控/锁定/关闭），整卡可拖动。
class DesktopLyricsOverlayContent extends StatelessWidget {
  const DesktopLyricsOverlayContent({
    super.key,
    required this.settings,
    required this.current,
    required this.next,
    required this.isPlaying,
    this.progress = 0.0,
    this.activeOnBottom = false,
    required this.onControlPlayback,
    required this.onToggleLock,
    required this.onClose,
    this.onUpdateSettings,
    this.onOpenDetailedSettings,
    this.cursorPositionProvider,
    this.windowPositionProvider,
    this.ignoreMouseEventsSetter,
    this.appFocusedProvider,
  });

  final DesktopLyricsSettings settings;
  final String current;
  final String next;
  final bool isPlaying;
  final double progress;

  /// 双行交替高亮：当前句是否落在下行（主窗按歌词行下标奇偶下发）。
  final bool activeOnBottom;
  final ValueChanged<String> onControlPlayback;

  /// 参数为目标锁定状态（true=锁定）。
  final ValueChanged<bool> onToggleLock;
  final VoidCallback onClose;
  final ValueChanged<DesktopLyricsSettings>? onUpdateSettings;
  final VoidCallback? onOpenDetailedSettings;
  final Future<Offset?> Function()? cursorPositionProvider;
  final Future<Offset?> Function()? windowPositionProvider;
  final Future<void> Function(bool ignore)? ignoreMouseEventsSetter;
  final Future<bool> Function()? appFocusedProvider;

  @override
  Widget build(BuildContext context) {
    final Widget child = settings.locked
        ? _LockedLyricsBody(
            settings: settings,
            current: current,
            next: next,
            progress: progress,
            activeOnBottom: activeOnBottom,
            onToggleLock: onToggleLock,
            cursorPositionProvider: cursorPositionProvider,
            windowPositionProvider: windowPositionProvider,
            ignoreMouseEventsSetter: ignoreMouseEventsSetter,
          )
        : _HoverableOverlay(
            settings: settings,
            current: current,
            next: next,
            isPlaying: isPlaying,
            progress: progress,
            activeOnBottom: activeOnBottom,
            onControlPlayback: onControlPlayback,
            onToggleLock: onToggleLock,
            onClose: onClose,
            onUpdateSettings: onUpdateSettings,
            onOpenDetailedSettings: onOpenDetailedSettings,
            cursorPositionProvider: cursorPositionProvider,
            windowPositionProvider: windowPositionProvider,
            ignoreMouseEventsSetter: ignoreMouseEventsSetter,
            appFocusedProvider: appFocusedProvider,
          );
    return Material(type: MaterialType.transparency, child: child);
  }
}

/// 锁定态：歌词文字常显，悬停窗口淡入「🔒 解锁」胶囊徽标，悬停徽标临时解除穿透以响应点击解锁。
@visibleForTesting
class LockedLyricsBody extends StatefulWidget {
  const LockedLyricsBody({
    super.key,
    required this.settings,
    required this.current,
    required this.next,
    this.progress = 0.0,
    this.activeOnBottom = false,
    required this.onToggleLock,
    this.cursorPositionProvider,
    this.windowPositionProvider,
    this.ignoreMouseEventsSetter,
  });

  final DesktopLyricsSettings settings;
  final String current;
  final String next;
  final double progress;
  final bool activeOnBottom;
  final ValueChanged<bool> onToggleLock;
  final Future<Offset?> Function()? cursorPositionProvider;
  final Future<Offset?> Function()? windowPositionProvider;
  final Future<void> Function(bool ignore)? ignoreMouseEventsSetter;

  @override
  State<LockedLyricsBody> createState() => _LockedLyricsBodyState();
}

typedef _LockedLyricsBody = LockedLyricsBody;

class _LockedLyricsBodyState extends State<LockedLyricsBody> {
  bool _isHoveringWindow = false;
  bool _isHoveringPill = false;
  bool _polling = false;
  Timer? _pollTimer;
  int _pollTickCount = 0;
  Offset? _cachedWindowPos;

  @override
  void initState() {
    super.initState();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      _pollCursor();
    });
  }

  @override
  void didUpdateWidget(covariant LockedLyricsBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部（主窗设置推送）收到 updateSettings 会无条件重施
    // setIgnoreMouseEvents(locked)：用户正悬浮胶囊时穿透被加了回去，而本地
    // hover 标记仍为 true，轮询只认"状态迁移"就永远不会再恢复点击（胶囊
    // 死锁到光标移出再进）。重置标记后，下一轮轮询（≤80ms）按"新进入
    // 胶囊"重新解除穿透。
    if (oldWidget.settings != widget.settings) {
      _isHoveringWindow = false;
      _isHoveringPill = false;
      _cachedWindowPos = null;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _setIgnoreMouseEvents(bool ignore) async {
    try {
      if (widget.ignoreMouseEventsSetter != null) {
        await widget.ignoreMouseEventsSetter!(ignore);
      } else {
        await windowManager.setIgnoreMouseEvents(ignore);
      }
    } catch (_) {}
  }

  Future<void> _pollCursor() async {
    if (_polling) return;
    _polling = true;
    try {
      Offset? cursorPos;
      try {
        cursorPos = widget.cursorPositionProvider != null
            ? await widget.cursorPositionProvider!()
            : await windowManager.getCursorScreenPoint();
      } catch (_) {}

      // 窗口位置只在拖动/主窗复位时变化（锁定态穿透后根本无法拖动），
      // 每轮都查纯是平台通道往返浪费：缓存并每 ~1s 校准一次，
      // 平时每轮只查光标（通道调用从 2 次/轮降到 1 次/轮）。
      _pollTickCount++;
      if (_cachedWindowPos == null || _pollTickCount % 12 == 0) {
        try {
          _cachedWindowPos = widget.windowPositionProvider != null
              ? await widget.windowPositionProvider!()
              : await windowManager.getPosition();
        } catch (_) {}
      }
      final windowPos = _cachedWindowPos;

      if (!mounted || cursorPos == null || windowPos == null) return;

      // 命中判定只认卡片带（窗口底部 overlayHeight 高）：常驻菜单带在
      // 锁定态无内容且穿透，光标扫过菜单带不应触发解锁胶囊淡入。
      final cardBandTop =
          windowPos.dy + WindowsDesktopLyricsBridge.overlayMenuPanelHeight;
      final winRect = Rect.fromLTWH(
        windowPos.dx,
        cardBandTop,
        WindowsDesktopLyricsBridge.overlayWidth,
        WindowsDesktopLyricsBridge.overlayHeight,
      );
      const pillWidth = 84.0;
      const pillHeight = 24.0;
      final pillLeft =
          windowPos.dx +
          (WindowsDesktopLyricsBridge.overlayWidth - pillWidth) / 2;
      final pillTop = cardBandTop + 2.0;
      final pillRect = Rect.fromLTWH(pillLeft, pillTop, pillWidth, pillHeight);

      if (winRect.contains(cursorPos)) {
        var stateChanged = false;
        if (!_isHoveringWindow) {
          _isHoveringWindow = true;
          stateChanged = true;
        }
        if (pillRect.contains(cursorPos)) {
          if (!_isHoveringPill) {
            _isHoveringPill = true;
            stateChanged = true;
            await _setIgnoreMouseEvents(false);
          }
        } else {
          if (_isHoveringPill) {
            _isHoveringPill = false;
            stateChanged = true;
            await _setIgnoreMouseEvents(true);
          }
        }
        if (!mounted) return;
        if (stateChanged) {
          setState(() {});
        }
      } else {
        if (_isHoveringWindow || _isHoveringPill) {
          _isHoveringWindow = false;
          _isHoveringPill = false;
          await _setIgnoreMouseEvents(true);
          if (!mounted) return;
          setState(() {});
        }
      }
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: WindowsDesktopLyricsBridge.overlayWidth,
      height: WindowsDesktopLyricsBridge.overlayWindowHeight,
      child: Stack(
        children: [
          // 歌词主体限定在卡片带（窗口底部 124 高）：窗口常驻展开高度后
          // 不能再任由其填满整窗（上方是常驻菜单带，锁定态无内容）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: WindowsDesktopLyricsBridge.overlayHeight,
            child: buildOverlayLyricsBody(
              settings: widget.settings,
              current: widget.current,
              next: widget.next,
              progress: widget.progress,
              activeOnBottom: widget.activeOnBottom,
            ),
          ),
          // 解锁胶囊：卡片顶之上的专属带内顶部居中（与未锁定态工具栏同带）。
          Positioned(
            left: 0,
            right: 0,
            bottom: WindowsDesktopLyricsBridge.overlayLyricsHeight,
            height: WindowsDesktopLyricsBridge.lyricsTopInset,
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 2.0),
                child: AnimatedOpacity(
                  opacity: _isHoveringWindow ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 180),
                  child: IgnorePointer(
                    ignoring: !_isHoveringWindow,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onToggleLock(false),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Container(
                          width: 84.0,
                          height: 24.0,
                          decoration: BoxDecoration(
                            color: const Color(0xCC333333),
                            borderRadius: BorderRadius.circular(12.0),
                            border: Border.all(
                              color: Colors.white.withValues(
                                alpha: _isHoveringPill ? 0.35 : 0.15,
                              ),
                              width: 0.5,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.lock_rounded,
                                size: 13.0,
                                color: Colors.white,
                              ),
                              SizedBox(width: 4.0),
                              Text(
                                '解锁',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.0,
                                  fontWeight: FontWeight.w500,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

@visibleForTesting
typedef HoverableOverlay = _HoverableOverlay;

/// 未锁定态：卡片带贴窗口底常显，悬停淡入暗色卡片 + 顶部工具栏，整卡可拖动；
/// 快捷菜单在卡片上方的常驻菜单带内淡入/滑出（窗口尺寸不变，零原生
/// resize —— 消除 DWM 拉伸中间帧导致的"闪一下"）。
///
/// 命中测试（穿透）由光标轮询驱动：菜单带平时整带穿透（不挡下层应用
/// 点击），光标进入卡片带或菜单展开期间进入窗口才解除穿透。
class _HoverableOverlay extends StatefulWidget {
  const _HoverableOverlay({
    required this.settings,
    required this.current,
    required this.next,
    required this.isPlaying,
    this.progress = 0.0,
    this.activeOnBottom = false,
    required this.onControlPlayback,
    required this.onToggleLock,
    required this.onClose,
    this.onUpdateSettings,
    this.onOpenDetailedSettings,
    this.cursorPositionProvider,
    this.windowPositionProvider,
    this.ignoreMouseEventsSetter,
    this.appFocusedProvider,
  });

  final DesktopLyricsSettings settings;
  final String current;
  final String next;
  final bool isPlaying;
  final double progress;
  final bool activeOnBottom;
  final ValueChanged<String> onControlPlayback;
  final ValueChanged<bool> onToggleLock;
  final VoidCallback onClose;
  final ValueChanged<DesktopLyricsSettings>? onUpdateSettings;
  final VoidCallback? onOpenDetailedSettings;

  /// 光标屏幕坐标（默认 windowManager.getCursorScreenPoint）。
  final Future<Offset?> Function()? cursorPositionProvider;

  /// 窗口逻辑坐标（默认 windowManager.getPosition）。
  final Future<Offset?> Function()? windowPositionProvider;

  /// 设置整窗穿透（默认 windowManager.setIgnoreMouseEvents）。
  final Future<void> Function(bool ignore)? ignoreMouseEventsSetter;

  /// 本窗口是否为系统前台窗口（默认 windowManager.isFocused()）。
  final Future<bool> Function()? appFocusedProvider;

  @override
  State<_HoverableOverlay> createState() => _HoverableOverlayState();
}

class _HoverableOverlayState extends State<_HoverableOverlay> {
  /// 光标位于卡片带内（驱动卡片背景与工具栏淡入）。
  bool _hovering = false;

  /// 快捷菜单展开中。
  bool _showSettingsMenu = false;

  /// 当前窗口是否处于"接收鼠标"状态（false = 整窗穿透）。
  /// 光标轮询驱动：卡片带命中或菜单展开期间命中窗口即解除穿透。
  bool _windowInteractive = false;

  bool _polling = false;
  Timer? _pollTimer;

  /// 菜单展开期间是否至少观察到一次"本窗是前台窗口"。
  /// 悬浮窗在不抢焦点的环境下 isFocused 恒为 false，不能据此直接关菜单，
  /// 否则菜单一开就被立刻收起。
  bool _menuSawFocus = false;
  Timer? _menuFocusTimer;
  Timer? _mouseOutCloseTimer;

  /// 光标轮询间隔：命中区域判定（穿透切换、hover、移出收起）的节拍。
  /// 与锁定态解锁胶囊轮询同款（80ms 在交互延迟与通道开销间折中）。
  static const Duration _kPollInterval = Duration(milliseconds: 80);

  /// 菜单展开后光标移出整窗多久自动收起（覆盖失焦判定失效的环境）。
  static const Duration _kMenuMouseOutCloseDelay = Duration(milliseconds: 800);

  /// 快捷菜单淡入/滑出时长：纯 Flutter 隐式动画（窗口几何不动）。
  static const Duration _kMenuTransition = Duration(milliseconds: 160);

  @override
  void initState() {
    super.initState();
    // 只用周期轮询、不做 initState 首拍：子窗启动路径上窗口尚未 show()，
    // 隐藏期施加 setIgnoreMouseEvents(true) 会给窗口加 WS_EX_LAYERED，
    // 导致 DComp 内容面永久空白（见 OverlayPassthroughScheduler 注释）。
    // show() 在首帧后的 postFrameCallback 里完成，远早于 80ms 后的
    // 首个轮询拍，穿透校准不受影响。
    _pollTimer = Timer.periodic(_kPollInterval, (_) {
      unawaited(_pollCursor());
    });
  }

  @override
  void dispose() {
    _stopMenuDismissWatch();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<Offset?> _getCursorPosition() async {
    try {
      final provider = widget.cursorPositionProvider;
      if (provider != null) return await provider();
      return await windowManager.getCursorScreenPoint();
    } on Exception {
      return null;
    }
  }

  Future<Offset?> _getWindowPosition() async {
    try {
      final provider = widget.windowPositionProvider;
      if (provider != null) return await provider();
      return await windowManager.getPosition();
    } on Exception {
      return null;
    }
  }

  Future<void> _setIgnoreMouseEvents(bool ignore) async {
    try {
      final setter = widget.ignoreMouseEventsSetter;
      if (setter != null) {
        await setter(ignore);
      } else {
        await windowManager.setIgnoreMouseEvents(ignore);
      }
    } on Exception {
      // 穿透设置失败不影响展示（与锁定态胶囊同策略）。
    }
  }

  /// 光标轮询：命中测试 + hover + 移出收起。
  ///
  /// 命中区域（窗口逻辑坐标）：
  /// - 卡片带 = [top + menuPanelHeight, top + overlayWindowHeight]（底部
  ///   [overlayHeight] 高）—— 恒为交互区（hover 卡片/工具栏/拖动）；
  /// - 菜单带 = 卡片带上方 —— 仅在菜单展开时并入交互区（点菜单项）。
  Future<void> _pollCursor() async {
    if (_polling) return;
    _polling = true;
    try {
      final cursorPos = await _getCursorPosition();
      final windowPos = await _getWindowPosition();
      if (!mounted || cursorPos == null || windowPos == null) return;

      final cardBandTop =
          windowPos.dy + WindowsDesktopLyricsBridge.overlayMenuPanelHeight;
      final inCard =
          cursorPos.dy >= cardBandTop &&
          cursorPos.dy <=
              windowPos.dy + WindowsDesktopLyricsBridge.overlayWindowHeight &&
          cursorPos.dx >= windowPos.dx &&
          cursorPos.dx <=
              windowPos.dx + WindowsDesktopLyricsBridge.overlayWidth;
      final inWindow =
          cursorPos.dy >= windowPos.dy &&
          cursorPos.dy <=
              windowPos.dy + WindowsDesktopLyricsBridge.overlayWindowHeight &&
          cursorPos.dx >= windowPos.dx &&
          cursorPos.dx <=
              windowPos.dx + WindowsDesktopLyricsBridge.overlayWidth;

      // 菜单展开期间整窗可交互（菜单在菜单带）；收起后仅卡片带可交互，
      // 菜单带恢复穿透，不挡下层应用点击。
      final wantInteractive = inCard || (_showSettingsMenu && inWindow);
      if (wantInteractive != _windowInteractive) {
        _windowInteractive = wantInteractive;
        await _setIgnoreMouseEvents(!wantInteractive);
        if (!mounted) return;
      }

      if (inCard != _hovering) {
        setState(() => _hovering = inCard);
      }

      // 移出收起：菜单展开且光标已离开整窗一段时间。
      if (_showSettingsMenu && !inWindow) {
        _mouseOutCloseTimer ??= Timer(_kMenuMouseOutCloseDelay, () {
          _mouseOutCloseTimer = null;
          if (!mounted || _hovering || !_showSettingsMenu) return;
          _setSettingsMenuVisible(false);
        });
      } else {
        _mouseOutCloseTimer?.cancel();
        _mouseOutCloseTimer = null;
      }
    } finally {
      _polling = false;
    }
  }

  void _setSettingsMenuVisible(bool visible) {
    if (_showSettingsMenu == visible) return;
    setState(() => _showSettingsMenu = visible);
    if (visible) {
      _startMenuDismissWatch();
    } else {
      _stopMenuDismissWatch();
    }
    // 菜单收展改变命中区域（整窗 ↔ 仅卡片带）：立即轮询一拍，不等下个
    // 周期，收起瞬间菜单带即刻恢复穿透。
    unawaited(_pollCursor());
  }

  /// 菜单展开期间的关闭看门狗：
  /// 1) 轮询本窗是否仍是系统前台窗口 —— 用户点了别的软件即刻收起；
  /// 2) 鼠标移出整个窗口并停留 800ms —— 覆盖"窗口从不被激活、isFocused
  ///    恒为 false"的环境（此时第 1 条永远无法判定）。
  void _startMenuDismissWatch() {
    _menuSawFocus = false;
    _menuFocusTimer?.cancel();
    _menuFocusTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      unawaited(_checkMenuFocus());
    });
  }

  void _stopMenuDismissWatch() {
    _menuFocusTimer?.cancel();
    _menuFocusTimer = null;
    _mouseOutCloseTimer?.cancel();
    _mouseOutCloseTimer = null;
    _menuSawFocus = false;
  }

  Future<void> _checkMenuFocus() async {
    if (!_showSettingsMenu) {
      _stopMenuDismissWatch();
      return;
    }
    final focused = await _isAppFocused();
    if (!mounted || !_showSettingsMenu) return;
    if (focused) {
      _menuSawFocus = true;
      return;
    }
    if (_menuSawFocus) {
      _setSettingsMenuVisible(false);
    }
  }

  Future<bool> _isAppFocused() async {
    try {
      final provider = widget.appFocusedProvider;
      if (provider != null) return await provider();
      return await windowManager.isFocused();
    } catch (e) {
      // 查询失败（插件未就绪等）：保守认为仍在前台，绝不误关菜单。
      debugPrint('[桌面歌词悬浮窗] 前台状态查询失败: $e');
      return true;
    }
  }

  void _updateSettings(DesktopLyricsSettings newSettings) {
    // Update local model for immediate response
    widget.onUpdateSettings?.call(newSettings);
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;

    // 常态：背景纯透明（若用户在设置中显式调高 opacity 则兼容展示）
    // 悬停：平滑淡入现代半透暗调卡片背景（0xCC141823）
    final cardColor = _hovering
        ? const Color(0xCC141823)
        : (settings.opacity > 0
              ? Color(
                  settings.backgroundColor,
                ).withValues(alpha: settings.opacity.clamp(0.0, 1.0))
              : Colors.transparent);

    final cardBorder = _hovering
        ? Border.all(color: Colors.white.withValues(alpha: 0.12), width: 1.0)
        : null;

    final cardShadows = _hovering
        ? [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ]
        : null;

    final showToolbar = _hovering || _showSettingsMenu;

    // 布局契约：窗口常驻展开高度（菜单带 + 卡片带），卡片带贴窗口底，
    // 全部锚点以窗口底边为基准 —— 与 MediaQuery 无关，彻底杜绝
    // "窗口几何与 metrics 到达时序不同步"的中间帧（历史实现读
    // MediaQuery.sizeOf，resize 落地与 metrics 更新之间的任何 rebuild
    // 都会按旧高度推卡片位置，跳一帧）。
    return SizedBox(
      width: WindowsDesktopLyricsBridge.overlayWidth,
      height: WindowsDesktopLyricsBridge.overlayWindowHeight,
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 菜单带（卡片带上方）：快捷菜单在此淡入/滑出。收起态整带
            // 透明且 IgnorePointer + 原生穿透（见 _pollCursor），不挡
            // 下层应用点击；展开态点带内空白即收起。
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: WindowsDesktopLyricsBridge.overlayMenuPanelHeight,
              child: IgnorePointer(
                ignoring: !_showSettingsMenu,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setSettingsMenuVisible(false),
                  child: AnimatedOpacity(
                    opacity: _showSettingsMenu ? 1.0 : 0.0,
                    duration: _kMenuTransition,
                    child: AnimatedSlide(
                      offset: _showSettingsMenu
                          ? Offset.zero
                          : const Offset(0, -0.15),
                      duration: _kMenuTransition,
                      curve: Curves.easeOutCubic,
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4, right: 8),
                          child: _OverlayQuickSettingsMenu(
                            settings: settings,
                            onControlPlayback: widget.onControlPlayback,
                            onUpdateSettings: (newSettings) {
                              _updateSettings(newSettings);
                            },
                            onOpenDetailedSettings: () {
                              // 先让主窗把设置页带起来（用户注意力随之
                              // 切走），再淡出菜单 —— 收起动作在背后完成。
                              widget.onOpenDetailedSettings?.call();
                              _setSettingsMenuVisible(false);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 卡片带：贴窗口底（恒定 124 高，菜单收展不影响其几何）。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: WindowsDesktopLyricsBridge.overlayHeight,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: cardBorder,
                  boxShadow: cardShadows,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: DragToMoveArea(
                    child: Container(
                      color: Colors.transparent,
                      child: buildOverlayLyricsBody(
                        settings: settings,
                        current: widget.current,
                        next: widget.next,
                        progress: widget.progress,
                        activeOnBottom: widget.activeOnBottom,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 工具栏专属带：卡片顶之上 [lyricsTopInset] 高的带子，右下锚定
            // （右 8、底 2 = 历史的卡片顶 +2）。
            Positioned(
              left: 0,
              right: 0,
              bottom: WindowsDesktopLyricsBridge.overlayLyricsHeight,
              height: WindowsDesktopLyricsBridge.lyricsTopInset,
              child: AnimatedOpacity(
                opacity: showToolbar ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                child: IgnorePointer(
                  ignoring: !showToolbar,
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8, bottom: 2),
                      child: _buildOverlayToolbar(context),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlayToolbar(BuildContext context) {
    final settings = widget.settings;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolbarButton(
            icon: Icons.skip_previous_rounded,
            tooltip: '上一曲',
            iconSize: 20,
            onPressed: () => widget.onControlPlayback('previous'),
          ),
          const SizedBox(width: 2),
          _ToolbarButton(
            icon: widget.isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            tooltip: widget.isPlaying ? '暂停' : '播放',
            iconSize: 20,
            onPressed: () => widget.onControlPlayback('togglePlay'),
          ),
          const SizedBox(width: 2),
          _ToolbarButton(
            icon: Icons.skip_next_rounded,
            tooltip: '下一曲',
            iconSize: 20,
            onPressed: () => widget.onControlPlayback('next'),
          ),
          Container(
            width: 1,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: Colors.white.withValues(alpha: 0.18),
          ),
          _ToolbarButton(
            icon: settings.locked
                ? Icons.lock_rounded
                : Icons.lock_open_rounded,
            tooltip: settings.locked ? '解锁歌词' : '锁定歌词',
            iconSize: 20,
            onPressed: () => widget.onToggleLock(!settings.locked),
          ),
          const SizedBox(width: 2),
          _ToolbarButton(
            icon: Icons.settings_rounded,
            tooltip: '桌面歌词设置',
            iconSize: 20,
            isActive: _showSettingsMenu,
            onPressed: () => _setSettingsMenuVisible(!_showSettingsMenu),
          ),
          const SizedBox(width: 2),
          _ToolbarButton(
            icon: Icons.close_rounded,
            tooltip: '关闭桌面歌词',
            iconSize: 20,
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}

/// 歌词主体（锁定/未锁定两套子树共用）：单行居中或双行交替（乒乓）高亮排版。
///
/// 布局契约：紧约束 SizedBox(780x124) + 顶部 [WindowsDesktopLyricsBridge
/// .lyricsTopInset] 留给工具栏/解锁胶囊 + 水平 24 Padding + FittedBox(scaleDown)
/// + 固定宽度（悬浮窗宽 - 48）的容器。
/// 顶部留白是"按钮不再压住歌词"的关键：历史 88px 单带布局下 30px 按钮
/// （y2~36）与双行歌词渲染区（约 y20~74）恒重叠约 16px，调位置无解。
/// 紧约束保证内容超过歌词带高度（系统字体缩放/48sp 大字号）时整体等比
/// 缩小，而不是 RenderFlex 垂直溢出（溢出黄黑条纹会常驻窗口底部）。
///
/// 双行排布（[activeOnBottom] 由主窗按"当前句下标奇偶"下发）：
/// - 正在唱的那行带动画进度（已播放色逐字变色 + 跑马灯），另一行是下一句
///   （未播放色轻度弱化、progress 0）；
/// - 高亮在上下两行之间**交替**：唱到下行时上行换成下一句、唱到上行时下行
///   换成下一句 —— 正在唱的那句文字永远留在原地，消除历史实现里
///   "每句都要从下行搬到上行"的跳行观感；
/// - 横向锚点由 alignment 决定：split = 上行居左/下行居右（对角交错），
///   center/left/right = 上下两行同侧（此时交替完全没有位移）。
Widget buildOverlayLyricsBody({
  required DesktopLyricsSettings settings,
  required String current,
  required String next,
  double progress = 0.0,
  bool activeOnBottom = false,
}) {
  final playedColor = Color(settings.playedTextColor);
  final unplayedColor = Color(settings.unplayedTextColor);
  final isSplit = DesktopLyricsAlignment.isSplit(settings.alignment);
  // 单行下 split 无"上下两行"可分，渲染等价居中。
  final singleLineAlign = switch (settings.alignment) {
    DesktopLyricsAlignment.left => TextAlign.left,
    DesktopLyricsAlignment.right => TextAlign.right,
    _ => TextAlign.center,
  };
  // 双行同侧对齐时的共享锚点（split 走各自的对角锚点，不取此值）。
  final sharedAlign = switch (settings.alignment) {
    DesktopLyricsAlignment.left => Alignment.centerLeft,
    DesktopLyricsAlignment.right => Alignment.centerRight,
    _ => Alignment.center,
  };
  final sharedTextAlign = switch (settings.alignment) {
    DesktopLyricsAlignment.left => TextAlign.left,
    DesktopLyricsAlignment.right => TextAlign.right,
    _ => TextAlign.center,
  };

  const horizontalPadding = 24.0;
  final contentWidth =
      WindowsDesktopLyricsBridge.overlayWidth - (horizontalPadding * 2);

  final Widget body;
  if (settings.singleLine) {
    // 单行模式：歌词带内垂直居中展示单行逐字变色/跑马灯歌词
    body = LyricsKaraokeLine(
      text: current.isEmpty ? '暂无歌词' : current,
      fontSize: settings.fontSize,
      playedColor: playedColor,
      unplayedColor: unplayedColor,
      progress: progress,
      availableWidth: contentWidth,
      alignment: singleLineAlign,
      textOpacity: settings.textOpacity,
      fontWeight: FontWeight.bold,
    );
  } else {
    // 双行交替排版：上下两行统一字号（settings.fontSize * 0.82）与 bold 字重，
    // 仅用"已播放金黄高亮 / 未播放天蓝降透明度"区分正在唱与下一句。
    final dualLineWidth = contentWidth - 60.0;
    final dualFontSize = settings.fontSize * 0.82;
    final activeText = current.isEmpty ? '暂无歌词' : current;

    Widget dualLine({
      required String text,
      required bool active,
      required Alignment align,
      required TextAlign textAlign,
    }) {
      // 下一句只做轻度弱化（颜色 alpha 0.85），不再叠 textOpacity 折扣：
      // 悬浮窗背景默认全透明，双重压暗会让下一句糊在桌面上看不清
      //（用户反馈）。层级区分靠 1.0 与 0.85 的轻微差异即可。
      return Align(
        alignment: align,
        child: LyricsKaraokeLine(
          text: text,
          fontSize: dualFontSize,
          playedColor: playedColor,
          unplayedColor: active
              ? unplayedColor
              : unplayedColor.withValues(alpha: 0.85),
          progress: active ? progress : 0.0,
          availableWidth: dualLineWidth,
          alignment: textAlign,
          textOpacity: settings.textOpacity,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        dualLine(
          text: activeOnBottom ? next : activeText,
          active: !activeOnBottom,
          align: isSplit ? Alignment.centerLeft : sharedAlign,
          textAlign: isSplit ? TextAlign.left : sharedTextAlign,
        ),
        const SizedBox(height: 4),
        dualLine(
          text: activeOnBottom ? activeText : next,
          active: activeOnBottom,
          align: isSplit ? Alignment.centerRight : sharedAlign,
          textAlign: isSplit ? TextAlign.right : sharedTextAlign,
        ),
      ],
    );
  }

  // RepaintBoundary：逐字进度消息以最高 30Hz 到达，每次都会触发歌词行
  // 重绘；独立成层后工具栏/解锁胶囊/快捷菜单不必随之重新光栅化。
  return RepaintBoundary(
    child: SizedBox(
      width: WindowsDesktopLyricsBridge.overlayWidth,
      height: WindowsDesktopLyricsBridge.overlayHeight,
      child: Padding(
        // 顶部 lyricsTopInset 是工具栏/解锁胶囊的专属带（锁定态为负空间）：
        // 歌词只在下方歌词带内居中，与按钮彻底脱开。
        padding: const EdgeInsets.only(
          top: WindowsDesktopLyricsBridge.lyricsTopInset,
          bottom: 2.0,
          left: horizontalPadding,
          right: horizontalPadding,
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(width: contentWidth, child: body),
          ),
        ),
      ),
    ),
  );
}

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 20,
    this.isActive = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;
  final bool isActive;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: AppDesktopTheme.tooltipWaitDuration,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: (widget.isActive || _hovered)
                  ? Colors.white.withValues(
                      alpha: widget.isActive ? 0.28 : 0.18,
                    )
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: (widget.isActive || _hovered)
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.88),
            ),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
typedef OverlayQuickSettingsMenu = _OverlayQuickSettingsMenu;

/// 桌面歌词悬浮工具栏快捷调节菜单（字号加减、歌词进度、歌词配色方案、
/// 单双行切换、更多设置）。
class _OverlayQuickSettingsMenu extends StatelessWidget {
  const _OverlayQuickSettingsMenu({
    required this.settings,
    required this.onControlPlayback,
    required this.onUpdateSettings,
    required this.onOpenDetailedSettings,
  });

  final DesktopLyricsSettings settings;

  /// 播控/进度指令下发通道（复用悬浮窗既有的 controlPlayback 动作通道，
  /// 由主窗把它们落到 PlayerController.lyricOffset）。
  final ValueChanged<String> onControlPlayback;
  final ValueChanged<DesktopLyricsSettings> onUpdateSettings;
  final VoidCallback onOpenDetailedSettings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xEE1A1E2C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. 字体大小
          Row(
            children: [
              const Text(
                '字体大小',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const Spacer(),
              _buildStepButton(
                icon: Icons.remove,
                onTap: () {
                  final newSize = (settings.fontSize - 2).clamp(
                    DesktopLyricsSettings.fontSizeMin,
                    DesktopLyricsSettings.fontSizeMax,
                  );
                  onUpdateSettings(settings.copyWith(fontSize: newSize));
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  '${settings.fontSize.round()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _buildStepButton(
                icon: Icons.add,
                onTap: () {
                  final newSize = (settings.fontSize + 2).clamp(
                    DesktopLyricsSettings.fontSizeMin,
                    DesktopLyricsSettings.fontSizeMax,
                  );
                  onUpdateSettings(settings.copyWith(fontSize: newSize));
                },
              ),
            ],
          ),
          Divider(
            height: 12,
            thickness: 0.5,
            color: Colors.white.withValues(alpha: 0.10),
          ),
          // 2. 歌词进度（时间偏移）：与播放页共用同一份偏移状态，子窗只发
          //    指令，结果沿既有歌词推送回流（见 PlayerController 的
          //    lyricOffsetEarlier/Later/Reset）。
          Row(
            children: [
              const Text(
                '歌词进度',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const Spacer(),
              _buildStepButton(
                icon: Icons.keyboard_double_arrow_left_rounded,
                tooltip: '歌词延后 0.5 秒',
                onTap: () => onControlPlayback('lyricOffsetLater'),
              ),
              const SizedBox(width: 6),
              _buildStepButton(
                icon: Icons.restart_alt_rounded,
                tooltip: '恢复歌词原始进度',
                onTap: () => onControlPlayback('lyricOffsetReset'),
              ),
              const SizedBox(width: 6),
              _buildStepButton(
                icon: Icons.keyboard_double_arrow_right_rounded,
                tooltip: '歌词提前 0.5 秒',
                onTap: () => onControlPlayback('lyricOffsetEarlier'),
              ),
            ],
          ),
          Divider(
            height: 12,
            thickness: 0.5,
            color: Colors.white.withValues(alpha: 0.10),
          ),
          // 3. 歌词配色：歌词（未播放）+ 高亮（已播放）成组切换，
          //    避免只改字体颜色导致高亮不跟随、甚至两色相同看不清。
          Row(
            children: [
              const Text(
                '歌词配色',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final scheme in DesktopLyricsColorScheme.presets) ...[
                    _buildSchemeChip(scheme),
                    if (scheme != DesktopLyricsColorScheme.presets.last)
                      const SizedBox(width: 6),
                  ],
                ],
              ),
            ],
          ),
          Divider(
            height: 12,
            thickness: 0.5,
            color: Colors.white.withValues(alpha: 0.10),
          ),
          // 5. 切换单/双行
          InkWell(
            onTap: () {
              onUpdateSettings(
                settings.copyWith(singleLine: !settings.singleLine),
              );
            },
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: [
                  Icon(
                    settings.singleLine
                        ? Icons.view_headline_rounded
                        : Icons.view_agenda_rounded,
                    size: 16,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    settings.singleLine ? '切换双行' : '切换单行',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          Divider(
            height: 12,
            thickness: 0.5,
            color: Colors.white.withValues(alpha: 0.10),
          ),
          // 7. 更多设置
          InkWell(
            onTap: onOpenDetailedSettings,
            borderRadius: BorderRadius.circular(6),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 2),
              child: Row(
                children: [
                  Icon(Icons.tune_rounded, size: 16, color: Colors.white70),
                  SizedBox(width: 8),
                  Text(
                    '更多设置',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  Spacer(),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: Colors.white38,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepButton({
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
  }) {
    final button = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(4),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 14, color: Colors.white),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip, child: button);
  }

  /// 配色方案圆点：左右对半双色（左=歌词色，右=高亮色），一眼看出
  /// 该方案切换的两项颜色；命中当前设置时白圈高亮。
  Widget _buildSchemeChip(DesktopLyricsColorScheme scheme) {
    final isSelected =
        settings.unplayedTextColor == scheme.unplayedTextColor &&
        settings.playedTextColor == scheme.playedTextColor;
    return Tooltip(
      message: scheme.name,
      child: InkWell(
        key: ValueKey('scheme_${scheme.name}'),
        onTap: () {
          onUpdateSettings(
            settings.copyWith(
              unplayedTextColor: scheme.unplayedTextColor,
              textColor: scheme.unplayedTextColor,
              playedTextColor: scheme.playedTextColor,
            ),
          );
        },
        borderRadius: BorderRadius.circular(9),
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                Color(scheme.unplayedTextColor),
                Color(scheme.playedTextColor),
              ],
              stops: const [0.5, 0.5],
            ),
            shape: BoxShape.circle,
            border: Border.all(
              color: isSelected
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.3),
              width: isSelected ? 2 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Color(
                        scheme.playedTextColor,
                      ).withValues(alpha: 0.6),
                      blurRadius: 4,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}
