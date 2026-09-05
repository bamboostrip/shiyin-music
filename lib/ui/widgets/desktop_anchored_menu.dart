import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// PC 锚定菜单与屏幕四周保留的最小边距（逻辑像素）。
const double kAnchoredMenuMinScreenMargin = 8;

/// PC 面板类锚定弹层（如播放队列面板）与屏幕四周保留的最小边距（逻辑像素）。
const double kAnchoredPanelMinScreenMargin = 12;

/// 锚定弹层定位函数：输入锚点、内容实测尺寸与窗口尺寸，返回内容最终矩形。
///
/// `placeAnchoredMenu` 与 `placeAnchoredPanelAbove` 均符合此签名，
/// 供 [DesktopAnchoredPopupRoute] 首帧测量后调用。
typedef AnchoredPlacement = Rect Function(
  Offset anchor,
  Size menuSize,
  Size screenSize,
);

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

/// 计算底边锚定面板（如播放队列面板）在屏幕（窗口）内的最终位置。
///
/// 纯函数，便于单测：
/// - [anchor] 是面板底边参考点（如播放条队列按钮「顶边-右缘」交点）；
/// - 面板右缘贴 anchor.dx、底缘贴 anchor.dy（即出现在锚点上方、与锚点右对齐）；
/// - 不做翻转（触发点在窗口底栏，上方恒有空间），越界时整体向窗口内钳制；
/// - 与屏幕四周保留 ≥ [margin] 的边距；
/// - 面板比可用区域还大时，先收缩到可用区域再定位。
Rect placeAnchoredPanelAbove({
  required Offset anchor,
  required Size panelSize,
  required Size screenSize,
  double margin = kAnchoredPanelMinScreenMargin,
}) {
  final double safeMargin = margin < 0 ? 0 : margin;

  final double screenWidth =
      screenSize.width.isFinite && screenSize.width > 0 ? screenSize.width : 0;
  final double screenHeight =
      screenSize.height.isFinite && screenSize.height > 0
          ? screenSize.height
          : 0;

  final double availableWidth = math.max(0.0, screenWidth - safeMargin * 2);
  final double availableHeight = math.max(0.0, screenHeight - safeMargin * 2);

  final double rawWidth =
      panelSize.width.isFinite && panelSize.width > 0 ? panelSize.width : 0.0;
  final double rawHeight =
      panelSize.height.isFinite && panelSize.height > 0 ? panelSize.height : 0.0;
  final double panelWidth = math.min(math.max(0.0, rawWidth), availableWidth);
  final double panelHeight =
      math.min(math.max(0.0, rawHeight), availableHeight);

  // 右缘贴锚点右对齐；不越过屏幕右缘-边距，也不把面板推出左缘之外。
  final double maxRight = math.max(safeMargin, screenWidth - safeMargin);
  final double minRight = math.min(safeMargin + panelWidth, maxRight);
  final double rightRaw = anchor.dx.isFinite ? anchor.dx : maxRight;
  final double right = rightRaw.clamp(minRight, maxRight);

  // 底缘贴锚点上方；锚点太靠顶时向下收进屏幕（保证上边距）。
  final double maxBottom = math.max(safeMargin, screenHeight - safeMargin);
  final double minBottom = math.min(safeMargin + panelHeight, maxBottom);
  final double bottomRaw = anchor.dy.isFinite ? anchor.dy : maxBottom;
  final double bottom = bottomRaw.clamp(minBottom, maxBottom);

  return Rect.fromLTWH(
    right - panelWidth,
    bottom - panelHeight,
    panelWidth,
    panelHeight,
  );
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

/// 取 [context] 对应 RenderBox「顶边-右缘」交点的全局（窗口）坐标，
/// 供底栏按钮等触发点把面板锚定在自己的上方（面板底缘贴按钮顶边、右对齐按钮）。
Offset anchorAboveRight(BuildContext context) {
  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return Offset.zero;
  }
  return renderObject.localToGlobal(
    Offset(renderObject.size.width, 0),
  );
}

/// 以 PC 上下文菜单的形式，在 [anchor]（全局/窗口坐标）附近弹出锚定菜单。
///
/// - 全屏 barrier：**视觉透明**，仅用于点击菜单外任意处关闭（light dismiss，
///   Windows/macOS 桌面惯例：右键菜单不压暗背景；QQ 音乐/网易云同）；
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
    DesktopAnchoredPopupRoute<T>(
      anchor: anchor,
      menuBuilder: builder,
      placement: (anchor, menuSize, screenSize) => placeAnchoredMenu(
        anchor: anchor,
        menuSize: menuSize,
        screenSize: screenSize,
      ),
      scrimColor: barrierColor ?? Colors.transparent,
      barrierLabel: barrierLabel ?? '关闭菜单',
      settings: settings,
    ),
  );
}

/// PC 锚定弹层通用路由：全屏半透明 barrier（点击关闭）+ Esc 关闭 +
/// 首帧以 Offstage 测量内容尺寸后经 [placement] 纯函数定位。
///
/// 上下文菜单（`showDesktopAnchoredMenu`）与播放队列面板
/// （`showDesktopQueuePanel`）共用本路由，barrier/Esc/测量逻辑只此一份。
class DesktopAnchoredPopupRoute<T> extends PopupRoute<T> {
  DesktopAnchoredPopupRoute({
    required Offset anchor,
    required WidgetBuilder menuBuilder,
    required this.placement,
    this.scrimColor = _defaultScrimColor,
    String? barrierLabel,
    super.settings,
  }) : _anchor = anchor,
       _menuBuilder = menuBuilder,
       _barrierLabel = barrierLabel ?? '关闭菜单';

  static const Color _defaultScrimColor = Color(0x1F000000); // black 12%

  final Offset _anchor;
  final WidgetBuilder _menuBuilder;
  final AnchoredPlacement placement;
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
    return _AnchoredPopupPosition(
      anchor: _anchor,
      menuBuilder: _menuBuilder,
      placement: placement,
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

/// 首帧以 Offstage 测量内容实际尺寸，再用 [placement] 计算位置并显示。
class _AnchoredPopupPosition extends StatefulWidget {
  const _AnchoredPopupPosition({
    required this.anchor,
    required this.menuBuilder,
    required this.placement,
  });

  final Offset anchor;
  final WidgetBuilder menuBuilder;
  final AnchoredPlacement placement;

  @override
  State<_AnchoredPopupPosition> createState() => _AnchoredPopupPositionState();
}

class _AnchoredPopupPositionState extends State<_AnchoredPopupPosition> {
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
      _menuRect = widget.placement(
        widget.anchor,
        renderObject.size,
        MediaQuery.sizeOf(context),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget menu = Material(
      type: MaterialType.transparency,
      child: KeyedSubtree(
        key: _measureKey,
        child: widget.menuBuilder(context),
      ),
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
