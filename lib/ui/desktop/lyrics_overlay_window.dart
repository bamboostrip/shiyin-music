// 桌面歌词悬浮窗（desktop_multi_window 子窗口入口 + UI）。
//
// 仅在 Windows 桌面形态由主窗经 WindowsDesktopLyricsBridge 创建；
// 子窗口引擎会重新执行 main()（desktop_multi_window 约定），main.dart
// 顶部按 `multi_window` 参数分流到本文件 [runLyricsOverlayWindow]。
//
// 消息协议（main -> sub）：
// - updateLyric    {current, next, isPlaying}
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

/// 子窗口控制器（入口函数创建后模块级持有，供关闭流程使用）。
WindowController? _overlayWindowController;

/// 拖动结束后位置持久化的防抖间隔（WM_MOVE 风暴下合并落盘）。
const Duration _kPersistDebounce = Duration(milliseconds: 500);

/// 关闭流程重入 guard：closeLyricsOverlayWindow 可能由用户点 X、
/// Alt+F4（onWindowClose 漏斗）与主窗侧 hide（window.close 被
/// preventClose 拦截后转入漏斗）并发触发，只执行一次。
bool _overlayCloseInFlight = false;

/// 立即持久化当前窗口位置（防抖取消失效时与关闭前补存共用）。
Future<void> persistOverlayWindowPosition() async {
  try {
    final position = await windowManager.getPosition();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(
        WindowsDesktopLyricsBridge.windowLeftPrefKey, position.dx);
    await prefs.setDouble(
        WindowsDesktopLyricsBridge.windowTopPrefKey, position.dy);
  } on Exception {
    // 位置持久化失败不影响展示。
  }
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
        WindowsDesktopLyricsBridge.overlayHeight,
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
  );

  // 尽早注册消息处理，缩短主窗早期消息的丢失窗口期
  // （主窗 createWindow 后立即推送初始内容）。
  try {
    DesktopMultiWindow.setMethodHandler((MethodCall call, int fromWindowId) async {
      switch (call.method) {
        case 'updateLyric':
          final message = (call.arguments as Map?)?.cast<String, dynamic>();
          if (message != null) {
            model
              ..current = message['current'] as String? ?? model.current
              ..next = message['next'] as String? ?? model.next
              ..isPlaying = message['isPlaying'] as bool? ?? model.isPlaying;
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
    debugPrint('[桌面歌词悬浮窗] FlutterError: ${details.exception}\n${details.stack}');
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
/// 歌词纯文字常显、窗口不接收任何鼠标事件；解锁（locked=false）恢复接收。
/// 旧持久化字段 passthrough 仅保留兼容解析，不再参与穿透判定
/// （"触摸穿透"开关的语义已被锁定吸收）。
/// 公开为顶层函数以便单测固定锁定/解锁的穿透行为。
///
/// ⚠️ 只允许在窗口已经显示后调用（见 [schedulePassthroughAfterShown]）。
Future<void> applyDesktopLyricsPassthrough(DesktopLyricsSettings settings) async {
  try {
    await windowManager.setIgnoreMouseEvents(settings.locked);
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
Future<void> schedulePassthroughAfterShown(DesktopLyricsSettings settings) async {
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
  // 最后一次移动在此落盘）。
  await persistOverlayWindowPosition();
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
  }) : _settings = settings,
       _current = current,
       _next = next,
       _isPlaying = isPlaying;

  DesktopLyricsSettings _settings;
  String _current;
  String _next;
  bool _isPlaying;

  DesktopLyricsSettings get settings => _settings;
  String get current => _current;
  String get next => _next;
  bool get isPlaying => _isPlaying;

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
}

class _LyricsOverlayApp extends StatelessWidget {
  const _LyricsOverlayApp({required this.model});

  final _OverlayModel model;

  @override
  Widget build(BuildContext context) {
    // 与主窗一致：Windows 桌面排除语义树，规避 AXTree 竞态崩溃。
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
    // 取消未触发的防抖保存并立即补存一次，避免最后一次移动丢失。
    _persistDebounce?.cancel();
    unawaited(persistOverlayWindowPosition());
    windowManager.removeListener(this);
    super.dispose();
  }

  // 拖动为原生模态循环，PointerUp 不一定派发回 Flutter；
  // onWindowMoved 在移动循环结束后触发，是持久化位置的可靠时机。
  // WM_MOVE 期间会密集回调，防抖合并为停止 500ms 后的一次落盘。
  @override
  void onWindowMoved() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(_kPersistDebounce, () {
      unawaited(persistOverlayWindowPosition());
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
          onControlPlayback: (action) => unawaited(_controlPlayback(action)),
          onToggleLock: (locked) => unawaited(_setLocked(locked)),
          onClose: () => unawaited(closeLyricsOverlayWindow()),
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
    required this.onControlPlayback,
    required this.onToggleLock,
    required this.onClose,
  });

  final DesktopLyricsSettings settings;
  final String current;
  final String next;
  final bool isPlaying;
  final ValueChanged<String> onControlPlayback;

  /// 参数为目标锁定状态（true=锁定）。
  final ValueChanged<bool> onToggleLock;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final Widget child = settings.locked
        ? _LockedLyricsBody(
            settings: settings,
            current: current,
            next: next,
          )
        : _HoverableOverlay(
            settings: settings,
            current: current,
            next: next,
            isPlaying: isPlaying,
            onControlPlayback: onControlPlayback,
            onToggleLock: onToggleLock,
            onClose: onClose,
          );
    return Material(
      type: MaterialType.transparency,
      child: child,
    );
  }
}

/// 锁定态：只有歌词文字（含文字阴影），无任何交互/装饰组件。
class _LockedLyricsBody extends StatelessWidget {
  const _LockedLyricsBody({
    required this.settings,
    required this.current,
    required this.next,
  });

  final DesktopLyricsSettings settings;
  final String current;
  final String next;

  @override
  Widget build(BuildContext context) {
    return buildOverlayLyricsBody(
      settings: settings,
      current: current,
      next: next,
    );
  }
}

/// 未锁定态：悬停淡入暗色卡片 + 顶部工具栏，整卡可拖动。
class _HoverableOverlay extends StatefulWidget {
  const _HoverableOverlay({
    required this.settings,
    required this.current,
    required this.next,
    required this.isPlaying,
    required this.onControlPlayback,
    required this.onToggleLock,
    required this.onClose,
  });

  final DesktopLyricsSettings settings;
  final String current;
  final String next;
  final bool isPlaying;
  final ValueChanged<String> onControlPlayback;
  final ValueChanged<bool> onToggleLock;
  final VoidCallback onClose;

  @override
  State<_HoverableOverlay> createState() => _HoverableOverlayState();
}

class _HoverableOverlayState extends State<_HoverableOverlay> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;

    // 常态：背景纯透明（若用户在设置中显式调高 opacity 则兼容展示）
    // 悬停：平滑淡入现代半透暗调卡片背景（0xCC141823）
    final cardColor = _hovering
        ? const Color(0xCC141823)
        : (settings.opacity > 0
            ? Color(settings.backgroundColor).withValues(
                alpha: settings.opacity.clamp(0.0, 1.0),
              )
            : Colors.transparent);

    final cardBorder = _hovering
        ? Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 1.0,
          )
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

    return MouseRegion(
      hitTestBehavior: HitTestBehavior.opaque,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Material(
        type: MaterialType.transparency,
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
            child: Stack(
              children: [
                // 歌词主体与整卡拖拽热区
                Positioned.fill(
                  child: DragToMoveArea(
                    child: Container(
                      color: Colors.transparent,
                      child: buildOverlayLyricsBody(
                        settings: settings,
                        current: widget.current,
                        next: widget.next,
                      ),
                    ),
                  ),
                ),
                // 悬停微型磨砂操作卡片顶部浮现操作栏
                Positioned(
                  top: 6,
                  right: 8,
                  child: AnimatedOpacity(
                    opacity: _hovering ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeInOut,
                    child: IgnorePointer(
                      ignoring: !_hovering,
                      child: _buildOverlayToolbar(context),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlayToolbar(BuildContext context) {
    final settings = widget.settings;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.10),
          width: 0.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToolbarButton(
              icon: Icons.skip_previous_rounded,
              tooltip: '上一曲',
              iconSize: 18,
              onPressed: () => widget.onControlPlayback('previous'),
            ),
            const SizedBox(width: 2),
            _ToolbarButton(
              icon: widget.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              tooltip: widget.isPlaying ? '暂停' : '播放',
              iconSize: 18,
              onPressed: () => widget.onControlPlayback('togglePlay'),
            ),
            const SizedBox(width: 2),
            _ToolbarButton(
              icon: Icons.skip_next_rounded,
              tooltip: '下一曲',
              iconSize: 18,
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
              iconSize: 18,
              onPressed: () => widget.onToggleLock(!settings.locked),
            ),
            const SizedBox(width: 2),
            _ToolbarButton(
              icon: Icons.close_rounded,
              tooltip: '关闭桌面歌词',
              iconSize: 18,
              onPressed: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// 歌词主体（锁定/未锁定两套子树共用）：当前句 + 下一句，含文字阴影。
///
/// 布局契约：紧约束 SizedBox(780x88) + 水平 32 Padding + FittedBox(scaleDown)
/// + 固定宽度（悬浮窗宽 - 64）的 Column。紧约束是关键：FittedBox 在松约束
/// （Center 直接包裹）下会按子项原尺寸布局、不触发缩小，子项超高时 Center
/// 直接溢出（锁定态无 Stack 紧约束故必现，未锁定态靠 Stack 偶然收敛）。
/// 紧约束保证两行总高超过 88px 窗高（系统字体缩放/48sp 大字号）时整体等比
/// 缩小，而不是 RenderFlex 垂直溢出（溢出黄黑条纹会常驻窗口底部）。
Widget buildOverlayLyricsBody({
  required DesktopLyricsSettings settings,
  required String current,
  required String next,
}) {
  final textColor = Color(settings.textColor);
  final hasNext = next.trim().isNotEmpty;
  return SizedBox(
    width: WindowsDesktopLyricsBridge.overlayWidth,
    height: WindowsDesktopLyricsBridge.overlayHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: WindowsDesktopLyricsBridge.overlayWidth - 64,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _lyricLine(
                  text: current.isEmpty ? '暂无歌词' : current,
                  fontSize: settings.fontSize,
                  color: textColor,
                  fontWeight: FontWeight.bold,
                ),
                if (hasNext) ...[
                  const SizedBox(height: 3),
                  _lyricLine(
                    text: next,
                    fontSize: settings.fontSize * 0.58,
                    color: textColor.withValues(alpha: 0.60),
                    fontWeight: FontWeight.normal,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Widget _lyricLine({
  required String text,
  required double fontSize,
  required Color color,
  required FontWeight fontWeight,
}) {
  return SizedBox(
    width: double.infinity,
    child: Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: TextStyle(
        decoration: TextDecoration.none,
        fontSize: fontSize,
        color: color,
        fontWeight: fontWeight,
        shadows: [
          Shadow(
            color: Colors.black.withValues(alpha: 0.75),
            blurRadius: 6,
            offset: const Offset(0, 1),
          ),
          Shadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 14,
          ),
        ],
      ),
    ),
  );
}

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = 18,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;

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
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hovered
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Icon(
              widget.icon,
              size: widget.iconSize,
              color: _hovered
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.88),
            ),
          ),
        ),
      ),
    );
  }
}
