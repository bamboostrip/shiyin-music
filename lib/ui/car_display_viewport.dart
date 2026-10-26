import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 车机显示视口：收缩/放大「布局视口」后再用变换还原，实现真正的界面缩放。
///
/// 与「只放大字体」的方案不同，这里改变的是布局约束与 [MediaQuery]：
/// - 网格列数、列表行数、按钮物理尺寸一起变化（缩小一屏装更多，放大按钮
///   在屏幕上物理变大，远距离点按容错更高）；
/// - 命中测试由 [Transform] 机制自动逆变换，且本节点自身尺寸恒为整屏，
///   不会出现「按钮看得见却点不到」（若直接 `Transform.scale` 包一个
///   缩小的 `SizedBox`，父节点 bounds 会把放大后的溢出区裁掉命中）；
/// - [textScaler] 不参与缩放：文字随布局一起被变换放大，避免「只放大字
///   不放大容器」导致固定高度行溢出。
///
/// [marginTop]/[marginBottom] 是**物理逻辑像素**（不参与缩放，直接占用屏幕
/// 上下空间），用于给车机悬浮状态栏、底部悬浮条让位。
///
/// 仅在车机模式且参数非默认值时由 [maybe] 启用；桌面/普通模式直接返回
/// 原始 child，保证现有用户零感知。
class CarDisplayViewport extends StatelessWidget {
  const CarDisplayViewport({
    super.key,
    required this.scale,
    required this.marginTop,
    required this.marginBottom,
    required this.child,
  }) : assert(scale > 0, 'scale 必须为正数');

  /// 界面缩放倍率（>0）。1.0 表示不缩放。
  final double scale;

  /// 顶部安全留白（逻辑像素）。
  final double marginTop;

  /// 底部安全留白（逻辑像素）。
  final double marginBottom;

  final Widget child;

  /// 按需启用：未开启、或参数均为默认值时直接返回 [child]。
  static Widget maybe({
    required bool enabled,
    required double scale,
    required double marginTop,
    required double marginBottom,
    required Widget child,
  }) {
    final active = enabled &&
        (scale != 1.0 || marginTop > 0 || marginBottom > 0);
    if (!active) return child;
    return CarDisplayViewport(
      scale: scale,
      marginTop: marginTop,
      marginBottom: marginBottom,
      child: child,
    );
  }

  /// 由真实屏幕数据折算出的虚拟 [MediaQueryData]。
  ///
  /// 供内部与测试共用：布局宽高按 scale 收缩、物理留白从边距中扣除后再
  /// 折算，`devicePixelRatio` 反向补偿，保证 `size * dpr` 仍等于物理像素。
  @visibleForTesting
  static MediaQueryData virtualMediaQuery(
    MediaQueryData real, {
    required double scale,
    required double marginTop,
    required double marginBottom,
  }) {
    assert(scale > 0, 'scale 必须为正数');
    final double s = scale;
    final double innerHeight =
        math.max(0.0, real.size.height - marginTop - marginBottom);
    final Size size = Size(real.size.width / s, innerHeight / s);

    // 系统 inset 里已经被「物理留白」让出的部分不再重复消费。
    double consume(double inset, double margin) =>
        math.max(0.0, inset - margin) / s;

    final EdgeInsets viewPadding = EdgeInsets.fromLTRB(
      real.viewPadding.left / s,
      consume(real.viewPadding.top, marginTop),
      real.viewPadding.right / s,
      consume(real.viewPadding.bottom, marginBottom),
    );
    final EdgeInsets viewInsets = EdgeInsets.fromLTRB(
      real.viewInsets.left / s,
      math.max(0.0, real.viewInsets.top - marginTop) / s,
      real.viewInsets.right / s,
      consume(real.viewInsets.bottom, marginBottom),
    );
    final EdgeInsets padding = EdgeInsets.fromLTRB(
      math.max(0.0, viewPadding.left - viewInsets.left),
      math.max(0.0, viewPadding.top - viewInsets.top),
      math.max(0.0, viewPadding.right - viewInsets.right),
      math.max(0.0, viewPadding.bottom - viewInsets.bottom),
    );

    return real.copyWith(
      size: size,
      devicePixelRatio: real.devicePixelRatio * s,
      padding: padding,
      viewPadding: viewPadding,
      viewInsets: viewInsets,
      systemGestureInsets: EdgeInsets.fromLTRB(
        real.systemGestureInsets.left / s,
        real.systemGestureInsets.top / s,
        real.systemGestureInsets.right / s,
        real.systemGestureInsets.bottom / s,
      ),
      // displayCutout / displayFeatures 是物理像素语义，当前项目无消费
      // （挖孔/折叠屏适配走 SafeArea 的 padding）；若将来直接消费，需要
      // 先换算成虚拟坐标再使用。
    );
  }

