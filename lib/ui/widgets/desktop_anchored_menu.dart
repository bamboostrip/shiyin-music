import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';

/// PC 锚定菜单与屏幕四周保留的最小边距（逻辑像素）。
const double kAnchoredMenuMinScreenMargin = 8;

/// PC 面板类锚定弹层（如播放队列面板）与屏幕四周保留的最小边距（逻辑像素）。
const double kAnchoredPanelMinScreenMargin = 12;

/// 悬停到父项后弹出二级菜单的延迟（对齐 Windows/QQ 音乐节奏）。
const Duration kCascadeMenuHoverDelay = Duration(milliseconds: 320);

/// 从父项移出、尚未进入二级菜单时的关闭宽限，避免移动路径抖动关掉。
const Duration kCascadeMenuLeaveGrace = Duration(milliseconds: 180);

/// 锚定弹层定位函数：输入锚点、内容实测尺寸与窗口尺寸，返回内容最终矩形。
typedef AnchoredPlacement = Rect Function(
  Offset anchor,
  Size menuSize,
  Size screenSize,
);

/// 计算锚定菜单在屏幕（窗口）内的最终位置。
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

  if (left + menuWidth > screenWidth - safeMargin) {
    left = anchor.dx - menuWidth;
  }
  if (top + menuHeight > screenHeight - safeMargin) {
    top = anchor.dy - menuHeight;
  }

  final double maxLeft = screenWidth - safeMargin - menuWidth;
  final double maxTop = screenHeight - safeMargin - menuHeight;
  if (left < safeMargin) left = safeMargin;
  if (left > maxLeft) left = maxLeft;
  if (top < safeMargin) top = safeMargin;
  if (top > maxTop) top = maxTop;

  return Rect.fromLTWH(left, top, menuWidth, menuHeight);
}

/// 计算底边锚定面板（如播放队列面板）在屏幕（窗口）内的最终位置。
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

  final double maxRight = math.max(safeMargin, screenWidth - safeMargin);
  final double minRight = math.min(safeMargin + panelWidth, maxRight);
  final double rightRaw = anchor.dx.isFinite ? anchor.dx : maxRight;
  final double right = rightRaw.clamp(minRight, maxRight);

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

/// 计算二级菜单相对一级菜单/父项的最终位置（右侧展开，越界左翻/上移）。
Rect placeCascadeSubmenu({
  required Offset parentItemTopRight,
  required Offset parentItemBottomLeft,
  required Size submenuSize,
  required Size primarySize,
  required Offset primaryTopLeft,
  required Size screenSize,
  double gap = 4,
  double margin = kAnchoredMenuMinScreenMargin,
}) {
  final double screenWidth =
      screenSize.width.isFinite && screenSize.width > 0 ? screenSize.width : 0;
  final double screenHeight =
      screenSize.height.isFinite && screenSize.height > 0
          ? screenSize.height
          : 0;
  final double availableWidth = math.max(0.0, screenWidth - margin * 2);
  final double availableHeight = math.max(0.0, screenHeight - margin * 2);
  final double menuWidth = math.min(submenuSize.width, availableWidth);
  final double menuHeight = math.min(submenuSize.height, availableHeight);

  // 默认：贴父项右缘、顶对齐父项顶边。
  var left = parentItemTopRight.dx + gap;
  var top = parentItemTopRight.dy;

  // 右侧放不下 → 翻到一级菜单左侧。
  if (left + menuWidth > screenWidth - margin) {
    left = primaryTopLeft.dx - gap - menuWidth;
  }
  // 仍越左 → 贴一级菜单右侧并钳制。
  if (left < margin) {
    left = math.min(primaryTopLeft.dx + primarySize.width + gap, screenWidth - margin - menuWidth);
  }

  // 底部放不下 → 上移对齐父项底边或贴边距。
  if (top + menuHeight > screenHeight - margin) {
    top = parentItemBottomLeft.dy - menuHeight;
  }
  if (top < margin) top = margin;
  final maxTop = screenHeight - margin - menuHeight;
  if (top > maxTop) top = math.max(margin, maxTop);

  return Rect.fromLTWH(left, top, menuWidth, menuHeight);
}

