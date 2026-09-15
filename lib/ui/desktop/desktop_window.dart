import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform, exit;
import 'dart:math' as math;
// window_manager 未重新导出 dart:ui 类型，Size/Offset/Color 需自行引入。
import 'dart:ui' show Color, Offset, Rect, Size;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException, PlatformException;
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
    // 重复调用会重复 addListener，残留旧 saver（几何双写、onWindowClose
    // 双触发导致 quitGracefully 执行两次）。初始化只允许一次；
    // 标志在成功完成后置位，中途异常允许调用方重试。
    if (_initialized) return;
    if (!isDesktopFormFactor) {
      // 桌面宿主（Windows 等）在调试移动端形态时，调整窗口为手机竖屏比例便于预览
      if (isDesktopPlatform) {
        try {
          await windowManager.ensureInitialized();
          const options = WindowOptions(
            size: Size(420, 860),
            minimumSize: Size(360, 520),
            title: '时音 (移动端调试)',
            titleBarStyle: TitleBarStyle.normal,
          );
          await windowManager.waitUntilReadyToShow(options, () async {
            await windowManager.show();
            await windowManager.focus();
          });
        } catch (_) {}
      }
      _initialized = true;
      return;
    }
    await windowManager.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    // 关闭拦截尽早打开：恢复链（读取几何/钳制/最大化）耗时期间用户点 X
    // 也必须走 [_WindowGeometrySaver.onWindowClose]，否则窗口被原生直接
    // 销毁、进程退出，初始化中的服务被拦腰斩断。
    // saver 先挂再开拦截：若顺序反过来，setPreventClose 生效到 addListener
    // 之间点 X 会被拦截却无人处理（点击被静默吞掉，窗口关不掉也不隐藏）。
    // 上次执行中途抛出后的重试会带着残留的旧 saver 到这里，必须先摘除：
    // 不摘则监听翻倍，几何双写、onWindowClose 双触发（quitGracefully×2）。
    final staleSaver = _saver;
    _saver = _WindowGeometrySaver(prefs);
    if (staleSaver != null) windowManager.removeListener(staleSaver);
    windowManager.addListener(_saver!);
    await windowManager.setPreventClose(true);
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
    _initialized = true;
  }

  static bool _initialized = false;

  static _WindowGeometrySaver? _saver;

  /// 解除关闭拦截（启动失败兜底路径使用）。
  ///
  /// 启动在 [ensureInitialized] 之后失败时，托盘永远不会创建（Tray.init
  /// 在 ShiyinApp.initState），若保留 setPreventClose(true)，错误页点 X
  /// 会被藏进不存在的托盘 → 进程永久隐形。解除后 X 直接原生关闭。
  static Future<void> disableCloseInterception() async {
    try {
      await windowManager.setPreventClose(false);
    } catch (error) {
      debugPrint('DesktopWindow: 解除关闭拦截失败（忽略）: $error');
    }
  }

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

  /// 统一退出路径：落盘几何 → 刷写注册的退出前持久化钩子 → 终止进程。
  ///
  /// Windows 上不走 windowManager.destroy() / exit() 等任何优雅关闭：
  /// Flutter 引擎 teardown（主窗无障碍桥拆除、桌面歌词子窗引擎线程退出）
  /// 会在 IME/UIA 等无障碍客户端活跃时，于 flutter_windows.dll 内触发
  /// 多处 use-after-free 崩溃（0xC0000005，GetEngine/messenger 等均已
  /// 实测），随后 WER 收集崩溃转储拖 ~12s 进程才退出，表现为"退出像
  /// 卡住"。
  ///
  /// 也无法走 ExitProcess：其 DllMain detach 阶段仍会运行各插件 DLL 的
  /// CRT 静态析构（desktop_multi_window 的析构调用引擎 messenger，已
  /// 实测崩溃）；也不能先 hide() 再退出——主窗隐藏触发应用生命周期
  /// 变化，歌词子窗随即关闭并开始注定崩溃的子引擎 teardown（已实测）。
  ///
  /// 这里直接硬终止：TerminateProcess(本进程) 内核终止包括子窗引擎在
  /// 内的全部其它线程且不做任何 DLL_PROCESS_DETACH，再
  /// TerminateThread(当前线程) 硬终止调用线程自身——此后不执行任何
  /// atexit/静态析构/DllMain 代码，不存在可崩溃的 teardown，毫秒级
  /// 退出且无 WER。托盘图标由 Shell 在进程死亡时自动清除；主窗与悬浮
  /// 窗同帧消失。仅用于用户主动退出，几何等状态已在终止之前落盘。
  ///
  /// Linux/macOS 上不存在上述 WER/UAF 问题（崩溃根源在 flutter_windows
  /// .dll 的无障碍桥），走窗口管理器正常销毁即可；此前的 kernel32 硬
  /// 终止在这两个平台会因 DynamicLibrary.open('kernel32.dll') 直接抛
  /// 异常，导致托盘"退出"永远退不掉。
  ///
  /// 托盘"退出"与关闭按钮的退出分支都必须走这里，禁止散落调用
  /// windowManager.destroy()。
  static Future<void> quitGracefully() async {
    try {
      await flushGeometry();
    } catch (error) {
      debugPrint('DesktopWindow: 退出时保存几何失败（不阻止退出）: $error');
    }
    // 播放队列/当前曲目等防抖落盘的状态：硬终止前立即刷写。
    await _runPreQuitFlushers();
    if (!Platform.isWindows) {
      try {
        await windowManager.destroy();
      } catch (error) {
        debugPrint('DesktopWindow: destroy 失败，降级 exit(0): $error');
        exit(0);
      }
      return;
    }
    _terminateNow();
  }

  /// 退出前持久化钩子：注册防抖落盘状态的立即刷写（如播放队列/当前
  /// 曲目）。每个钩子独立容错并限时，任何单个失败/超时都不阻止退出。
  static final List<Future<void> Function()> _preQuitFlushers = [];

  static void registerPreQuitFlusher(Future<void> Function() flusher) {
    if (!_preQuitFlushers.contains(flusher)) {
      _preQuitFlushers.add(flusher);
    }
  }

  static Future<void> _runPreQuitFlushers() async {
    for (final flusher in List.of(_preQuitFlushers)) {
      try {
        await flusher().timeout(const Duration(milliseconds: 800));
      } catch (error) {
        debugPrint('DesktopWindow: 退出前刷写状态失败（忽略）: $error');
      }
    }
  }

  /// TerminateProcess(本进程, 0) + TerminateThread(当前线程, 0)。
  /// 仅 Windows、仅用于 [quitGracefully] 末尾的用户主动退出（状态均已
  /// 落盘）；非 Windows 分支在 quitGracefully 内走 destroy()。
  static void _terminateNow() {
    final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
    final getCurrentProcess = kernel32
        .lookupFunction<ffi.IntPtr Function(), int Function()>('GetCurrentProcess');
    final getCurrentThread = kernel32
        .lookupFunction<ffi.IntPtr Function(), int Function()>('GetCurrentThread');
    final terminate = kernel32.lookupFunction<
        ffi.IntPtr Function(ffi.IntPtr, ffi.Uint32),
        int Function(int, int)>('TerminateProcess');
    terminate(getCurrentProcess(), 0);
    terminate(getCurrentThread(), 0);
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

  /// 主窗原生配置通道（runner 侧注册，见 windows/runner/flutter_window.cpp）。
  static const MethodChannel _windowChannel = MethodChannel(
    'shiyin_music/window',
  );

  static int? _lastEraseBackground;

  /// 同步主窗原生擦除底色（最大化/缩放过渡期新暴露区域的填充色）。
  ///
  /// 过渡期窗口新暴露的边缘在 Flutter 下一帧呈现前由原生先铺这层底色，
  /// 避免闪出黑边；按当前主题底色调用。同值去重，重复调用无副作用。
  static Future<void> syncEraseBackground(Color color) async {
    if (!isDesktopPlatform) return;
    final value = color.toARGB32() & 0xFFFFFF;
    if (_lastEraseBackground == value) return;
    _lastEraseBackground = value;
    try {
      await _windowChannel.invokeMethod<void>('setEraseBackground', value);
    } on MissingPluginException {
      // 旧 runner（未注册该通道）或测试环境：忽略。
    } on PlatformException {
      // 同步失败不影响功能。
    }
  }

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
  ///
  /// 除位置外同时钳制尺寸：窗口本身可能比可见区域还大（如 1280x800
  /// 的默认/记忆尺寸落在 1366x768 屏），不缩窗则底部/右侧永远探出屏幕。
  /// 尺寸上限取所有可见区域的包围盒而非单一显示器，避免误缩
  /// 跨双屏使用的合法大窗口；下限为最小窗口，可见范围比最小窗口还小
  /// 时以可见范围为准（保证窗口完整可见、可拖）。
  static DesktopWindowGeometry clampToVisibleAreas(
    DesktopWindowGeometry geometry,
    List<Rect> visibleAreas,
  ) {
    // 无可用显示器信息时无从钳制，原样返回。
    if (visibleAreas.isEmpty) return geometry;
    final windowRect = geometry.rect;
    // 所有可见区域的包围盒，作为尺寸钳制上限。
    var union = visibleAreas.first;
    for (final area in visibleAreas.skip(1)) {
      union = union.expandToInclude(area);
    }
    // 任一可见区域与窗口有足量交集（至少 kMinVisibleEdge 见方）→ 可见
    // 且可拖动，仅数像素交集视为不可用（拔显示器/DPI 换算后
    // 贴边的典型残余），走下方重定位。
    for (final area in visibleAreas) {
      final intersection = area.intersect(windowRect);
      if (intersection.width >= kMinVisibleEdge &&
          intersection.height >= kMinVisibleEdge) {
        return DesktopWindowGeometry(
          left: geometry.left,
          top: geometry.top,
          width: _clampExtent(
            geometry.width,
            DesktopWindow.kMinSize.width,
            union.width,
          ),
          height: _clampExtent(
            geometry.height,
            DesktopWindow.kMinSize.height,
            union.height,
          ),
        );
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
      width: _clampExtent(
        geometry.width,
        DesktopWindow.kMinSize.width,
        union.width,
      ),
      height: _clampExtent(
        geometry.height,
        DesktopWindow.kMinSize.height,
        union.height,
      ),
    );
  }

  /// 单边尺寸钳制：不超过 [visibleExtent]；不小于 [minSize]；
  /// 可见范围不比最小窗口大时以可见范围为准。
  static double _clampExtent(double value, double minSize, double visibleExtent) {
    if (visibleExtent <= minSize) {
      return visibleExtent;
    }
    return math.min(math.max(value, minSize), visibleExtent);
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
