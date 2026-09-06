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
// - sub -> main：windowClosed {}（用户手动关闭，触发可见性回调与就绪门控复位）/
//   overlayReady {}（子引擎通道就绪：主窗先打开就绪门控，再补发缓存的歌词与
//   设置；门控打开前所有主->子推送静默跳过，避免子引擎 handler 注册完成前
//   invoke 必抛的 MissingPluginException 竞态）/
//   controlPlayback (action: 'previous' | 'togglePlay' | 'next')（悬停播控条触发主窗播控）/
//   setLyricsLocked (locked: bool)（子窗工具栏请求切换锁定：主窗侧统一落盘、
//   通知设置页，并把新 settings 回推子窗，子窗不本地直改锁定状态）。
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
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_lyrics_service.dart';

class WindowsDesktopLyricsBridge {
  WindowsDesktopLyricsBridge({
    DesktopLyricsVisibilityChanged? onVisibilityChanged,
    DesktopLyricsPlaybackAction? onPlaybackAction,
    DesktopLyricsLockChanged? onLockChanged,
  }) : _onVisibilityChanged = onVisibilityChanged,
       _onPlaybackAction = onPlaybackAction,
       _onLockChanged = onLockChanged;

  final DesktopLyricsVisibilityChanged? _onVisibilityChanged;
  final DesktopLyricsPlaybackAction? _onPlaybackAction;
  final DesktopLyricsLockChanged? _onLockChanged;

  /// 悬浮窗固定尺寸（与悬浮窗侧约定一致；主窗/子窗共用的唯一定义处）。
  static const double overlayWidth = 780;
  static const double overlayHeight = 88;

  /// 悬浮窗拖动位置的持久化键（子窗 window_manager 逻辑坐标；
  /// 主窗侧钳制后回写，子窗启动时读取恢复）。
  static const String windowLeftPrefKey = 'desktop_lyrics.window.left';
  static const String windowTopPrefKey = 'desktop_lyrics.window.top';

  /// 钳制时至少保留的可见像素（与主窗 kMinVisibleEdge 语义一致）。
  static const double _kMinVisibleEdge = 80;

  WindowController? _window;
  bool _handlerRegistered = false;
  bool _visible = false;