/// 取 [context] 对应 RenderBox 顶边中点的全局（窗口）坐标。
Offset anchorAbove(BuildContext context) {
  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return Offset.zero;
  }
  return renderObject.localToGlobal(
    Offset(renderObject.size.width / 2, 0),
  );
}

/// 取 [context] 对应 RenderBox 底边中点的全局（窗口）坐标。
Offset anchorBelow(BuildContext context) {
  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return Offset.zero;
  }
  return renderObject.localToGlobal(
    Offset(renderObject.size.width / 2, renderObject.size.height),
  );
}

/// 取 [context] 对应 RenderBox「顶边-右缘」交点的全局（窗口）坐标。
Offset anchorAboveRight(BuildContext context) {
  final RenderObject? renderObject = context.findRenderObject();
  if (renderObject is! RenderBox || !renderObject.hasSize) {
    return Offset.zero;
  }
  return renderObject.localToGlobal(
    Offset(renderObject.size.width, 0),
  );
}

/// 以 PC 上下文菜单的形式，在 [anchor] 附近弹出锚定菜单。
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

/// PC 锚定弹层通用路由。
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

  static const Color _defaultScrimColor = Color(0x1F000000);

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

class _AnchoredPopupPositionState extends State<_AnchoredPopupPosition>
    with WidgetsBindingObserver {
  final GlobalKey _measureKey = GlobalKey();
  Rect? _menuRect;
  bool _closedByMetricsChange = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAndPlace());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 窗口尺寸/DPI 变化即关闭：锚点是打开瞬间的快照坐标，resize 后按钮
  /// 位置已变，重放只会得到贴边错位的面板（对齐 Windows 原生菜单行为）。
  @override
  void didChangeMetrics() {
    if (_closedByMetricsChange || !mounted) return;
    _closedByMetricsChange = true;
    Navigator.of(context).pop();
  }

  void _measureAndPlace() {
    if (!mounted) return;
    final BuildContext? measureContext = _measureKey.currentContext;
    if (measureContext == null) return;
    final RenderObject? renderObject = measureContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
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
              Offstage(child: menu),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 级联菜单（一级保留 + 右侧二级，悬停延时 / 点击展开）
// ---------------------------------------------------------------------------

/// 级联菜单节点：叶子可点击；有 [children] 时右侧展开二级。
class CascadeMenuNode {
  const CascadeMenuNode({
    required this.title,
    this.icon,
    this.trailingLabel,
    this.tooltip,
    this.selected = false,
    this.children,
    this.childrenBuilder,
    this.closeOnTap = true,
    this.onTap,
  });

  final String title;
  final IconData? icon;
  final String? trailingLabel;

  /// 悬浮提示；为空时用 [title]。
  final String? tooltip;
  final bool selected;

  /// 静态二级；与 [childrenBuilder] 二选一。
  final List<CascadeMenuNode>? children;

  /// 动态二级：每次展开/刷新时重新求值（开关类选项改完可不关菜单）。
  final List<CascadeMenuNode> Function()? childrenBuilder;

  /// 点击后是否关闭整组菜单。开关/单选偏好用 false。
  final bool closeOnTap;

  final VoidCallback? onTap;

  bool get hasSubmenu =>
      (children?.isNotEmpty ?? false) || childrenBuilder != null;

  List<CascadeMenuNode> resolveChildren() =>
      childrenBuilder?.call() ?? children ?? const <CascadeMenuNode>[];
}

/// 弹出 PC 级联菜单（QQ 音乐式：一级常驻，悬停/点击展开二级）。
///
/// 使用全屏路由，由 [showDesktopCascadeMenu] 内部自行定位一级/二级，
/// 不走 [DesktopAnchoredPopupRoute] 的外层 Positioned（会二次偏移）。
Future<void> showDesktopCascadeMenu({
  required BuildContext context,
  required Offset anchor,
  required List<CascadeMenuNode> items,
  Widget? header,
  double width = 220,
  double submenuWidth = 200,
}) {
  return Navigator.of(context, rootNavigator: true).push(
    _DesktopCascadeMenuRoute(
      anchor: anchor,
      items: items,
      header: header,
      width: width,
      submenuWidth: submenuWidth,
    ),
  );
}

class _DesktopCascadeMenuRoute extends PopupRoute<void> {
  _DesktopCascadeMenuRoute({
    required this.anchor,
    required this.items,
    required this.header,
    required this.width,
    required this.submenuWidth,
  });

  final Offset anchor;
  final List<CascadeMenuNode> items;
  final Widget? header;
  final double width;
  final double submenuWidth;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭菜单';

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
    return _DesktopCascadeMenuHost(
      anchor: anchor,
      items: items,
      header: header,
      width: width,
      submenuWidth: submenuWidth,
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

class _DesktopCascadeMenuHost extends StatefulWidget {
  const _DesktopCascadeMenuHost({
    required this.anchor,
    required this.items,
    required this.header,
    required this.width,
    required this.submenuWidth,
  });

  final Offset anchor;
  final List<CascadeMenuNode> items;
  final Widget? header;
  final double width;
  final double submenuWidth;

  @override
  State<_DesktopCascadeMenuHost> createState() =>
      _DesktopCascadeMenuHostState();
}

class _DesktopCascadeMenuHostState extends State<_DesktopCascadeMenuHost>
    with WidgetsBindingObserver {
  final GlobalKey _primaryMeasureKey = GlobalKey();
  final GlobalKey _submenuMeasureKey = GlobalKey();

  Rect? _primaryRect;
  Rect? _submenuRect;
  int? _openIndex;
  Timer? _hoverTimer;
  Timer? _leaveTimer;
  bool _pointerInPrimary = false;
  bool _pointerInSubmenu = false;
  bool _closedByMetricsChange = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measurePrimary());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hoverTimer?.cancel();
    _leaveTimer?.cancel();
    super.dispose();
  }

  /// 窗口尺寸/DPI 变化即关闭（理由同 [_AnchoredPopupPositionState]）。
  @override
  void didChangeMetrics() {
    if (_closedByMetricsChange || !mounted) return;
    _closedByMetricsChange = true;
    Navigator.of(context).pop();
  }

  void _measurePrimary() {
    if (!mounted) return;
    final box = _primaryMeasureKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measurePrimary());
      return;
    }
    setState(() {
      _primaryRect = placeAnchoredMenu(
        anchor: widget.anchor,
        menuSize: box.size,
        screenSize: MediaQuery.sizeOf(context),
      );
    });
  }

  void _measureSubmenu(int index, Rect parentItemGlobal) {
    if (!mounted || _primaryRect == null) return;
    final box = _submenuMeasureKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _measureSubmenu(index, parentItemGlobal),
      );
      return;
    }
    // 仅当仍指向同一项时才落位，避免快速划过时用过期测量。
    if (_openIndex != index) return;
    setState(() {
      _submenuRect = placeCascadeSubmenu(
        parentItemTopRight: parentItemGlobal.topRight,
        parentItemBottomLeft: parentItemGlobal.bottomLeft,
        submenuSize: box.size,
        primarySize: _primaryRect!.size,
        primaryTopLeft: _primaryRect!.topLeft,
        screenSize: MediaQuery.sizeOf(context),
      );
    });
  }

  void _scheduleOpenSubmenu(int index, Rect itemGlobal) {
    _leaveTimer?.cancel();
    if (_openIndex == index && _submenuRect != null) return;
    _hoverTimer?.cancel();
    _hoverTimer = Timer(kCascadeMenuHoverDelay, () {
      if (!mounted) return;
      setState(() {
        _openIndex = index;
        _submenuRect = null; // 先入树测量，再定位
      });
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _measureSubmenu(index, itemGlobal),
      );
    });
  }

  void _openSubmenuImmediately(int index, Rect itemGlobal) {
    _leaveTimer?.cancel();
    _hoverTimer?.cancel();
    setState(() {
      _openIndex = index;
      _submenuRect = null;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _measureSubmenu(index, itemGlobal),
    );
  }

  void _scheduleCloseSubmenu() {
    _hoverTimer?.cancel();
    _leaveTimer?.cancel();
    _leaveTimer = Timer(kCascadeMenuLeaveGrace, () {
      if (!mounted) return;
      if (_pointerInPrimary || _pointerInSubmenu) return;
      setState(() {
        _openIndex = null;
        _submenuRect = null;
      });
    });
  }

  /// 悬停到无二级的一级项时立即收起二级。
  ///
  /// 宽限期只服务「从父项移向二级」的路径；用户已明确停在叶子项上，
  /// 不能因 _pointerInPrimary 而一直挂着。
  void _closeSubmenuNow() {
    _hoverTimer?.cancel();
    _leaveTimer?.cancel();
    if (_openIndex == null && _submenuRect == null) return;
    setState(() {
      _openIndex = null;
      _submenuRect = null;
    });
  }

  void _closeAllAndRun(VoidCallback? onTap) {
    Navigator.of(context).pop();
    if (onTap == null) return;
    // 等一级路由 pop 后再执行（避免回调里再开菜单被当前 barrier 挡住）。
    Future<void>.delayed(const Duration(milliseconds: 80), onTap);
  }

  Rect _itemGlobalRect(BuildContext itemContext) {
    final box = itemContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return Rect.zero;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    // 无一级尺寸时仍入树测量（Offstage 由父路由处理）。
    final primary = KeyedSubtree(
      key: _primaryMeasureKey,
      child: _CascadeMenuPanel(
        width: widget.width,
        header: widget.header,
        children: [
          for (var i = 0; i < widget.items.length; i++)
            _CascadeMenuItem(
              node: widget.items[i],
              expanded: _openIndex == i,
              onHover: (itemContext) {
                final node = widget.items[i];
                if (!node.hasSubmenu) {
                  // 停在叶子项：立即收起已打开的二级，不留宽限。
                  _closeSubmenuNow();
                  return;
                }
                _scheduleOpenSubmenu(i, _itemGlobalRect(itemContext));
              },
              onLeave: _scheduleCloseSubmenu,
              onTap: (itemContext) {
                final node = widget.items[i];
                if (node.hasSubmenu) {
                  _openSubmenuImmediately(i, _itemGlobalRect(itemContext));
                  return;
                }
                if (!node.closeOnTap) {
                  node.onTap?.call();
                  setState(() {});
                  return;
                }
                _closeAllAndRun(node.onTap);
              },
            ),
        ],
      ),
    );

    final openIndex = _openIndex;
    final openNode =
        (openIndex != null && openIndex < widget.items.length)
            ? widget.items[openIndex]
            : null;

    Widget? submenu;
    if (openNode?.hasSubmenu == true) {
      final subItems = openNode!.resolveChildren();
      submenu = KeyedSubtree(
        key: _submenuMeasureKey,
        child: MouseRegion(
          onEnter: (_) {
            _pointerInSubmenu = true;
            _leaveTimer?.cancel();
          },
          onExit: (_) {
            _pointerInSubmenu = false;
            _scheduleCloseSubmenu();
          },
          child: _CascadeMenuPanel(
            width: widget.submenuWidth,
            children: [
              for (final child in subItems)
                _CascadeMenuItem(
                  node: child,
                  expanded: false,
                  onHover: (_) {},
                  onLeave: () {},
                  onTap: (_) {
                    child.onTap?.call();
                    if (child.closeOnTap) {
                      Navigator.of(context).pop();
                    } else {
                      // 开关/单选：留在菜单内，立刻刷新勾选态。
                      setState(() {});
                    }
                  },
                ),
            ],
          ),
        ),
      );
    }

    // 全屏铺满：Positioned 使用窗口绝对坐标，父级必须占满。
    return SizedBox.expand(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 一级：测量后定位；子级未定位前不显示，避免闪烁。
          if (_primaryRect != null)
            Positioned(
              left: _primaryRect!.left,
              top: _primaryRect!.top,
              width: _primaryRect!.width,
              height: _primaryRect!.height,
              child: MouseRegion(
                onEnter: (_) {
                  _pointerInPrimary = true;
                  _leaveTimer?.cancel();
                },
                onExit: (_) {
                  _pointerInPrimary = false;
                  _scheduleCloseSubmenu();
                },
                child: primary,
              ),
            )
          else
            Offstage(child: primary),
          // 二级：先入树测量（不可见），定位后显示。
          if (submenu != null)
            if (_submenuRect != null)
              Positioned(
                left: _submenuRect!.left,
                top: _submenuRect!.top,
                width: _submenuRect!.width,
                height: _submenuRect!.height,
                child: submenu,
              )
            else
              Offstage(child: submenu),
        ],
      ),
    );
  }
}

