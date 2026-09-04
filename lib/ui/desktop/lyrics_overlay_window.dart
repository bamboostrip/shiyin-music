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
import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/desktop_lyrics_service.dart';
import '../../services/windows_desktop_lyrics_bridge.dart';

/// 子窗口控制器（入口函数创建后模块级持有，供关闭流程使用）。
WindowController? _overlayWindowController;

/// 拖动结束后的位置持久化键（与 brief 约定一致）。
const String _kWindowLeftKey = 'desktop_lyrics.window.left';
const String _kWindowTopKey = 'desktop_lyrics.window.top';

/// 拖动结束后位置持久化的防抖间隔（WM_MOVE 风暴下合并落盘）。
const Duration _kPersistDebounce = Duration(milliseconds: 500);

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
  debugPrint('[桌面歌词悬浮窗] 启动 argsLength=${args.length}');

  // 参数解析失败直接返回，不让子引擎带病启动（此前 jsonDecode/int.parse
  // 无保护，畸形参数会导致子引擎未处理异常）。
  WindowController? windowController;
  try {
    if (args.length < 2) {
      debugPrint('[桌面歌词悬浮窗] 参数不足，直接退出');
      return;
    }
    windowController = WindowController.fromWindowId(int.parse(args[1]));
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] 解析窗口ID失败: $e');
    return;
  }
  _overlayWindowController = windowController;
  final shownController = windowController;

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
  // 子引擎启动，且无法从日志定位是哪一步。分步日志、互不干扰。
  // 子引擎内 window_manager 作用于本悬浮窗自身（ensureInitialized 将
  // native_window 绑定为当前引擎根 HWND，见 window_manager 源码）。
  try {
    await windowManager.ensureInitialized();
    debugPrint('[桌面歌词悬浮窗] windowManager 初始化 ok');
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] windowManager 初始化失败: $e');
  }
  try {
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setTitleBarStyle 失败: $e');
  }
  try {
    await windowManager.setAlwaysOnTop(true);
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] setAlwaysOnTop 失败: $e');
  }
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
  await _applyPassthrough(settings);

  // 恢复上次拖动位置（失败不影响展示）。
  try {
    final prefs = await SharedPreferences.getInstance();
    final left = prefs.getDouble(_kWindowLeftKey);
    final top = prefs.getDouble(_kWindowTopKey);
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
            await _applyPassthrough(model.settings);
          }
      }
      return null;
    });
  } catch (e) {
    debugPrint('[桌面歌词悬浮窗] 注册消息处理失败: $e');
  }

  runApp(_LyricsOverlayApp(model: model));
  // 插件创建的窗口初始隐藏（源码 ShowWindow(SW_HIDE)）。首帧渲染完成
  // 后再显示：此前 show() 在 runApp 之前调用，空窗口先行贴屏，
  // 既闪现白底默认窗，也可能与引擎首帧初始化竞态。
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      await shownController.show();
      debugPrint('[桌面歌词悬浮窗] show ok');
    } catch (e) {
      debugPrint('[桌面歌词悬浮窗] show 失败: $e');
    }
  });
}

/// locked && passthrough 时让鼠标穿透悬浮窗（锁定态由主窗设置页解锁）。
Future<void> _applyPassthrough(DesktopLyricsSettings settings) async {
  try {
    await windowManager.setIgnoreMouseEvents(
      settings.locked && settings.passthrough,
    );
  } on Exception {
    // setIgnoreMouseEvents 失败不影响歌词展示。
  }
}

/// 关闭悬浮窗：先通知主窗（触发 enabled=false 持久化），再销毁自身。
Future<void> closeLyricsOverlayWindow() async {
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
  bool _hovering = false;
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
    unawaited(_persistPosition());
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
      unawaited(_persistPosition());
    });
  }

  Future<void> _persistPosition() async {
    try {
      final position = await windowManager.getPosition();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kWindowLeftKey, position.dx);
      await prefs.setDouble(_kWindowTopKey, position.dy);
    } on Exception {
      // 位置持久化失败不影响展示。
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.model,
      builder: (context, _) {
        final settings = widget.model.settings;
        final background = Color(settings.backgroundColor).withValues(
          alpha: settings.opacity.clamp(0.05, 1.0).toDouble(),
        );
        final textColor = Color(settings.textColor);
        final locked = settings.locked;
        final clickThrough = locked && settings.passthrough;
        final showToolbar = _hovering && !clickThrough;

        return MouseRegion(
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: Material(
            type: MaterialType.transparency,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: background,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: _lyricsBody(
                        settings: settings,
                        textColor: textColor,
                        draggable: !locked,
                      ),
                    ),
                  ),
                ),
                if (showToolbar)
                  Positioned(
                    top: 10,
                    right: 14,
                    child: _toolbar(settings: settings),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _lyricsBody({
    required DesktopLyricsSettings settings,
    required Color textColor,
    required bool draggable,
  }) {
    final model = widget.model;
    final body = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _lyricLine(
            text: model.current.isEmpty ? '暂无歌词' : model.current,
            fontSize: settings.fontSize,
            color: textColor,
            fontWeight: FontWeight.bold,
          ),
          SizedBox(height: settings.fontSize * 0.15),
          _lyricLine(
            text: model.next,
            fontSize: settings.fontSize * 0.6,
            color: textColor.withValues(alpha: 0.7),
            fontWeight: FontWeight.normal,
          ),
        ],
      ),
    );
    if (!draggable) {
      return body;
    }
    return DragToMoveArea(child: body);
  }

  Widget _lyricLine({
    required String text,
    required double fontSize,
    required Color color,
    required FontWeight fontWeight,
  }) {
    return SizedBox(
      width: double.infinity,
      height: fontSize * 1.3,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: fontSize, color: color, fontWeight: fontWeight),
      ),
    );
  }

  Widget _toolbar({required DesktopLyricsSettings settings}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: settings.locked ? '解锁位置' : '锁定位置',
            icon: Icon(
              settings.locked ? Icons.lock : Icons.lock_open,
              size: 16,
              color: Colors.white,
            ),
            onPressed: () {
              // v1：悬浮窗内锁定为会话级（主窗设置页下次 updateSettings 会覆盖）。
              widget.model.settings = widget.model.settings.copyWith(
                locked: !widget.model.settings.locked,
              );
              unawaited(_applyPassthrough(widget.model.settings));
            },
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '关闭桌面歌词',
            icon: const Icon(Icons.close, size: 16, color: Colors.white),
            onPressed: () => unawaited(closeLyricsOverlayWindow()),
          ),
        ],
      ),
    );
  }
}