  /// 子窗消息通道就绪门控：子引擎完成样式/位置设置并注册消息 handler 后
  /// 才会上报 overlayReady（见 lyrics_overlay_window.dart）。在此之前对子窗
  /// 的任何 invokeMethod 都抛 MissingPluginException，故推送路径在此期间
  /// 只更新缓存、不真正 invoke，待 overlayReady 握手后统一补发。
  bool _overlayReady = false;

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
      // 已在展示：复用旧窗，仅补发缓存内容（标题/歌手 v1 不上屏）。
      // 此处不得重置 _overlayReady：复用路径里子引擎不会重新上报
      // overlayReady，误重置会导致歌词停止刷新；若子引擎仍在启动窗口期，
      // _pushLyric 的门控会静默跳过，由随后的 overlayReady 握手补发。
      await _pushLyric();
      return true;
    }
    try {
      // 重建子窗：复位就绪门控，新引擎必须等待新一轮 overlayReady 握手
      // （上一窗口的就绪状态对新建引擎无效）。
      _overlayReady = false;
      // 懒注册主窗侧消息处理（先于子窗可能的 windowClosed 上报）。
      _ensureMethodHandler();
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
      try {
        // 子引擎就绪需数百毫秒，且悬浮窗入口在完成无标题栏样式/尺寸/位置
        // 恢复后会自行 show()（见 lyrics_overlay_window.dart 入口末尾）。
        // 主窗侧不得提前 show()，否则会闪现白底带标题栏的默认 720x120 窗口；
        // 此处预置初始位置：记忆位置（已主窗侧钳制）或底部居中默认值，
        // 后续由悬浮窗自行 setPosition 覆盖为记忆位置（逻辑坐标）。
        await window.setFrame(await _initialFrame());
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
    // 子窗随之销毁：就绪状态失效，重开需等待新引擎的 overlayReady 握手。
    _overlayReady = false;
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
    // 未就绪（子引擎启动窗口期）只更新缓存，由 overlayReady 握手后补发。
    if (!_visible || !_overlayReady) return;
    try {
      await _invokeSub('updateSettings', settings.toMap());
    } on Exception {
      // 子窗已退出：缓存待下次 show 重发。
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
    // 就绪门控：子引擎 handler 注册完成前不 invoke（缓存已是最新，
    // overlayReady 握手后会补发），从源头消除 MissingPluginException。
    if (!_overlayReady) return;
    try {
      await _invokeSub('updateLyric', <String, dynamic>{
        'current': _current,
        'next': _next,
        'isPlaying': _isPlaying,
      });
    } on Exception catch (e) {
      // 最后防线：握手后的意外竞态（如窗口恰在销毁）。缓存待下次补发。
      debugPrint('[桌面歌词主窗] updateLyric 未送达，已缓存待补发: $e');
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
      // 只信任当前子窗的消息：热重启等路径下可能存在桥接已失忆的旧子窗，
      // 旧窗迟到的 windowClosed 会把指向新窗的 _window 清空、_visible 清
      // 假，造成"新窗歌词冻结/开关状态错乱"。
      if (_window == null || fromWindowId != _window!.windowId) {
        return null;
      }
      if (call.method == 'windowClosed') {
        // 主窗自己发起的关闭（hide/退出收口）时 _visible 已为 false：
        // 子窗 preventClose 拦截后补报的 windowClosed 不是用户手动关闭，
        // 不得触发可见性回调（否则会把持久化开关错误翻转为关）。
        if (!_visible) return null;
        // 子窗销毁：就绪门控同步失效，重建/重开需等待新一轮握手。
        _overlayReady = false;
        _visible = false;
        _window = null;
        _onVisibilityChanged?.call(visible: false, userClosed: true);
      } else if (call.method == 'overlayReady') {
        // 子引擎通道就绪：先打开就绪门控（本次补发自身也走门控路径），
        // 再补发启动窗口期内可能丢失的歌词与设置。
        _overlayReady = true;
        await _pushLyric();
        try {
          await _invokeSub('updateSettings', _settings.toMap());
        } on Exception catch (e) {
          debugPrint('[桌面歌词主窗] updateSettings 补发失败: $e');
        }
      } else if (call.method == 'controlPlayback') {
        final action = call.arguments?.toString();
        if (action != null && action.isNotEmpty) {
          _onPlaybackAction?.call(action);
        }
      } else if (call.method == 'setLyricsLocked') {
        // 子窗工具栏锁定按钮：不在子窗本地直改状态，由回调方（PlayerController）
        // 走 updateSettings 完成持久化 + 设置页通知，并经 updateSettings
        // 回推子窗后统一重建（锁定即全穿透）。
        _onLockChanged?.call(call.arguments == true);
      }
      return null;
    });
  }

  /// 悬浮窗初始 frame（物理像素，供 desktop_multi_window 的 setFrame）。
  ///
  /// 优先恢复记忆的拖动位置；无记忆时落主显示器底部居中。记忆位置在
  /// 主窗侧先行钳制到可见显示器区域并回写——悬浮窗侧（子引擎）只有
  /// window_manager 可用（无 screen_retriever 插件注册），无法自行判断
  /// 显示器配置变化，不钳制的话拔掉副显示器后悬浮窗会恢复到屏幕外成为
  /// 不可见的"僵尸窗"（锁定态全穿透，用户没有任何入口找回）。
  Future<Rect> _initialFrame() async {
    var origin = const Offset(100, 100);
    var scaleFactor = 1.0;
    var visibleAreas = const <Rect>[];
    try {
      final primary = await screenRetriever.getPrimaryDisplay();
      final all = await screenRetriever.getAllDisplays();
      final primaryArea = _visibleAreaOf(primary);
      visibleAreas = [
        primaryArea,
        for (final display in all)
          if (display.id != primary.id) _visibleAreaOf(display),
      ];
      scaleFactor = (primary.scaleFactor ?? 1.0).toDouble();
      origin = Offset(
        primaryArea.left +
            (primaryArea.width - overlayWidth) / 2,
        primaryArea.top +
            primaryArea.height -
            overlayHeight -
            80,
      );
    } on Exception catch (e) {
      debugPrint('[桌面歌词主窗] 获取显示器信息失败，用固定位置: $e');
      // 拿不到显示器信息时无从钳制/换算，退回固定逻辑位置。
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final left = prefs.getDouble(windowLeftPrefKey);
      final top = prefs.getDouble(windowTopPrefKey);
      if (left != null && top != null) {
        final clamped = clampOverlayOriginToVisibleAreas(
          Offset(left, top),
          visibleAreas,
          fallback: origin,
        );
        if (clamped.dx != left || clamped.dy != top) {
          await prefs.setDouble(windowLeftPrefKey, clamped.dx);
          await prefs.setDouble(windowTopPrefKey, clamped.dy);
        }
        origin = clamped;
      }
    } on Exception catch (e) {
      debugPrint('[桌面歌词主窗] 读取/钳制记忆位置失败，用默认位置: $e');
    }
    // desktop_multi_window 的 setFrame 底层是 MoveWindow（物理像素），
    // 而 screen_retriever/window_manager 记忆位置都是逻辑坐标：
    // 必须按主显示器缩放换算，否则 DPI>100% 时首帧位置/尺寸偏小偏移。
    return Offset(origin.dx * scaleFactor, origin.dy * scaleFactor) &
        Size(overlayWidth * scaleFactor, overlayHeight * scaleFactor);
  }

  /// 显示器的可见区域：优先 visiblePosition/visibleSize，缺失时退回原点/整屏。
  static Rect _visibleAreaOf(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }

  /// 把悬浮窗原点钳制到至少留出 [_kMinVisibleEdge] 可见边（纯函数，供单测）。
  ///
  /// 与任一可见区域有足量交集 → 原样返回；否则钳入第一个区域
  /// （右/下至少留 80px，窗口比区域宽时贴左/上）。无显示器信息时
  /// 返回 [fallback]。
  @visibleForTesting
  static Offset clampOverlayOriginToVisibleAreas(
    Offset origin,
    List<Rect> visibleAreas, {
    required Offset fallback,
  }) {
    if (visibleAreas.isEmpty) return fallback;
    final windowRect = origin & const Size(overlayWidth, overlayHeight);
    for (final area in visibleAreas) {
      final intersection = area.intersect(windowRect);
      if (intersection.width >= _kMinVisibleEdge &&
          intersection.height >= _kMinVisibleEdge) {
        return origin;
      }
    }
    final area = visibleAreas.first;
    final clampedLeft = origin.dx
        .clamp(
          area.left,
          math.max(area.left, area.right - _kMinVisibleEdge),
        )
        .toDouble();
    final clampedTop = origin.dy
        .clamp(
          area.top,
          math.max(area.top, area.bottom - _kMinVisibleEdge),
        )
        .toDouble();
    return Offset(clampedLeft, clampedTop);
  }
}
