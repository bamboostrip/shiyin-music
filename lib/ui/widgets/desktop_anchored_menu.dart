import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// PC 锚定菜单与屏幕四周保留的最小边距（逻辑像素）。
const double kAnchoredMenuMinScreenMargin = 8;

/// 计算锚定菜单在屏幕（窗口）内的最终位置。
///
/// 纯函数，便于单测：
/// - [anchor] 是菜单左上角的参考点（全局/窗口坐标，如右键位置或 `...` 按钮底边中点）；
/// - 默认菜单从锚点向右下展开；
/// - 向右溢出屏幕时向左翻转（菜单右缘贴锚点左侧），向下溢出时向上翻转；
/// - 翻转与钳制保证菜单整体与屏幕四周保留 ≥ [margin] 的边距；
/// - 菜单本身比屏幕还大时，先收缩到可用区域再定位（左上角贴边距）。
Rect placeAnchoredMenu({
  required Offset anchor,
  required Size menuSize,
  required Size screenSize,
  double margin = kAnchoredMenuMinScreenMargin,
}) {
  final double safeMargin = margin < 0 ? 0 : margin;

  final double screenWidth =
      screenSize.width.isFinite && screenSize.width > 0 ? screenSize.width : 0;
  final double screenHeight =
      screenSize.height.isFinite && screenSize.height > 0
          ? screenSize.height
          : 0;

  // 菜单可用尺寸：屏幕减去四周边距，不允许为负。
  final double availableWidth = math.max(0.0, screenWidth - safeMargin * 2);
  final double availableHeight = math.max(0.0, screenHeight - safeMargin * 2);

  final double rawWidth =
      menuSize.width.isFinite && menuSize.width > 0 ? menuSize.width : 0.0;
  final double rawHeight =
      menuSize.height.isFinite && menuSize.height > 0 ? menuSize.height : 0.0;
  final double menuWidth = math.min(math.max(0.0, rawWidth), availableWidth);
  final double menuHeight = math.min(math.max(0.0, rawHeight), availableHeight);

  var left = anchor.dx.isFinite ? anchor.dx : 0.0;
  var top = anchor.dy.isFinite ? anchor.dy : 0.0;

  // 向右溢出 → 向左翻转（右缘贴锚点左侧）。
  if (left + menuWidth > screenWidth - safeMargin) {
    left = anchor.dx - menuWidth;
  }
  // 向下溢出 → 向上翻转（底缘贴锚点上方）。
  if (top + menuHeight > screenHeight - safeMargin) {
    top = anchor.dy - menuHeight;
  }

  // 翻转后仍可能越界（如锚点在屏幕外），钳制到边距内。
  final double maxLeft = screenWidth - safeMargin - menuWidth;
  final double maxTop = screenHeight - safeMargin - menuHeight;
  if (left < safeMargin) left = safeMargin;
  if (left > maxLeft) left = maxLeft;
  if (top < safeMargin) top = safeMargin;
  if (top > maxTop) top = maxTop;

  return Rect.fromLTWH(left, top, menuWidth, menuHeight);
}

/// 取 [context] 对应 RenderBox 底边中点的全局（窗口）坐标，
/// 供 `...` 按钮等触发点把菜单锚定在自己的下方。
Offset anchorBelow(BuildContext context) {
  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return Offset.zero;
  }
  return renderObject.localToGlobal(
    Offset(renderObject.size.width / 2, renderObject.size.height),
  );
}

/// 以 PC 上下文菜单的形式，在 [anchor]（全局/窗口坐标）附近弹出锚定菜单。
///
/// - 全屏 barrier：点击空白处关闭；
/// - Esc 关闭；
/// - 菜单尺寸在首帧测量后经 [placeAnchoredMenu] 定位（窗口尺寸变化不跟随，
///   关闭重开即可，符合任务要求）；
/// - 坐标空间 = 当前应用窗口（MediaQuery 尺寸），不处理跨显示器。
Future<T?> showDesktopAnchoredMenu<T>({
  required BuildContext context,
  required Offset anchor,
  required WidgetBuilder builder,
  Color? barrierColor,
  String? barrierLabel,
  bool useRootNavigator = true,
  RouteSettings? settings,
}) {
  return Navigator.of(context, rootNavigator: useRootNavigator).push(
    _DesktopAnchoredMenuRoute<T>(
      anchor: anchor,
      menuBuilder: builder,
      scrimColor: barrierColor ?? Colors.black.withValues(alpha: 0.12),
      barrierLabel: barrierLabel ?? '关闭菜单',
      settings: settings,
    ),
  );
}

class _DesktopAnchoredMenuRoute<T> extends PopupRoute<T> {
  _DesktopAnchoredMenuRoute({
    required Offset anchor,
    required WidgetBuilder menuBuilder,
    required this.scrimColor,
    String? barrierLabel,
    super.settings,
  }) : _anchor = anchor,
       _menuBuilder = menuBuilder,
       _barrierLabel = barrierLabel ?? '关闭菜单';

  final Offset _anchor;
  final WidgetBuilder _menuBuilder;
  final Color scrimColor;
  final String _barrierLabel;

  @override
  Color? get barrierColor => scrimColor;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => _barrierLabel;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 130);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 90);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _AnchoredMenuPosition(
      anchor: _anchor,
      menuBuilder: _menuBuilder,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      child: child,
    );
  }
}

/// 首帧以 Offstage 测量菜单实际尺寸，再用 [placeAnchoredMenu] 计算位置并显示。
class _AnchoredMenuPosition extends StatefulWidget {
  const _AnchoredMenuPosition({required this.anchor, required this.menuBuilder});

  final Offset anchor;
  final WidgetBuilder menuBuilder;

  @override
  State<_AnchoredMenuPosition> createState() => _AnchoredMenuPositionState();
}

class _AnchoredMenuPositionState extends State<_AnchoredMenuPosition> {
  final GlobalKey _measureKey = GlobalKey();
  Rect? _menuRect;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndPlace());
  }

  void _measureAndPlace() {
    if (!mounted) return;
    final BuildContext? measureContext = _measureKey.currentContext;
    if (measureContext == null) return;
    final RenderObject? renderObject = measureContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      // 尺寸尚未就绪（字体/图标异步），下一帧重试。
      WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndPlace());
      return;
    }
    setState(() {
      _menuRect = placeAnchoredMenu(
        anchor: widget.anchor,
        menuSize: renderObject.size,
        screenSize: MediaQuery.sizeOf(context),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget menu = KeyedSubtree(
      key: _measureKey,
      child: widget.menuBuilder(context),
    );

    return FocusScope(
      autofocus: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () {
            Navigator.of(context).pop();
          },
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (_menuRect != null)
              Positioned(
                left: _menuRect!.left,
                top: _menuRect!.top,
                width: _menuRect!.width,
                height: _menuRect!.height,
                child: menu,
              )
            else
              // 测量帧：不绘制、不命中，菜单随下一帧出现在锚定位置。
              Offstage(child: menu),
          ],
        ),
      ),
    );
  }
}