  @override
  Widget build(BuildContext context) {
    final MediaQueryData real = MediaQuery.of(context);
    return _CarDisplayViewport(
      scale: scale,
      marginTop: marginTop,
      marginBottom: marginBottom,
      child: MediaQuery(
        data: virtualMediaQuery(
          real,
          scale: scale,
          marginTop: marginTop,
          marginBottom: marginBottom,
        ),
        child: child,
      ),
    );
  }
}

/// 承载变换的 RenderObject 挂件（对外只是 [CarDisplayViewport] 的实现细节）。
class _CarDisplayViewport extends SingleChildRenderObjectWidget {
  const _CarDisplayViewport({
    required this.scale,
    required this.marginTop,
    required this.marginBottom,
    required super.child,
  });

  final double scale;
  final double marginTop;
  final double marginBottom;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderCarDisplayViewport(
      scale: scale,
      marginTop: marginTop,
      marginBottom: marginBottom,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderCarDisplayViewport renderObject,
  ) {
    renderObject
      ..scale = scale
      ..marginTop = marginTop
      ..marginBottom = marginBottom;
  }
}

/// 自身尺寸 = 父约束（整屏），子节点按缩放后的虚拟尺寸 tight 布局，
/// 绘制时平移 + 缩放回整屏。
class _RenderCarDisplayViewport extends RenderProxyBox {
  _RenderCarDisplayViewport({
    required double scale,
    required double marginTop,
    required double marginBottom,
  })  : _scale = scale,
        _marginTop = marginTop,
        _marginBottom = marginBottom;

  double _scale;
  double _marginTop;
  double _marginBottom;
  final Matrix4 _transform = Matrix4.identity();

  double get scale => _scale;
  set scale(double value) {
    assert(value > 0, 'scale 必须为正数');
    if (_scale == value) return;
    _scale = value;
    markNeedsLayout();
  }

  double get marginTop => _marginTop;
  set marginTop(double value) {
    if (_marginTop == value) return;
    _marginTop = value;
    markNeedsLayout();
  }

  double get marginBottom => _marginBottom;
  set marginBottom(double value) {
    if (_marginBottom == value) return;
    _marginBottom = value;
    markNeedsLayout();
  }

  void _updateTransform() {
    // 先缩放（以左上角为原点），再向下平移 marginTop。
    _transform.setIdentity();
    _transform.setEntry(0, 0, _scale);
    _transform.setEntry(1, 1, _scale);
    _transform.setEntry(1, 3, _marginTop);
  }

  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    assert(
      constraints.hasBoundedWidth && constraints.hasBoundedHeight,
      'CarDisplayViewport 需要有限约束（应挂在 MaterialApp.builder 或整屏容器下）',
    );
    final Size available = constraints.hasBoundedWidth && constraints.hasBoundedHeight
        ? constraints.biggest
        : size;
    final double innerWidth = math.max(0.0, available.width / _scale);
    final double innerHeight = math.max(
      0.0,
      (available.height - _marginTop - _marginBottom) / _scale,
    );
    size = available;
    _updateTransform();
    child?.layout(
      BoxConstraints.tight(Size(innerWidth, innerHeight)),
      parentUsesSize: true,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (!_scale.isFinite || _scale <= 0) return;
    final Matrix4 transform = Matrix4.copy(_transform);
    context.pushTransform(needsCompositing, offset, transform, super.paint);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    if (!_scale.isFinite || _scale <= 0) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (BoxHitTestResult result, Offset position) {
        return super.hitTestChildren(result, position: position);
      },
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(DoubleProperty('scale', _scale));
    properties.add(DoubleProperty('marginTop', _marginTop));
    properties.add(DoubleProperty('marginBottom', _marginBottom));
  }
}
