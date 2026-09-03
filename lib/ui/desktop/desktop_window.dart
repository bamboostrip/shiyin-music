import 'dart:async';
import 'dart:math' as math;
// window_manager 未重新导出 dart:ui 类型，Size/Offset 需自行引入。
import 'dart:ui' show Offset, Rect, Size;

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
    final prefs = await SharedPreferences.getInstance();
    final geometry = DesktopWindowGeometry.load(prefs);
    final options = WindowOptions(
      size: geometry?.size ?? kDefaultSize,
      minimumSize: kMinSize,
      title: kWindowTitle,
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
      await windowManager.show();
      await windowManager.focus();
    });
    _saver = _WindowGeometrySaver(prefs);
    windowManager.addListener(_saver!);
  }

  static _WindowGeometrySaver? _saver;

  /// 取当前所有显示器的可见区域（主显示器在前），钳制已保存几何。
  static Future<DesktopWindowGeometry> _clampToConnectedDisplays(
    DesktopWindowGeometry geometry,
  ) async {
    final primary = await screenRetriever.getPrimaryDisplay();
    final all = await screenRetriever.getAllDisplays();
    // 主显示器排最前：钳制时优先落回主显示器（按 id 去重）。
    final displays = <Display>[
      primary,
      ...all.where((display) => display.id != primary.id),
    ];
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

  /// 将窗口几何钳制到至少与一块显示器可见区域相交，
  /// 避免显示器配置变化后窗口恢复到屏幕外。
  /// [visibleAreas] 为各显示器的可见区域（左上角 + 尺寸）。
  static DesktopWindowGeometry clampToVisibleAreas(
    DesktopWindowGeometry geometry,
    List<Rect> visibleAreas,
  ) {
    // 无可用显示器信息时无从钳制，原样返回。
    if (visibleAreas.isEmpty) return geometry;
    final windowRect = geometry.rect;
    // 任一可见区域与窗口矩形相交 → 位置仍可见，原样返回。
    for (final area in visibleAreas) {
      if (area.overlaps(windowRect)) return geometry;
    }
    // 完全不可见 → 放进第一个可见区域，右/下边至少留出 80px 可见；
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
