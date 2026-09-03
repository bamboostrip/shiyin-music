import 'package:flutter/material.dart';

/// 窗口宽度分级（逻辑像素），阈值与设计文档 §3 一致。
enum WindowWidthClass { compact, medium, expanded, large, expandedDesktop }

/// 自适应布局工具类。
///
/// 平板检测基于 Material Design 的 breakpoint：
/// - 最小边 < 600dp → 手机
/// - 最小边 ≥ 600dp → 平板
///
/// 手机横屏时最小边仍为宽度（一般 ≤ 430dp），不会被误判为平板。
class AdaptiveLayout {
  const AdaptiveLayout._();

  /// 普通平板内容区域的最大宽度（已取消限制，保留常量供网格计算参考）。
  static const double tabletMaxWidth = 800;

  /// 超宽屏内容区域的最大宽度（已取消限制，保留常量供网格计算参考）。
  static const double wideMaxWidth = 1200;

  /// 是否为平板设备。
  ///
  /// 使用 [MediaQuery.sizeOf] 获取屏幕逻辑像素，
  /// `shortestSide >= 600` 即判定为平板（Material Design 标准）。
  static bool isTablet(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.shortestSide >= 600;
  }

  /// 不依赖 [BuildContext] 的平板判断。
  ///
  /// 直接从 [PlatformDispatcher] 读取屏幕物理尺寸换算为逻辑像素。
  /// 适用于 [State.dispose] 等 context 已失效、无法调用
  /// [MediaQuery.sizeOf] 的场景，否则会触发
  /// `Null check operator used on a null value` 异常。
  static bool isTabletByPlatform() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return false;
    final view = views.first;
    final physical = view.physicalSize;
    if (physical.isEmpty) return false;
    final size = physical / view.devicePixelRatio;
    return size.shortestSide >= 600;
  }

  /// 是否为超宽屏（宽高比 ≥ 2.5 或宽度 ≥ 1600dp）。
  static bool isUltraWide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 1600 || (size.height > 0 && size.width / size.height >= 2.5);
  }

  /// 根据屏幕宽度计算内容区域的最大宽度。
  ///
  /// 已取消最大宽度限制，所有屏幕均铺满显示。
  static double contentMaxWidthFor(BuildContext context) {
    return double.infinity;
  }

  /// 根据屏幕宽度计算网格列数。
  ///
  /// 适用于歌单、专辑等网格布局。
  static int gridColumnsFor(BuildContext context, {double minItemWidth = 160}) {
    final maxWidth = contentMaxWidthFor(context);
    final effectiveWidth = maxWidth == double.infinity
        ? MediaQuery.sizeOf(context).width
        : maxWidth;
    return (effectiveWidth / minItemWidth).floor().clamp(2, 8);
  }

  /// 按宽度返回窗口分级（PC 适配断点体系入口）。
  static WindowWidthClass widthClassFor(double width) {
    if (width >= 1600) return WindowWidthClass.expandedDesktop;
    if (width >= 1200) return WindowWidthClass.large;
    if (width >= 840) return WindowWidthClass.expanded;
    if (width >= 600) return WindowWidthClass.medium;
    return WindowWidthClass.compact;
  }

  /// 按宽度与最小项宽计算网格列数，结果夹在 [min]–[max]。
  ///
  /// 宽度低于网格起点（840，即 expanded 断点）时直接返回 [min]。
  /// 32 为两侧内容边距预留。
  static int gridColumnsForWidth(
    double width, {
    double minItemWidth = 200,
    int min = 2,
    int max = 6,
  }) {
    if (width < 840) return min;
    final columns = ((width - 32) ~/ minItemWidth).clamp(min, max);
    return columns;
  }
}

/// 自适应内容内边距。
///
/// 已取消最大宽度限制，所有屏幕均铺满显示。
class AdaptiveContentPadding extends StatelessWidget {
  const AdaptiveContentPadding({
    super.key,
    required this.child,
    this.maxWidth,
  });

  final Widget child;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