class _CascadeMenuPanel extends StatelessWidget {
  const _CascadeMenuPanel({
    required this.width,
    required this.children,
    this.header,
  });

  final double width;
  final List<Widget> children;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E212B) : colorScheme.surface;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : colorScheme.outlineVariant.withValues(alpha: 0.8);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : colorScheme.outlineVariant.withValues(alpha: 0.6);

    return Material(
      type: MaterialType.transparency,
      child: Container(
        width: width,
        constraints: const BoxConstraints(maxHeight: 460),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.14),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(11),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (header != null) ...[
                header!,
                Divider(height: 1, thickness: 1, color: dividerColor),
              ],
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CascadeMenuItem extends StatefulWidget {
  const _CascadeMenuItem({
    required this.node,
    required this.expanded,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final CascadeMenuNode node;
  final bool expanded;
  final void Function(BuildContext itemContext) onHover;
  final VoidCallback onLeave;
  final void Function(BuildContext itemContext) onTap;

  @override
  State<_CascadeMenuItem> createState() => _CascadeMenuItemState();
}

class _CascadeMenuItemState extends State<_CascadeMenuItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hoverColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : colorScheme.surfaceContainerHigh;
    final color = widget.node.selected
        ? colorScheme.primary
        : colorScheme.onSurface;
    final highlight = _hovering || widget.expanded;

    return Builder(
      builder: (itemContext) {
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) {
            setState(() => _hovering = true);
            widget.onHover(itemContext);
          },
          onExit: (_) {
            setState(() => _hovering = false);
            widget.onLeave();
          },
          child: Tooltip(
            message: widget.node.tooltip ?? widget.node.title,
            waitDuration: AppDesktopTheme.tooltipWaitDuration,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onTap(itemContext),
              child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              constraints: const BoxConstraints(minHeight: 36),
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              padding: const EdgeInsets.only(left: 10, right: 8, top: 8, bottom: 8),
              decoration: BoxDecoration(
                color: highlight ? hoverColor : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  if (widget.node.icon != null) ...[
                    Icon(widget.node.icon, size: 18, color: color),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      widget.node.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13.5,
                        fontWeight: widget.node.selected
                            ? FontWeight.w700
                            : FontWeight.w600,
                        color: color,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  if (widget.node.trailingLabel != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      widget.node.trailingLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                  if (widget.node.selected && !widget.node.hasSubmenu) ...[
                    const SizedBox(width: 6),
                    Icon(Icons.check_rounded, size: 16, color: colorScheme.primary),
                  ],
                  if (widget.node.hasSubmenu) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
      },
    );
  }
}

/// PC 二级菜单通用面板皮肤（兼容旧调用；新代码优先用 [showDesktopCascadeMenu]）。
class DesktopPopupMenuPanel extends StatelessWidget {
  const DesktopPopupMenuPanel({
    super.key,
    required this.title,
    required this.children,
    this.width = 200,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final double width;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E212B) : colorScheme.surface;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : colorScheme.outlineVariant.withValues(alpha: 0.8);
    final dividerColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : colorScheme.outlineVariant.withValues(alpha: 0.6);

    return Container(
      width: width,
      constraints: const BoxConstraints(maxHeight: 420),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                    ?trailing,
                  ],
                ),
              ),
              Divider(height: 1, thickness: 1, color: dividerColor),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: children,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PC 二级菜单单行选项（可带选中勾、副文案）。
class DesktopPopupMenuItem extends StatefulWidget {
  const DesktopPopupMenuItem({
    super.key,
    required this.label,
    this.subtitle,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<DesktopPopupMenuItem> createState() => _DesktopPopupMenuItemState();
}

class _DesktopPopupMenuItemState extends State<DesktopPopupMenuItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hoverColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : colorScheme.surfaceContainerHigh;
    final color = widget.selected
        ? colorScheme.primary
        : colorScheme.onSurface;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            constraints: const BoxConstraints(minHeight: 36),
            margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _hovering ? hoverColor : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontSize: 13.5,
                      fontWeight: widget.selected
                          ? FontWeight.w700
                          : FontWeight.w600,
                      color: color,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                if (widget.subtitle != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    widget.subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
                if (widget.selected) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.check_rounded, size: 16, color: colorScheme.primary),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
