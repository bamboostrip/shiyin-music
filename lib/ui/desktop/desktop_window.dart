import 'dart:async';
// window_manager 未重新导出 dart:ui 类型，Size/Offset 需自行引入。
import 'dart:ui' show Offset, Size;

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
        await windowManager.setPosition(geometry.offset);
      }
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
