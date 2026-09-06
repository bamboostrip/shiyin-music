import 'dart:async';
import 'dart:math' as math;
// window_manager 未重新导出 dart:ui 类型，Size/Offset 需自行引入。
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:screen_retriever/screen_retriever.dart';
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
    // 关闭拦截尽早打开：恢复链（读取几何/钳制/最大化）耗时期间用户点 X
    // 也必须走 [_WindowGeometrySaver.onWindowClose]，否则窗口被原生直接
    // 销毁、进程退出，初始化中的服务被拦腰斩断。
    await windowManager.setPreventClose(true);
    final prefs = await SharedPreferences.getInstance();
    final geometry = DesktopWindowGeometry.load(prefs);
    final options = WindowOptions(
      size: geometry?.size ?? kDefaultSize,
      minimumSize: kMinSize,
      title: kWindowTitle,
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      // window_manager 0.4.x 的 WindowOptions 无 position 参数，
      // 恢复记忆位置改用 setPosition。
      if (geometry != null) {
        // 显示器配置可能自上次会话后变化（拔掉显示器、断开远程桌面等），
        // 恢复前先把位置钳制到至少与一块显示器可见区域相交。
        final clamped = await _clampToConnectedDisplays(geometry);
        await windowManager.setPosition(clamped.offset);
      }
      // 最大化记忆：先按标记还原最大化再显示，避免"先小窗后放大"的闪烁。
      if (DesktopWindow.maximizedPreferred(prefs)) {
        await windowManager.maximize();
      }
      await windowManager.show();
      await windowManager.focus();
    });
    _saver = _WindowGeometrySaver(prefs);
    windowManager.addListener(_saver!);
  }

  static _WindowGeometrySaver? _saver;

  /// "关闭时最小化到托盘"持久化键。
  static const String kCloseToTrayPrefKey = 'window.closeToTray';

  /// 最大化状态持久化键（由 [_WindowGeometrySaver] 随事件写入）。
  static const String kMaximizedPrefKey = 'window.maximized';

  /// 会话级"关闭到托盘"降级开关（null = 未降级，以持久化设置为准）。
  ///
  /// 托盘初始化失败时置 false：本会话内 X 按钮直接退出，保证应用可达。
  /// 只降级当前会话，不回写持久化设置——托盘在下次启动恢复后，
  /// 用户显式开启的"关闭到托盘"不受一次性的环境故障影响。
  static bool? _closeToTraySessionOverride;

  /// 退出前清理钩子（main.dart 注入：关闭桌面歌词子窗、销毁托盘等）。
  ///
  /// [quitGracefully] 在销毁主窗前调用；因 destroy() 原生实现是
  /// PostQuitMessage（进程直接退出），Dart 侧不会获得优雅关闭机会，
  /// 所有跨窗口/系统资源必须在 destroy 之前在此清理。
  static Future<void> Function()? onBeforeQuit;

  /// 统一退出路径：清理钩子 → 落盘几何 → 销毁窗口（进程随之退出）。
  ///
  /// 托盘"退出"与关闭按钮的 destroy 分支都必须走这里，禁止散落调用
  /// windowManager.destroy()——否则托盘图标残留、桌面歌词子窗被硬杀
  /// （子窗最后 500ms 防抖内的拖动位置丢失）。
  static Future<void> quitGracefully() async {
    final hook = onBeforeQuit;
    if (hook != null) {
      try {
        await hook();
      } catch (error) {
        debugPrint('DesktopWindow: 退出前清理失败（继续退出）: $error');
      }
    }
    try {
      await flushGeometry();
    } catch (error) {
      debugPrint('DesktopWindow: 退出时保存几何失败（不阻止退出）: $error');
    }
    try {
      await windowManager.destroy();
    } catch (error) {
      debugPrint('DesktopWindow: 窗口销毁失败: $error');
    }
  }

  /// 读取关闭行为：true（默认）→ 关闭时隐藏到托盘；false → 真正退出。
  /// 会话级降级（托盘初始化失败）优先于持久化设置。
  static bool closeToTrayEnabled(SharedPreferences prefs) =>
      _closeToTraySessionOverride ??
      (prefs.getBool(kCloseToTrayPrefKey) ?? true);

  /// 设置/清除会话级"关闭到托盘"降级（见 [_closeToTraySessionOverride]）。
  static void setCloseToTraySessionOverride(bool? value) {
    _closeToTraySessionOverride = value;
  }

  /// 写入关闭行为设置。
  static Future<void> setCloseToTray(SharedPreferences prefs, bool value) =>
      prefs.setBool(kCloseToTrayPrefKey, value);

  /// 读取最大化记忆：true → 上次退出时窗口处于最大化，启动后应还原。
  static bool maximizedPreferred(SharedPreferences prefs) =>
      prefs.getBool(kMaximizedPrefKey) ?? false;

  /// 立即持久化当前窗口几何（取消防抖）。
  ///
  /// 供托盘"退出"等在销毁窗口前调用，保证最后一次位置不丢失。
  static Future<void> flushGeometry() async => _saver?.flush();

  /// 重置窗口：清空持久化几何与最大化标记，恢复默认尺寸并居中。
  ///
  /// 非桌面形态只清 prefs，不触碰窗口管理器（可能未初始化）。
  static Future<void> resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    await DesktopWindowGeometry.reset(prefs);
    await prefs.remove(kMaximizedPrefKey);
    if (!isDesktopFormFactor) return;
    // 最大化状态下 setBounds/center 不生效且后续 resize 事件会把全屏
    // 尺寸当常规几何落盘：先还原再重置。
    try {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      }
    } catch (error) {
      debugPrint('DesktopWindow: 重置前还原最大化失败（继续重置）: $error');
    }
    await windowManager.setBounds(
      Rect.fromLTWH(0, 0, kDefaultSize.width, kDefaultSize.height),
    );
    await windowManager.center();
  }

  /// 取当前所有显示器的可见区域（主显示器在前），钳制已保存几何。
  ///
  /// 显示器查询失败（驱动/远程会话异常等）时无从钳制，
  /// 回退为直接使用保存几何，避免整个恢复流程失败。
  static Future<DesktopWindowGeometry> _clampToConnectedDisplays(
    DesktopWindowGeometry geometry,
  ) async {
    final List<Display> displays;
    try {
      final primary = await screenRetriever.getPrimaryDisplay();
      final all = await screenRetriever.getAllDisplays();
      // 主显示器排最前：钳制时优先落回主显示器（按 id 去重）。
      displays = [
        primary,
        ...all.where((display) => display.id != primary.id),
      ];
    } catch (error) {
      debugPrint('DesktopWindow: 显示器查询失败，跳过钳制: $error');
      return geometry;
    }
    final visibleAreas = displays.map(_visibleAreaOf).toList();
    return DesktopWindowGeometry.clampToVisibleAreas(geometry, visibleAreas);
  }

  /// 显示器的可见区域：优先 visiblePosition/visibleSize，
  /// 缺失时退回原点/整屏 size。
  static Rect _visibleAreaOf(Display display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
  }
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

  /// 钳制时右/下方向至少保留的可见像素数。
  static const double kMinVisibleEdge = 80;

  Size get size => Size(width, height);
  Offset get offset => Offset(left, top);

  Rect get rect => Rect.fromLTWH(left, top, width, height);

  /// 将窗口几何钳制到至少在一块显示器可见区域内留出
  /// [kMinVisibleEdge] 的可见边，避免显示器配置变化后窗口恢复到屏幕外
  /// 或仅剩几像素可见（用户无法拖回）。
  /// [visibleAreas] 为各显示器的可见区域（左上角 + 尺寸）。
  static DesktopWindowGeometry clampToVisibleAreas(
    DesktopWindowGeometry geometry,
    List<Rect> visibleAreas,
  ) {
    // 无可用显示器信息时无从钳制，原样返回。
    if (visibleAreas.isEmpty) return geometry;
    final windowRect = geometry.rect;
    // 任一可见区域与窗口有足量交集（至少 kMinVisibleEdge 见方）→ 可见
    // 且可拖动，原样返回。仅数像素交集视为不可用（拔显示器/DPI 换算后
    // 贴边的典型残余），走下方重定位。
    for (final area in visibleAreas) {
      final intersection = area.intersect(windowRect);
      if (intersection.width >= kMinVisibleEdge &&
          intersection.height >= kMinVisibleEdge) {
        return geometry;
      }
    }
    // 不可见/不可用 → 放进第一个可见区域，右/下边至少留出 80px 可见；
    // 窗口比区域（减去 80px）还宽/高时贴区域左上角。
    final area = visibleAreas.first;
    final clampedLeft = area.left +
        math.max(0.0, area.width - kMinVisibleEdge - geometry.width);
    final clampedTop = area.top +
        math.max(0.0, area.height - kMinVisibleEdge - geometry.height);
    return DesktopWindowGeometry(
      left: clampedLeft,
      top: clampedTop,
      width: geometry.width,
      height: geometry.height,
    );
  }

  /// 按字段值判等，便于断言"存取往返后几何一致"。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DesktopWindowGeometry &&
          other.left == left &&
          other.top == top &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

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

