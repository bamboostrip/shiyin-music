// Windows 桌面歌词主窗侧桥接。
//
// 职责：把 DesktopLyricsService 门面 API 一比一映射到 desktop_multi_window
// 悬浮窗（lib/ui/desktop/lyrics_overlay_window.dart）。仅 Windows 分支使用；
// Android 路径不经此类。
//
// 消息协议（与悬浮窗侧约定一致）：
// - main -> sub：updateLyric {current, next, isPlaying} /
//   updateSettings {DesktopLyricsSettings.toMap()}
//   （不向子窗发 close：主窗侧关闭直接走原生 window.close）。
// - sub -> main：windowClosed {}（用户手动关闭，触发可见性回调）/
//   overlayReady {}（子引擎通道就绪，主窗补发缓存的歌词与设置）。
//
// API 名以包源码为准（desktop_multi_window 0.2.1）：
// - DesktopMultiWindow.createWindow([arguments]) -> WindowController
//   （子引擎以 args=['multi_window', id, arguments] 重新执行 main()）
// - DesktopMultiWindow.invokeMethod(targetWindowId, method, [arguments])
//   （主窗 id 固定为 0，无 sendToMain/sendToWindow API）
// - DesktopMultiWindow.setMethodHandler(handler(call, fromWindowId))
import 'dart:async';
import 'dart:convert';
// window_manager/desktop_multi_window 未重导出 dart:ui 类型。
import 'dart:ui' show Offset, Rect, Size;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:screen_retriever/screen_retriever.dart';

import 'desktop_lyrics_service.dart';

class WindowsDesktopLyricsBridge {
  WindowsDesktopLyricsBridge({DesktopLyricsVisibilityChanged? onVisibilityChanged})
    : _onVisibilityChanged = onVisibilityChanged;

  final DesktopLyricsVisibilityChanged? _onVisibilityChanged;

  /// 悬浮窗固定尺寸（与悬浮窗侧 v1 约定一致；主窗/子窗共用的唯一定义处）。
  static const double overlayWidth = 720;
  static const double overlayHeight = 120;

  WindowController? _window;
  bool _handlerRegistered = false;
  bool _visible = false;

  // 最近一次推送的内容：悬浮窗引擎启动存在窗口期，重show/补发时以缓存为准。
  DesktopLyricsSettings _settings = const DesktopLyricsSettings();
  String _current = '';
  String _next = '';
  bool _isPlaying = false;
  bool _appForeground = true;

  /// 悬浮窗是否可见（内部状态，不依赖平台查询）。
  bool get isVisible => _visible;

  /// 最近一次记录的前台状态（诊断/调试用途）。
  bool get appForeground => _appForeground;

  /// show/hide 串行化队列：开关连点时 createWindow/close 都是异步多步，
  /// 并发执行会造出幽灵窗口（hide 关了空引用，show 后续又把窗建出来；
  /// 两个 show 并发则第二个覆盖 _window，第一个成孤儿只能点卡片 X 关）。
  /// 所有创建/销毁走同一队列，顺序执行，终态必与最后一次操作一致。
  Future<void> _serial = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() task) {
    final next = _serial.then((_) => task());
    _serial = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<bool> show({required String title, required String artist}) =>
      _enqueue(() => _showInner(title: title, artist: artist));

  Future<void> hide() => _enqueue(_hideInner);

  Future<bool> _showInner({required String title, required String artist}) async {
    if (_visible && _window != null) {
      // 已在展示：仅补发缓存内容（标题/歌手 v1 不上屏）。
      await _pushLyric();
      return true;
    }
    debugPrint('[桌面歌词主窗] show 开始 title=$title artist=$artist');
    debugPrint(
      '[桌面歌词主窗] 生效设置 opacity=${_settings.opacity} '
      'fontSize=${_settings.fontSize}',
    );
    try {
      // 懒注册主窗侧消息处理（先于子窗可能的 windowClosed 上报）。
      _ensureMethodHandler();
      debugPrint('[桌面歌词主窗] createWindow 开始');
      final window = await DesktopMultiWindow.createWindow(
        jsonEncode(<String, dynamic>{
          'settings': _settings.toMap(),
          'current': _current,
          'next': _next,
          'isPlaying': _isPlaying,
          'title': title,
          'artist': artist,
        }),
      );
      debugPrint('[桌面歌词主窗] createWindow ok id=${window.windowId}，setFrame 开始');
      try {
        // 子引擎就绪需数百毫秒，且悬浮窗入口在完成无标题栏样式/尺寸/位置
        // 恢复后会自行 show()（见 lyrics_overlay_window.dart 入口末尾）。
        // 主窗侧不得提前 show()，否则会闪现白底带标题栏的默认 720x120 窗口；
        // 此处仅预置默认位置（首次展示无记忆位置时兜底，后续由悬浮窗自行
        // 覆盖为记忆位置）。
        await window.setFrame(await _defaultFrame());
        debugPrint('[桌面歌词主窗] setFrame ok');
      } on Exception catch (e) {
        debugPrint('[桌面歌词主窗] setFrame 失败: $e，关闭已创建窗口');
        // 布局/显示阶段失败：先关闭已创建的原生窗口，避免控制器被丢弃后
        // 原生窗口游离残留；再按创建失败路径统一处理。
        try {
          await window.close();
        } on Exception {
          // 窗口可能已被销毁。
        }
        rethrow;
      }
      _window = window;
      _visible = true;
      debugPrint('[桌面歌词主窗] show 成功，等待子引擎启动');
      return true;
    } on Exception catch (e) {
      debugPrint('[桌面歌词主窗] show 失败: $e');
      _visible = false;
      _window = null;
      return false;
    }
  }

  Future<void> _hideInner() async {
    final window = _window;
    _visible = false;
    _window = null;
    if (window == null) return;
    try {
      // 主窗发起的关闭直接走原生 close（WM_CLOSE -> 销毁子窗与子引擎），
      // 不向子窗发 close 消息，避免与销毁竞态产生多余的 windowClosed 上报。
      await window.close();
    } on Exception {
      // 窗口可能已被销毁。
    }
  }

  Future<void> updateLyrics({
    required String current,
    required String next,
  }) async {
    _current = current;
    _next = next;
    if (!_visible) return;
    await _pushLyric();
  }

  Future<void> updatePlayState({required bool isPlaying}) async {
    _isPlaying = isPlaying;
    if (!_visible) return;
    await _pushLyric();
  }

  Future<void> updateSettings(DesktopLyricsSettings settings) async {
    _settings = settings;
    if (!_visible) return;
    try {
      await _invokeSub('updateSettings', settings.toMap());
    } on Exception {
      // 子窗未就绪/已退出：缓存待下次 show 重发。
    }
  }

  /// v1 不做卡拉OK逐字进度（悬浮窗按整行展示）。
  Future<void> updateKaraokeProgress({
    required double progress,
    required Duration? lineDuration,
    required bool isPlaying,
  }) async {}

  /// 仅内部记录；可见性由 PlayerController 依自身前台状态调度 show/hide。
  Future<void> setAppForeground({required bool isForeground}) async {
    _appForeground = isForeground;
  }

  Future<void> _pushLyric() async {
    try {
      await _invokeSub('updateLyric', <String, dynamic>{
        'current': _current,
        'next': _next,
        'isPlaying': _isPlaying,
      });
    } on Exception catch (e) {
      // 子窗未就绪（引擎启动窗口期）或已退出：缓存待下次补发。
      debugPrint('[桌面歌词主窗] updateLyric 推送失败（子窗未就绪可能）: $e');
    }
  }

  Future<dynamic> _invokeSub(String method, dynamic arguments) async {
    final window = _window;
    if (window == null) return null;
    return DesktopMultiWindow.invokeMethod(window.windowId, method, arguments);
  }

  void _ensureMethodHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    DesktopMultiWindow.setMethodHandler((MethodCall call, int fromWindowId) async {
      if (call.method == 'windowClosed') {
        _visible = false;
        _window = null;
        _onVisibilityChanged?.call(visible: false, userClosed: true);
      } else if (call.method == 'overlayReady') {
        // 子引擎通道就绪：补发启动窗口期内可能丢失的歌词与设置。
        debugPrint('[桌面歌词主窗] 子引擎就绪，补发缓存内容');
        await _pushLyric();
        try {
          await _invokeSub('updateSettings', _settings.toMap());
        } on Exception catch (e) {
          debugPrint('[桌面歌词主窗] updateSettings 补发失败: $e');
        }
      }
      return null;
    });
  }

  /// 首次展示的默认位置：主显示器底部居中（之后由悬浮窗自行恢复记忆位置）。
  Future<Rect> _defaultFrame() async {
    var origin = const Offset(100, 100);
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final size = display.size;
      debugPrint('[桌面歌词主窗] 主显示器尺寸 ${size.width}x${size.height}');
      origin = Offset(
        (size.width - overlayWidth) / 2,
        size.height - overlayHeight - 80,
      );
    } on Exception catch (e) {
      debugPrint('[桌面歌词主窗] 获取主显示器失败，用固定位置: $e');
      // 拿不到显示器信息时退回固定位置。
    }
    return origin & const Size(WindowsDesktopLyricsBridge.overlayWidth,
        WindowsDesktopLyricsBridge.overlayHeight);
  }
}