/// 监听窗口移动/缩放，防抖后持久化几何；同时承担关闭拦截行为。
class _WindowGeometrySaver extends WindowListener {
  _WindowGeometrySaver(this._prefs);

  final SharedPreferences _prefs;
  Timer? _debounce;

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  /// 最大化状态记忆：随事件立即落盘（无需防抖，低频事件）。
  /// 最大化/还原时窗口管理器也会派发 resize，几何本身由 [_scheduleSave] 走防抖。
  @override
  void onWindowMaximize() {
    unawaited(_prefs.setBool(DesktopWindow.kMaximizedPrefKey, true));
  }

  @override
  void onWindowUnmaximize() {
    unawaited(_prefs.setBool(DesktopWindow.kMaximizedPrefKey, false));
  }

  /// 关闭拦截（[DesktopWindow.ensureInitialized] 已 setPreventClose）：
  /// 先取消防抖并立即落盘几何，再按用户设置决定隐藏到托盘还是真正退出。
  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  Future<void> _handleWindowClose() async {
    try {
      await flush();
    } catch (error) {
      debugPrint('DesktopWindow: 窗口关闭时保存几何失败（不阻止关闭）: $error');
    }
    try {
      if (DesktopWindow.closeToTrayEnabled(_prefs)) {
        await windowManager.hide();
      } else {
        // 统一退出路径：先走清理钩子（关歌词子窗/销毁托盘）再销毁。
        await DesktopWindow.quitGracefully();
      }
    } catch (error) {
      debugPrint('DesktopWindow: 窗口关闭处理失败，降级强制销毁: $error');
      try {
        await windowManager.destroy();
      } catch (_) {}
    }
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      await _saveNow();
    });
  }

  /// 取消防抖并立即保存当前几何。
  Future<void> flush() async {
    _debounce?.cancel();
    _debounce = null;
    await _saveNow();
  }

  Future<void> _saveNow() async {
    // 处于最大化状态时不落盘常规几何，避免最大化全屏尺寸覆盖用户常规窗口尺寸。
    // 查询实时状态而非持久化标记：持久化标记在 onWindowMaximize/Unmaximize
    // 异步落盘，存在滞后（如刚启动按标记还原最大化时标记仍为 true 但几何
    // 事件尚未到达）；且"重置窗口"会清标记，若此处读标记会让保护失效。
    try {
      if (await windowManager.isMaximized()) {
        return;
      }
      final bounds = await windowManager.getBounds();
      await DesktopWindowGeometry(
        left: bounds.left,
        top: bounds.top,
        width: bounds.width,
        height: bounds.height,
      ).save(_prefs);
    } catch (error) {
      debugPrint('DesktopWindow: 保存窗口几何失败: $error');
    }
  }
}
